-- StatsPro.lua
-- Inspired by SwiftStats by TaylorSay (MIT). Boilerplate, color defaults, and the
-- basic stat list are adapted from upstream; the rest is original work. See LICENSE
-- for full attribution.
local _, addon = ...
addon.fontRuntime = {}
addon.panelEditRuntime = { requested = false }
addon.resetRuntime = {
    pending = nil,
    popupKey = "STATSPRO_RESET_ACTIVE_PROFILE",
}
addon.wipeRuntime = {
    pending = nil,
    popupKey = "STATSPRO_WIPE_ALL_DATA",
}
addon.developerLinks = {
    popupKey = "STATSPRO_COPY_DEVELOPER_LINK",
    koFiLink = {
        key = "koFiLink",
        label = "Ko-fi",
        url = "https://ko-fi.com/antrakt92",
    },
    contact = {
        key = "contact",
        labelKey = "Contact",
        url = "https://github.com/Antrakt92/StatsPro/issues",
    },
}
addon.durabilityRuntime = {
    generation = 0,
    retryDelays = { 1, 3, 8, 15 },
    retryStates = {
        durability = {
            generation = 0,
            attempt = 0,
            scheduledGeneration = nil,
            scheduledAttempt = nil,
        },
        repair = {
            generation = 0,
            attempt = 0,
            scheduledGeneration = nil,
            scheduledAttempt = nil,
        },
    },
}
addon.itemLevelRuntime = {
    generation = 0,
    attempt = 0,
    maxAttempts = 4,
}
addon.critRuntime = {
    selectedSource = nil,
    selectedSpellSchool = nil,
}
addon.movementRuntime = {
    baseSpeed = 7,
    percentAtBaseSpeed = 100,
    -- WHY: AbbreviateNumbers is AllowedWhenTainted in Retail 12.x and performs
    -- the scaling inside Blizzard C code. One decimal keeps the existing HUD
    -- precision; the tiny epsilon avoids binary floor-underflow at exact values.
    nativePercentOptions = {
        breakpointData = {
            {
                breakpoint = 0,
                abbreviation = "%",
                significandDivisor = 0.006999999999,
                fractionDivisor = 10,
                abbreviationIsGlobal = false,
            },
        },
    },
    nativePercentFormatterState = nil,
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

addon.fontRuntime.glyphRequirementLabelKeys = {
    [GLYPH_LATIN] = "Western European text",
    [GLYPH_CYR] = "Russian text",
    [GLYPH_HANGUL] = "Korean text",
    [GLYPH_HANS] = "Simplified Chinese text",
    [GLYPH_HANT] = "Traditional Chinese text",
}

function addon.fontRuntime.GlyphRequirementLabelKey(requirement)
    return addon.fontRuntime.glyphRequirementLabelKeys[requirement]
        or "text for the selected language"
end

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

function addon.fontRuntime.asciiLower(value)
    if type(value) ~= "string" then return nil end
    -- WoW Lua 5.1 string casing is byte-based. Restrict folding to matched ASCII
    -- bytes so localized font names and paths keep their UTF-8 sequences intact.
    return (value:gsub("[A-Z]", string.lower))
end

local function FontPathKey(fontPath)
    if type(fontPath) ~= "string" then return nil end
    local ok, secret = pcall(issecretvalue, fontPath)
    if not ok or secret then return nil end
    return addon.fontRuntime.asciiLower(fontPath:gsub("/", "\\"))
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

-- Per-client-shipped Blizzard font paths (drives the picker no-LSM fallback and
-- current-name reverse lookup). FONT_GLYPH_SUPPORT above answers "what glyphs
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
local CURRENT_RELEASE = "1.14.4"

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
    -- Outlined text keeps the fresh/reset HUD readable while a transparent backing
    -- gives both panels the lightest default footprint. Saved profiles stay explicit.
    panelBackgroundAlpha = 0,
    -- Text outline style: "none" | "outline" | "thick". Default preserves current OUTLINE text.
    textOutlineStyle = "outline",
    -- Optional provenance only: old profiles intentionally resolve to Custom without
    -- a schema migration or any write during load. Fresh/reset profiles start Default.
    appearancePresetID = "default",
    -- WHY LocaleAwareDefaultFont: Blizzard's locale-aware default-font global resolves
    -- to the right TTF for the current WoW client locale (CJK-supporting on zhCN/zhTW/
    -- koKR; Latin/Cyrillic-supporting elsewhere). Hardcoding FRIZQT would render
    -- localized labels (Crit / 暴击 / 치명 / etc.) as `?` boxes on CJK clients. The
    -- helper guards against font-replacement addons (Chonky, Tukui, ElvUI) that
    -- override STANDARD_TEXT_FONT to their own path — those would hijack our defaults
    -- otherwise. Falls back to FRIZQT for any non-Blizzard path.
    font = LocaleAwareDefaultFont(),
    updateInterval = 0.5,
    -- Account-only onboarding marker. Existing registries that predate the field
    -- are treated as already seen; a truly empty install explicitly stores false.
    quickSetupSeen = true,
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
    showRating = true,
    showPercentage = true,
    matchValueColorToStat = true,
    targetSnapshot = "mythicPlusCurrent",

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
function addon.IsCleanFiniteNumber(value)
    if issecretvalue(value) then return false end
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

-- One classification boundary for display-only numerics. The first result says
-- whether Blizzard may render the value; the second is a clean restricted-state
-- flag. Arithmetic still uses IsCleanFiniteNumber exclusively.
function addon.ClassifyRenderableNumber(value)
    local ok, secret = pcall(issecretvalue, value)
    if not ok then return false, false end
    return secret or addon.IsCleanFiniteNumber(value), secret
end

-- WHY: Blizzard's paper doll defines spell crit as the minimum across schools
-- 2..MAX_SPELL_SCHOOLS, then chooses the best of spell/ranged/melee. Addon Lua cannot
-- repeat those comparisons once the PTR marks every operand secret. Cache only the
-- winning source descriptor from a complete clean read, then pass that source's live
-- secret value directly to the client formatter in combat. This is a live proxy rather
-- than a guaranteed aggregate; a cold restricted start remains explicitly unknown.
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
        if type(fn) ~= "function" then return nil, "unavailable" end
        local ok, value = pcall(fn, ...)
        if not ok then return nil, "unavailable" end
        local secretOK, secret = pcall(issecretvalue, value)
        if not secretOK then return nil, "unavailable" end
        if secret then return value, "restricted" end
        if not addon.IsCleanFiniteNumber(value) then return nil, "unavailable" end
        return value, "clean"
    end
    local melee, meleeState = read(GetCritChance)
    local ranged, rangedState = read(GetRangedCritChance)
    local maxSpellSchool = addon.GetMaxSpellSchool()
    local spellValues = {}
    local spellStates = {}
    local restricted = meleeState == "restricted" or rangedState == "restricted"
    local unavailable = meleeState == "unavailable" or rangedState == "unavailable"
    for school = 2, maxSpellSchool do
        local value, state = read(GetSpellCritChance, school)
        spellValues[school] = value
        spellStates[school] = state
        if state == "restricted" then restricted = true end
        if state == "unavailable" then unavailable = true end
    end
    if restricted then
        local runtime = addon.critRuntime
        if runtime.selectedSource == "spell" then
            local school = runtime.selectedSpellSchool
            if spellStates[school] ~= "unavailable" then
                return spellValues[school], "liveProxy"
            end
        elseif runtime.selectedSource == "ranged" and rangedState ~= "unavailable" then
            return ranged, "liveProxy"
        elseif runtime.selectedSource == "melee" and meleeState ~= "unavailable" then
            return melee, "liveProxy"
        end
        return nil, "restricted"
    end
    if unavailable then return nil, "unavailable" end
    local spell = spellValues[2]
    local spellSchool = 2
    for school = 3, maxSpellSchool do
        if spellValues[school] < spell then
            spell = spellValues[school]
            spellSchool = school
        end
    end
    local runtime = addon.critRuntime
    if spell >= ranged and spell >= melee then
        runtime.selectedSource = "spell"
        runtime.selectedSpellSchool = spellSchool
        return spell, "exact"
    elseif ranged >= melee then
        runtime.selectedSource = "ranged"
        runtime.selectedSpellSchool = nil
        return ranged, "exact"
    end
    runtime.selectedSource = "melee"
    runtime.selectedSpellSchool = nil
    return melee, "exact"
end

local OFFENSIVE_STATS = {
    { statKey = "crit", label = "Crit", api = addon.GetBestCritChance,
      ratingCR = CR_CRIT_MELEE, colorKey = "crit", showKey = "showCrit", composite = true },
    { statKey = "haste",   label = "Haste",   api = GetHaste,         ratingCR = CR_HASTE_MELEE, colorKey = "haste",   showKey = "showHaste"   },
    { statKey = "mastery", label = "Mastery", api = GetMasteryEffect, ratingCR = CR_MASTERY,     colorKey = "mastery", showKey = "showMastery" },
    -- versatility handled specially (dual-source: rating + flat); gated by showVersatility
}

-- Appearance presets deliberately exclude font, layout, visibility, routing, scale,
-- locale, refresh rate, positions, and assignments. Every color palette is complete so
-- applying a preset never inherits a partially customized table by accident.
addon.appearancePresets = {
    order = { "default", "classic", "clean-dark", "midnight", "monochrome", "high-contrast" },
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
            colors = CopyTable(defaults.colors),
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
addon.appearancePresets.definitions.default = { label = "Default" }
for key in pairs(addon.appearancePresets.allowlist) do
    addon.appearancePresets.definitions.default[key] = key == "colors"
        and CopyTable(defaults.colors) or defaults[key]
end

-- Quick Setup presets are deliberately functional rather than visual. They own
-- the complete row/routing shape required for a predictable result, while
-- preserving appearance, scale, positions, locale, refresh rate, visibility,
-- locking, Archon context, profile assignments, and account settings.
addon.hudPresets = {
    order = { "compact", "dps", "tank" },
    allowlist = {
        displayMode = true, labelStyle = true,
        showRating = true, showPercentage = true,
        showMainStat = true, showStamina = true, showItemLevel = true,
        showOffensive = true, hideZeroOffensive = true,
        showCrit = true, showHaste = true,
        showMastery = true, showVersatility = true,
        showTertiary = true, hideZeroTertiary = true,
        showLeech = true, showAvoidance = true, showSpeed = true,
        showDefensive = true, hideZeroDefensive = true,
        showDodge = true, showParry = true, showBlock = true,
        showArmor = true, showStagger = true,
        showDurability = true, showRepairCost = true,
        useWorstDurability = true,
        splitCharacter = true, splitItemLevel = true,
        splitOffensive = true, splitTertiary = true,
        splitDefensive = true, splitDurability = true,
        splitRepairCost = true,
    },
    definitions = {
        compact = {
            label = "Compact",
            summary = "Secondary stats only",
            values = {
                displayMode = "flat", labelStyle = "full",
                showRating = true, showPercentage = true,
                showMainStat = false, showStamina = false, showItemLevel = false,
                showOffensive = true, hideZeroOffensive = false,
                showCrit = true, showHaste = true,
                showMastery = true, showVersatility = true,
                showTertiary = false, hideZeroTertiary = true,
                showLeech = true, showAvoidance = true, showSpeed = true,
                showDefensive = false, hideZeroDefensive = true,
                showDodge = true, showParry = true, showBlock = true,
                showArmor = true, showStagger = false,
                showDurability = false, showRepairCost = false,
                useWorstDurability = false,
                splitCharacter = false, splitItemLevel = true,
                splitOffensive = false, splitTertiary = false,
                splitDefensive = true, splitDurability = true,
                splitRepairCost = true,
            },
        },
        dps = {
            label = "DPS",
            summary = "DPS and tertiary stats with gear status",
            values = {
                displayMode = "flat", labelStyle = "full",
                showRating = true, showPercentage = true,
                showMainStat = false, showStamina = false, showItemLevel = true,
                showOffensive = true, hideZeroOffensive = true,
                showCrit = true, showHaste = true,
                showMastery = true, showVersatility = true,
                showTertiary = true, hideZeroTertiary = true,
                showLeech = true, showAvoidance = true, showSpeed = true,
                showDefensive = false, hideZeroDefensive = true,
                showDodge = true, showParry = true, showBlock = true,
                showArmor = true, showStagger = true,
                showDurability = true, showRepairCost = true,
                useWorstDurability = false,
                splitCharacter = false, splitItemLevel = false,
                splitOffensive = false, splitTertiary = false,
                splitDefensive = false, splitDurability = false,
                splitRepairCost = false,
            },
        },
        tank = {
            label = "Tank",
            summary = "DPS, tertiary, and defensive stats with gear status",
        },
    },
    session = nil,
    views = {},
    settingsDiscovered = false,
    combatState = nil,
}
-- WHY: Tank is the DPS setup plus defensive rows. Deriving a detached copy
-- keeps that product contract exact without coupling either mutable table.
addon.hudPresets.definitions.tank.values =
    CopyTable(addon.hudPresets.definitions.dps.values)
addon.hudPresets.definitions.tank.values.showDefensive = true

-- Shared preview coordination keeps the two preset services mutually exclusive and
-- gives DB reads a single override path. Service-specific definitions, runtime apply,
-- current-ID detection, and UI rendering stay on their owning service.
addon.presetRuntime = {
    services = { addon.appearancePresets, addon.hudPresets },
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
addon.archonTargets.defaultSnapshotKey = "mythicPlusCurrent"
addon.archonTargets.snapshotOptions = {
    { value = "mythicPlusCurrent",  label = "M+ Current" },
    { value = "mythicPlusHighKeys", label = "M+ High Keys" },
    { value = "raidNormal",         label = "Raid Normal" },
    { value = "raidHeroic",         label = "Raid Heroic" },
    { value = "raidMythic",         label = "Raid Mythic" },
}
-- Session-local by design: a character change reloads addon Lua, while zoning into
-- Mythic+ does not. Context and effective-level changes clear entries so switching
-- away and back cannot revive a comparison captured before the transition.
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


function addon.archonTargets.IsCleanContextKey(value)
    return type(value) == "string" and not issecretvalue(value) and value ~= ""
end

function addon.archonTargets.InvalidateComparisonCache()
    local cache = addon.archonTargets.comparisonCache
    cache.generation = cache.generation + 1
    cache.entries = {}
end

function addon.archonTargets.ActivateComparisonContext(classToken, specKey, snapshotKey)
    if not addon.archonTargets.IsCleanContextKey(classToken)
        or not addon.archonTargets.IsCleanContextKey(specKey)
        or not addon.archonTargets.IsCleanContextKey(snapshotKey) then return nil end
    local cache = addon.archonTargets.comparisonCache
    if cache.classToken ~= classToken or cache.specKey ~= specKey or cache.snapshotKey ~= snapshotKey then
        cache.classToken = classToken
        cache.specKey = specKey
        cache.snapshotKey = snapshotKey
        addon.archonTargets.InvalidateComparisonCache()
    end
    return cache
end

function addon.archonTargets.GetCachedComparison(classToken, specKey, snapshotKey, statKey,
                                                  target, ratingCR, capturedAt)
    if not addon.archonTargets.IsCleanContextKey(statKey)
        or not addon.IsCleanFiniteNumber(target)
        or not addon.IsCleanFiniteNumber(ratingCR)
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
    if not addon.IsCleanFiniteNumber(entry.current)
        or not addon.IsCleanFiniteNumber(entry.delta) then
        cache.entries[statKey] = nil
        return nil
    end
    if entry.currentPct ~= nil and not addon.IsCleanFiniteNumber(entry.currentPct) then
        cache.entries[statKey] = nil
        return nil
    end
    if type(entry.targetPct) ~= "nil"
        and not addon.IsCleanFiniteNumber(entry.targetPct) then
        cache.entries[statKey] = nil
        return nil
    end
    return entry
end

function addon.archonTargets.StoreCleanComparison(classToken, specKey, snapshotKey, statKey,
                                                   target, ratingCR, capturedAt,
                                                   current, currentPct, delta, targetPct)
    if not addon.archonTargets.IsCleanContextKey(statKey)
        or not addon.IsCleanFiniteNumber(target)
        or not addon.IsCleanFiniteNumber(ratingCR)
        or not addon.IsCleanFiniteNumber(current)
        or not addon.IsCleanFiniteNumber(delta)
        or type(capturedAt) ~= "string" or issecretvalue(capturedAt) then return end
    if currentPct ~= nil and not addon.IsCleanFiniteNumber(currentPct) then return end
    if type(targetPct) ~= "nil" and not addon.IsCleanFiniteNumber(targetPct) then return end
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
        targetPct = targetPct,
    }
end

function addon.archonTargets.NormalizeSnapshotKey(value)
    if value == "raid" then return "raidMythic" end
    -- Legacy schema v1/v2 and SavedVariables used mythicPlus for High Keys.
    -- Keep that meaning so an upgrade never silently changes a user's target.
    if value == "mythicPlus" then return "mythicPlusHighKeys" end
    for _, option in ipairs(addon.archonTargets.snapshotOptions) do
        if value == option.value then return value end
    end
    return addon.archonTargets.defaultSnapshotKey
end

function addon.archonTargets.GetAvailableSnapshotOptions()
    local root = _G.StatsProArchonTargets
    local options = {}
    if type(root) == "table" and (root.schemaVersion == 4 or root.schemaVersion == 5)
        and type(root.snapshots) == "table" then
        for _, option in ipairs(addon.archonTargets.snapshotOptions) do
            local snapshot = root.snapshots[option.value]
            if type(snapshot) == "table" then
                local detail = type(snapshot.difficultyLabel) == "string"
                    and snapshot.difficultyLabel ~= "" and snapshot.difficultyLabel or nil
                options[#options + 1] = {
                    value = option.value,
                    label = option.label,
                    detail = detail,
                }
            end
        end
    elseif type(root) == "table" and root.schemaVersion == 3
        and type(root.snapshots) == "table" then
        for _, option in ipairs(addon.archonTargets.snapshotOptions) do
            if type(root.snapshots[option.value]) == "table" then
                options[#options + 1] = option
            end
        end
    elseif type(root) == "table" and root.schemaVersion == 2
        and type(root.snapshots) == "table" then
        if type(root.snapshots.mythicPlus) == "table" then
            options[#options + 1] = addon.archonTargets.snapshotOptions[2]
        end
        if type(root.snapshots.raid) == "table" then
            options[#options + 1] = addon.archonTargets.snapshotOptions[5]
        end
    elseif type(root) == "table" and root.schemaVersion == 1 then
        options[#options + 1] = addon.archonTargets.snapshotOptions[2]
    end
    return options
end

function addon.archonTargets.ResolveAvailableSnapshotKey(value)
    local requested = addon.archonTargets.NormalizeSnapshotKey(value)
    local available = {}
    for _, option in ipairs(addon.archonTargets.GetAvailableSnapshotOptions()) do
        available[option.value] = true
    end
    if available[requested] then return requested end

    local fallbackOrder
    if requested == "mythicPlusHighKeys" then
        fallbackOrder = { "mythicPlusHighKeys", "mythicPlusCurrent" }
    elseif requested == "mythicPlusCurrent" then
        fallbackOrder = { "mythicPlusCurrent", "mythicPlusHighKeys" }
    elseif requested == "raidNormal" then
        fallbackOrder = { "raidNormal", "raidHeroic", "raidMythic" }
    elseif requested == "raidHeroic" then
        fallbackOrder = { "raidHeroic", "raidNormal", "raidMythic" }
    else
        fallbackOrder = { "raidMythic", "raidHeroic", "raidNormal" }
    end
    for _, key in ipairs(fallbackOrder) do
        if available[key] then return key end
    end
    for _, option in ipairs(addon.archonTargets.GetAvailableSnapshotOptions()) do
        if available[option.value] then return option.value end
    end
    return addon.archonTargets.defaultSnapshotKey
end

function addon.archonTargets.GetRootSnapshot(snapshotKey)
    local root = _G.StatsProArchonTargets
    if type(root) ~= "table" then return nil end
    local normalizedKey = addon.archonTargets.ResolveAvailableSnapshotKey(snapshotKey)
    if root.schemaVersion == 3 or root.schemaVersion == 4 or root.schemaVersion == 5 then
        local snapshots = root.snapshots
        local snapshotRoot = type(snapshots) == "table" and snapshots[normalizedKey] or nil
        if type(snapshotRoot) ~= "table" then return nil end
        return snapshotRoot, root, normalizedKey
    end
    if root.schemaVersion == 2 then
        local legacyKey = normalizedKey == "raidMythic" and "raid"
            or normalizedKey == "mythicPlusHighKeys" and "mythicPlus" or nil
        local snapshotRoot = legacyKey and type(root.snapshots) == "table"
            and root.snapshots[legacyKey] or nil
        if type(snapshotRoot) ~= "table" then return nil end
        return snapshotRoot, root, normalizedKey
    end
    if root.schemaVersion == 1 then
        return root, root, "mythicPlusHighKeys"
    end
    return nil
end

function addon.archonTargets.GetSnapshot(classToken, specKey, snapshotKey)
    local snapshotRoot, root, normalizedKey = addon.archonTargets.GetRootSnapshot(snapshotKey)
    if not snapshotRoot then return nil end
    local specs = snapshotRoot.specs
    if type(specs) ~= "table" then return nil, snapshotRoot, root, normalizedKey end
    local classData = specs[classToken]
    if type(classData) ~= "table" then return nil, snapshotRoot, root, normalizedKey end
    local specData = classData[specKey]
    if type(specData) ~= "table" then
        local rootSnapshots = type(root) == "table" and root.snapshots or nil
        if type(root) == "table" and root.schemaVersion == 5 and normalizedKey == "raidMythic"
            and type(rootSnapshots) == "table" then
            local fallbackRoot = rootSnapshots.raidHeroic
            local fallbackClasses = type(fallbackRoot) == "table" and fallbackRoot.specs or nil
            local fallbackClass = type(fallbackClasses) == "table" and fallbackClasses[classToken] or nil
            local fallbackSpec = type(fallbackClass) == "table" and fallbackClass[specKey] or nil
            if type(fallbackSpec) == "table" then
                return fallbackSpec, fallbackRoot, root, "raidHeroic"
            end
        end
        return nil, snapshotRoot, root, normalizedKey
    end
    return specData, snapshotRoot, root, normalizedKey
end

function addon.archonTargets.GetCurrentSnapshot()
    local classToken = addon.archonTargets.GetCurrentClassToken()
    local specKey = addon.archonTargets.GetCurrentSpecKey()
    if not classToken or not specKey then return nil end
    local snapshot, snapshotRoot, root, snapshotKey = addon.archonTargets.GetSnapshot(classToken, specKey, cached.targetSnapshot)
    snapshotKey = snapshotKey or addon.archonTargets.ResolveAvailableSnapshotKey(cached.targetSnapshot)
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

function addon.archonTargets.CalculateMasteryTargetPercent(currentRating, currentPct, target)
    if not addon.IsCleanFiniteNumber(currentRating) or currentRating < 0
        or not addon.IsCleanFiniteNumber(currentPct)
        or not addon.IsCleanFiniteNumber(target) or target < 0 then return nil end
    local currentBonus, targetBonus, currentReason, targetReason =
        addon.archonTargets.GetRatingBonusesForValues(
            CR_MASTERY, currentRating, target)
    if not addon.IsCleanFiniteNumber(currentBonus)
        or not addon.IsCleanFiniteNumber(targetBonus) then
        if currentReason == "restricted" or targetReason == "restricted" then
            return nil, "restricted"
        end
        return nil, "unavailable"
    end
    local targetPct = currentPct + targetBonus - currentBonus
    if not addon.IsCleanFiniteNumber(targetPct) then return nil end
    return targetPct
end

function addon.archonTargets.BuildMeta(statKey, currentRating, ratingCR, currentPct,
                                       colorKey, currentPctDisplay, currentRatingDisplay)
    local hasCleanCurrent = addon.IsCleanFiniteNumber(currentRating) and currentRating >= 0
    local _, ratingDisplayIsSecret = addon.ClassifyRenderableNumber(currentRatingDisplay)
    local hasLiveCurrentRating = ratingDisplayIsSecret
    local hasCurrentPctDisplay, displayIsSecret =
        addon.ClassifyRenderableNumber(currentPctDisplay)
    if not hasCurrentPctDisplay then
        currentPctDisplay = currentPct
        hasCurrentPctDisplay = addon.IsCleanFiniteNumber(currentPctDisplay)
    end
    local target, snapshot, snapshotRoot, _, snapshotKey, classToken, specKey = addon.archonTargets.GetStatTarget(statKey)
    if not target then return nil end
    if type(snapshot) ~= "table" or type(snapshotRoot) ~= "table" then return nil end
    local cleanRatingCR = addon.IsCleanFiniteNumber(ratingCR) and ratingCR or nil
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
    }
    if hasCleanCurrent then
        local displayPct = addon.IsCleanFiniteNumber(currentPct) and currentPct or nil
        local delta = currentRating - target
        if addon.IsCleanFiniteNumber(delta) then
            local targetPct, targetPctReason
            local cachedEntry
            if statKey == "mastery" and cleanRatingCR == CR_MASTERY then
                targetPct, targetPctReason = addon.archonTargets.CalculateMasteryTargetPercent(
                    currentRating, displayPct, target)
                if targetPct == nil and (displayIsSecret or targetPctReason == "restricted") then
                    cachedEntry = addon.archonTargets.GetCachedComparison(
                        classToken, specKey, snapshotKey, statKey,
                        target, cleanRatingCR, capturedAt)
                    if cachedEntry then targetPct = cachedEntry.targetPct end
                end
            end
            meta.comparisonState = "exact"
            meta.current = currentRating
            meta.currentPct = displayPct
            meta.targetPct = targetPct
            -- Display-only: direct combat percentages may be secret while the rating
            -- remains clean. Keep the raw value out of comparisons/caches and pass it
            -- only to the same client formatter used by the live HUD.
            if hasCurrentPctDisplay then meta.currentPctDisplay = currentPctDisplay end
            meta.delta = delta
            -- A transient nil/error from Mastery APIs must not replace the last fully
            -- clean percentage tuple with a rating-only one. Restricted live values
            -- are different: the cached Target % is still valid and intentionally
            -- travels with the fresh clean rating comparison.
            local preserveCompleteMasteryCache = statKey == "mastery"
                and targetPct == nil and not displayIsSecret
                and targetPctReason ~= "restricted"
            if preserveCompleteMasteryCache and cachedEntry == nil then
                cachedEntry = addon.archonTargets.GetCachedComparison(
                    classToken, specKey, snapshotKey, statKey,
                    target, cleanRatingCR, capturedAt)
            end
            preserveCompleteMasteryCache = preserveCompleteMasteryCache
                and cachedEntry ~= nil and cachedEntry.targetPct ~= nil
            if not preserveCompleteMasteryCache then
                addon.archonTargets.StoreCleanComparison(
                    classToken, specKey, snapshotKey, statKey, target, cleanRatingCR,
                    capturedAt, currentRating, displayPct, delta, targetPct)
            end
        end
        return meta
    end
    local entry = addon.archonTargets.GetCachedComparison(
        classToken, specKey, snapshotKey, statKey, target, cleanRatingCR, capturedAt)
    if hasLiveCurrentRating then
        -- A restricted rating may be rendered by the client but must never enter
        -- addon arithmetic, ordering, or the clean comparison cache. Prefer the
        -- live value over a stale last-known comparison and state the limitation
        -- explicitly in the tooltip.
        meta.comparisonState = "liveOnly"
        meta.currentRatingDisplay = currentRatingDisplay
        if hasCurrentPctDisplay then meta.currentPctDisplay = currentPctDisplay end
        -- Target % was captured during a clean update for this exact class/spec/
        -- snapshot/target and player-level epoch. It does not reuse Current/Delta.
        if entry then meta.targetPct = entry.targetPct end
        return meta
    end
    if entry then
        meta.comparisonState = "lastKnown"
        meta.current = entry.current
        meta.currentPct = entry.currentPct
        meta.delta = entry.delta
        meta.targetPct = entry.targetPct
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
    -- GetUnitSpeed's second return is ground run speed in yards/second, so only
    -- value resolution differs. Rating, visibility, hide-zero, columns, colors
    -- and formatting stay on the shared path.
    { label = "Speed", api = GetUnitSpeed, ratingCR = CR_SPEED, colorKey = "speed",
      showKey = "showSpeed", valueKind = "movement" },
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
    versTotalRating = nil,
    armorDR = nil,
    itemLevelOverall = nil,
    itemLevelEquipped = nil,
    itemLevelComplete = false,
    durabilityValue = nil,  -- selected projection of the last complete aggregate
    durabilityLastCompleteAverage = nil,
    durabilityLastCompleteWorst = nil,
    durabilityComplete = false, -- completeness of the latest scan, not cache freshness
    durabilityHasItems = false,
    repairCost = nil,       -- exact live repair cost; nil while any damaged slot is unresolved
    repairCostComplete = false,
    -- Last clean hide-zero decision per stat row. Secret combat reads cannot be safely
    -- compared to 0, so they reuse this instead of making absent rows appear.
    cleanRowVisibility = {},
    updateErrorCount = 0,
    lastUpdateError = nil,
    displayMode = "flat",
    labelStyle = "full",
    targetSnapshot = "mythicPlusCurrent",
    updateInterval = 0.5,
}

-- Dirty flag for event-driven cache refresh (durability scan is per-19-slot, not free)
local durabilityDirty = true

-- External inventory/config events open one fresh bounded-retry generation.
-- Timer callbacks never reset this budget, so stable nil tooltip data cannot
-- create an endless polling loop.
function addon.durabilityRuntime.MarkDirty()
    local runtime = addon.durabilityRuntime
    runtime.generation = runtime.generation + 1
    local durabilityRetry = runtime.retryStates.durability
    durabilityRetry.generation = runtime.generation
    durabilityRetry.attempt = 0
    durabilityRetry.scheduledGeneration = nil
    durabilityRetry.scheduledAttempt = nil
    local repairRetry = runtime.retryStates.repair
    repairRetry.generation = runtime.generation
    repairRetry.attempt = 0
    repairRetry.scheduledGeneration = nil
    repairRetry.scheduledAttempt = nil
    durabilityDirty = true
end

-- Durability and repair share one slot scan but own independent retry budgets.
-- WHY: durability can be entirely unavailable while equipment hydrates, so it must
-- not consume the later tooltip-repair attempts once equipped slots become readable.
function addon.durabilityRuntime.ScheduleRetry(kind, pending)
    local runtime = addon.durabilityRuntime
    local state = runtime.retryStates[kind]
    local generation = runtime.generation
    if state.generation ~= generation then
        state.generation = generation
        state.attempt = 0
        state.scheduledGeneration = nil
        state.scheduledAttempt = nil
    end
    if not pending then
        if state.scheduledGeneration == generation then
            state.scheduledGeneration = nil
            state.scheduledAttempt = nil
        end
        return
    end
    if state.scheduledGeneration == generation then return end

    local attempt = state.attempt + 1
    local delay = runtime.retryDelays[attempt]
    if not delay then return end
    state.attempt = attempt
    state.scheduledGeneration = generation
    state.scheduledAttempt = attempt
    C_Timer.After(delay, function()
        if runtime.generation ~= generation
                or state.generation ~= generation
                or state.attempt ~= attempt
                or state.scheduledGeneration ~= generation
                or state.scheduledAttempt ~= attempt then return end
        state.scheduledGeneration = nil
        state.scheduledAttempt = nil
        local shouldRetry
        if kind == "durability" then
            shouldRetry = cached.showDurability
                and cached.durabilityComplete == false and not InCombatLockdown()
        else
            shouldRetry = cached.showRepairCost and cached.repairCostComplete == false
        end
        if shouldRetry then durabilityDirty = true end
    end)
end
-- Dirty flag for item-level refresh (overall iLvl can change from gear or bags)
local itemLevelDirty = true
function addon.itemLevelRuntime.MarkDirty()
    local runtime = addon.itemLevelRuntime
    runtime.generation = runtime.generation + 1
    runtime.attempt = 0
    cached.itemLevelComplete = false
    itemLevelDirty = true
end
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
--   enUS (canonical source table with a few intentional display-name aliases)
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
--   - hardcoded literal keys in special-case branches: "Vers" / "Armor"
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
        -- ===== Settings UI strings =====
        -- Tabs (Defensive reuses the existing key above):
        ["Stats"] = "Stats", ["Layout"] = "Layout", ["Appearance"] = "Appearance",
        -- Section headers / split block labels (Durability reuses the existing key above):
        ["Character"] = "Character", ["Item Level"] = "Item Level",
        ["Offensive"] = "Offensive", ["Tertiary"] = "Tertiary",
        ["Gear"] = "Gear", ["Repair Cost"] = "Repair Cost",
        ["Side Panel Contains"] = "Side Panel Contains",
        ["Value Display"] = "Value Display",
        ["Frame & Position"] = "Frame & Position",
        ["Typography"] = "Typography",
        ["Appearance Presets"] = "Appearance Presets", ["Preset:"] = "Preset:",
        ["Default"] = "Default", ["Classic"] = "Classic", ["Clean Dark"] = "Clean Dark", ["Midnight"] = "Midnight",
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
        ["Raid Normal"] = "Raid Normal", ["Raid Heroic"] = "Raid Heroic", ["Raid Mythic"] = "Raid Mythic",
        ["Full"] = "Full", ["Short"] = "Short", ["Hidden"] = "Hidden",
        ["None"] = "None", ["Outline"] = "Outline", ["Thick Outline"] = "Thick Outline",
        ["M+ Target"] = "M+ Target", ["Raid Target"] = "Raid Target",
        ["M+ High Keys"] = "M+ High Keys", ["Raid Mythic All Bosses"] = "Raid Mythic All Bosses",
        ["M+ Current"] = "M+ Current", ["Raid Normal All Bosses"] = "Raid Normal All Bosses", ["Raid Heroic All Bosses"] = "Raid Heroic All Bosses",
        ["Target:"] = "Target:", ["Current:"] = "Current:", ["Missing:"] = "Missing:",
        ["Over:"] = "Over:", ["Matched:"] = "Matched:", ["Snapshot:"] = "Snapshot:",
        ["Last known comparison"] = "Last known comparison", ["Live values; comparison unavailable"] = "Live values; comparison unavailable", ["Source:"] = "Source:",
        ["Stats panel shown"] = "Stats panel shown", ["Stats panel hidden"] = "Stats panel hidden",
        ["Settings reset to defaults"] = "Settings reset to defaults",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help"] = "Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again.",
        ["SwiftStats has no supported settings to import."] = "SwiftStats has no supported settings to import.",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "These settings use a newer schema and cannot be imported by this StatsPro version.",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them.",
        ["StatsPro saved data is corrupted and remains read-only. Use /ss wipe outside combat to reset it."] = "StatsPro saved data is corrupted and remains read-only. Use /ss wipe outside combat to reset it.",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "SwiftStats import is unavailable during combat. Try again after combat.",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged.",
        ["Import"] = "Import",
        ["SwiftStats settings imported into new profile \"%s\"."] = "SwiftStats settings imported into new profile \"%s\".",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "SwiftStats import failed; profiles and assignments were preserved.",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged.",
        ["Reset corrupted StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position."] = "Reset corrupted StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position.",
        ["All StatsPro data reset to defaults."] = "All StatsPro data reset to defaults.",
        -- Buttons + title:
        ["Close"] = "Close",
        ["Contact"] = "Contact", ["Click to copy the link."] = "Click to copy the link.",
        ["Copy the link below (Ctrl+C)."] = "Copy the link below (Ctrl+C).",
        ["Open Settings"] = "Open Settings", ["Settings"] = "Settings",
        ["Profiles & sharing..."] = "Profiles...", ["Profiles & sharing"] = "Profiles & sharing",
        ["Shared with %d specializations"] = "Shared with %d specializations",
        ["Unknown specialization (%d)"] = "Unknown specialization (%d)",
        ["Copy settings from..."] = "Copy settings from...", ["Use the same settings as..."] = "Use the same settings as...",
        ["Use these settings for..."] = "Use these settings for...", ["Stop sharing..."] = "Stop sharing...",
        ["Advanced..."] = "Advanced...", ["Hide advanced"] = "Hide advanced",
        ["Reset these settings..."] = "Reset these settings...", ["Forget this character..."] = "Forget this character...",
        ["Defaults for future specializations..."] = "Defaults for future specializations...", ["Delete unused settings..."] = "Delete unused settings...",
        ["Copy %s from \"%s\" to \"%s\"? The destination will keep its own settings afterward."] = "Copy %s from \"%s\" to \"%s\"? The destination will keep its own settings afterward.",
        ["Use the same settings for \"%s\" and \"%s\"? Future changes will affect both."] = "Use the same settings for \"%s\" and \"%s\"? Future changes will affect both.",
        ["Use the shared settings from \"%s\" for \"%s\"? They are already shared by %d specializations; future changes will affect all %d."] = "Use the shared settings from \"%s\" for \"%s\"? They are already shared by %d specializations; future changes will affect all %d.",
        ["Give \"%s\" its own copy of these settings? Future changes will no longer affect the other specializations."] = "Give \"%s\" its own copy of these settings? Future changes will no longer affect the other specializations.",
        ["Reset the settings used by \"%s\"? The same reset will affect %d specializations."] = "Reset the settings used by \"%s\"? The same reset will affect %d specializations.",
        ["Reset the settings used by \"%s\" to defaults?"] = "Reset the settings used by \"%s\" to defaults?",
        ["This profile is also a default for future specializations; they will use the reset settings."] = "This profile is also a default for future specializations; they will use the reset settings.",
        ["Delete %d unused settings records? Settings currently used by a specialization or future-specialization default will be kept."] = "Delete %d unused settings records? Settings currently used by a specialization or future-specialization default will be kept.",
        ["Switch pending until combat ends"] = "Switch pending until combat ends", ["Account default profile"] = "Account default profile",
        ["Current"] = "Current", ["Active"] = "Active",
        ["No visited characters"] = "No visited characters",
        ["Spec %d"] = "Spec %d", ["Profile changes are unavailable during combat."] = "Profile changes are unavailable during combat.",
        ["Waiting for a safe profile context."] = "Waiting for a safe profile context.",
        ["Compatibility mode - profiles are read-only."] = "Compatibility mode - profiles are read-only.",
        ["Corrupted data - profiles are read-only. Use /ss wipe to reset."] = "Corrupted data - profiles are read-only. Use /ss wipe to reset.",
        ["All settings"] = "All settings", ["Stat and gear settings"] = "Stat and gear settings", ["Layout settings"] = "Layout settings", ["Appearance settings"] = "Appearance settings", ["Choose settings to copy"] = "Choose settings to copy",
        ["Confirm"] = "Confirm", ["Cancel"] = "Cancel",
        ["Tank"] = "Tank", ["Healer"] = "Healer", ["Damage"] = "Damage",
        ["Choose a role"] = "Choose a role",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy.",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy.",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy.",
        ["Profile changes saved."] = "Profile changes saved.", ["Enter a valid profile name."] = "Enter a valid profile name.",
        ["A profile with this name already exists."] = "A profile with this name already exists.",
        ["Profiles changed; review and try again."] = "Profiles changed; review and try again.",
        ["The current character cannot be forgotten."] = "The current character cannot be forgotten.",
        ["Nothing changed."] = "Nothing changed.",
        ["Profile operation failed. Review the selection and try again."] = "Profile operation failed. Review the selection and try again.",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references.",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "Forget \"%s\"? Its character record will be removed, but profile settings will be kept.",
        -- Templates:
        ["Auto (current: %s)"] = "Auto (current: %s)",
        ["Western European text"] = "Western European text",
        ["Russian text"] = "Russian text",
        ["Korean text"] = "Korean text",
        ["Simplified Chinese text"] = "Simplified Chinese text",
        ["Traditional Chinese text"] = "Traditional Chinese text",
        ["text for the selected language"] = "text for the selected language",
        ["|cffffaa44⚠|r The selected font may not render %s correctly. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r The selected font may not render %s correctly. Pick a SharedMedia font with proper coverage.",
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
        -- ===== Settings UI =====
        -- Tabs (Defensive uses "Защита" via the existing key above):
        ["Stats"] = "Статы", ["Layout"] = "Макет", ["Appearance"] = "Внешний вид",
        -- Section headers / split block labels (Durability reuses "Проч" — short form):
        ["Character"] = "Персонаж", ["Item Level"] = "Уровень предметов",
        ["Offensive"] = "Атака", ["Tertiary"] = "Третичные",
        ["Gear"] = "Экипировка", ["Repair Cost"] = "Стоимость ремонта",
        ["Side Panel Contains"] = "В боковой панели",
        ["Value Display"] = "Отображение значений",
        ["Frame & Position"] = "Окно и позиция",
        ["Typography"] = "Типографика",
        ["Appearance Presets"] = "Пресеты оформления", ["Preset:"] = "Пресет:",
        ["Default"] = "По умолчанию", ["Classic"] = "Классика", ["Clean Dark"] = "Чистый тёмный", ["Midnight"] = "Полночь",
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
        ["Raid Normal"] = "Рейд: обычный", ["Raid Heroic"] = "Рейд: героический", ["Raid Mythic"] = "Рейд: эпохальный",
        ["Full"] = "Полный", ["Short"] = "Короткий", ["Hidden"] = "Скрытый",
        ["None"] = "Нет", ["Outline"] = "Контур", ["Thick Outline"] = "Толстый контур",
        ["M+ Target"] = "Цель M+", ["Raid Target"] = "Цель рейда",
        ["M+ High Keys"] = "M+ высокие ключи", ["Raid Mythic All Bosses"] = "Эпох. рейд, все боссы",
        ["M+ Current"] = "M+ текущие ключи", ["Raid Normal All Bosses"] = "Обычный рейд, все боссы", ["Raid Heroic All Bosses"] = "Героический рейд, все боссы",
        ["Target:"] = "Цель:", ["Current:"] = "Сейчас:", ["Missing:"] = "Не хватает:",
        ["Over:"] = "Сверх:", ["Matched:"] = "Совпало:", ["Snapshot:"] = "Снимок:",
        ["Last known comparison"] = "Последнее известное сравнение", ["Live values; comparison unavailable"] = "Актуальные значения; сравнение недоступно", ["Source:"] = "Источник:",
        ["Stats panel shown"] = "Панель статов показана", ["Stats panel hidden"] = "Панель статов скрыта",
        ["Settings reset to defaults"] = "Настройки сброшены по умолчанию",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help"] = "Команды: /ss или /statspro (настройки), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "Настройки SwiftStats не загружены. Включите SwiftStats на один вход в игру, выполните /reload, затем снова введите /statspro import.",
        ["SwiftStats has no supported settings to import."] = "В SwiftStats нет поддерживаемых настроек для импорта.",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "Эти настройки используют более новую схему и не могут быть импортированы этой версией StatsPro.",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "Настройки доступны только для чтения, поскольку они сохранены более новой версией StatsPro. Обновите StatsPro, чтобы изменять их.",
        ["StatsPro saved data is corrupted and remains read-only. Use /ss wipe outside combat to reset it."] = "Сохранённые данные StatsPro повреждены и остаются доступными только для чтения. Используйте /ss wipe вне боя, чтобы сбросить их.",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "Импорт SwiftStats недоступен в бою. Повторите после боя.",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "Импортировать совместимые настройки SwiftStats в новый профиль для текущего персонажа и специализации? Существующие профили, другие назначения, настройки аккаунта и данные SwiftStats останутся без изменений.",
        ["Import"] = "Импорт",
        ["SwiftStats settings imported into new profile \"%s\"."] = "Настройки SwiftStats импортированы в новый профиль «%s».",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "Не удалось импортировать SwiftStats; профили и назначения сохранены.",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "Сбросить все данные StatsPro? Это безвозвратно удалит все профили, назначения персонажей и специализаций, шаблоны ролей, настройки аккаунта и сохранённые позиции. Данные SwiftStats останутся без изменений.",
        ["Reset corrupted StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position."] = "Сбросить повреждённые данные StatsPro? Это безвозвратно удалит все профили, назначения персонажей и специализаций, шаблоны ролей, настройки аккаунта и сохранённые позиции.",
        ["All StatsPro data reset to defaults."] = "Все данные StatsPro сброшены до значений по умолчанию.",
        -- Buttons + title:
        ["Close"] = "Закрыть",
        ["Contact"] = "Связаться", ["Click to copy the link."] = "Нажмите, чтобы скопировать ссылку.",
        ["Copy the link below (Ctrl+C)."] = "Скопируйте ссылку ниже (Ctrl+C).",
        ["Open Settings"] = "Открыть настройки", ["Settings"] = "Настройки",
        ["Profiles & sharing..."] = "Профили...", ["Profiles & sharing"] = "Профили и общий доступ",
        ["Shared with %d specializations"] = "Общие настройки для специализаций: %d",
        ["Unknown specialization (%d)"] = "Неизвестная специализация (%d)",
        ["Copy settings from..."] = "Скопировать настройки из...", ["Use the same settings as..."] = "Использовать общие настройки с...",
        ["Use these settings for..."] = "Использовать эти настройки для...", ["Stop sharing..."] = "Отделить настройки...",
        ["Advanced..."] = "Дополнительно...", ["Hide advanced"] = "Скрыть дополнительные",
        ["Reset these settings..."] = "Сбросить эти настройки...", ["Forget this character..."] = "Забыть этого персонажа...",
        ["Defaults for future specializations..."] = "Настройки для будущих специализаций...", ["Delete unused settings..."] = "Удалить неиспользуемые настройки...",
        ["Copy %s from \"%s\" to \"%s\"? The destination will keep its own settings afterward."] = "Скопировать %s из «%s» в «%s»? После этого у назначения останутся собственные настройки.",
        ["Use the same settings for \"%s\" and \"%s\"? Future changes will affect both."] = "Использовать общие настройки для «%s» и «%s»? Последующие изменения затронут обе специализации.",
        ["Use the shared settings from \"%s\" for \"%s\"? They are already shared by %d specializations; future changes will affect all %d."] = "Использовать общие настройки из «%s» для «%s»? Их уже используют %d специализации; последующие изменения затронут все %d.",
        ["Give \"%s\" its own copy of these settings? Future changes will no longer affect the other specializations."] = "Создать для «%s» отдельную копию этих настроек? Последующие изменения больше не затронут другие специализации.",
        ["Reset the settings used by \"%s\"? The same reset will affect %d specializations."] = "Сбросить настройки, используемые «%s»? Этот же сброс затронет %d специализаций.",
        ["Reset the settings used by \"%s\" to defaults?"] = "Сбросить настройки, используемые «%s», до стандартных?",
        ["This profile is also a default for future specializations; they will use the reset settings."] = "Этот профиль также задан по умолчанию для будущих специализаций; после сброса они будут использовать сброшенные настройки.",
        ["Delete %d unused settings records? Settings currently used by a specialization or future-specialization default will be kept."] = "Удалить неиспользуемые записи настроек (%d)? Настройки специализаций и шаблоны для будущих специализаций будут сохранены.",
        ["Switch pending until combat ends"] = "Переключение после окончания боя", ["Account default profile"] = "Профиль аккаунта по умолчанию",
        ["Current"] = "Текущий", ["Active"] = "Активно",
        ["No visited characters"] = "Нет посещённых персонажей",
        ["Spec %d"] = "Специализация %d", ["Profile changes are unavailable during combat."] = "Изменение профилей недоступно в бою.",
        ["Waiting for a safe profile context."] = "Ожидание безопасного контекста профиля.",
        ["Compatibility mode - profiles are read-only."] = "Режим совместимости — профили доступны только для чтения.",
        ["Corrupted data - profiles are read-only. Use /ss wipe to reset."] = "Данные повреждены — профили доступны только для чтения. Используйте /ss wipe для сброса.",
        ["All settings"] = "Все настройки", ["Stat and gear settings"] = "Показатели и экипировка", ["Layout settings"] = "Расположение", ["Appearance settings"] = "Внешний вид", ["Choose settings to copy"] = "Выберите настройки для копирования",
        ["Confirm"] = "Подтвердить", ["Cancel"] = "Отмена",
        ["Tank"] = "Танк", ["Healer"] = "Лекарь", ["Damage"] = "Урон",
        ["Choose a role"] = "Выберите роль",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "Использовать «%s» как источник для будущих специализаций танка? Существующие назначения не изменятся; каждый новый контекст получит независимую копию.",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "Использовать «%s» как источник для будущих специализаций лекаря? Существующие назначения не изменятся; каждый новый контекст получит независимую копию.",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "Использовать «%s» как источник для будущих специализаций урона? Существующие назначения не изменятся; каждый новый контекст получит независимую копию.",
        ["Profile changes saved."] = "Изменения профилей сохранены.", ["Enter a valid profile name."] = "Введите допустимое имя профиля.",
        ["A profile with this name already exists."] = "Профиль с таким именем уже существует.",
        ["Profiles changed; review and try again."] = "Профили изменились. Проверьте выбор и повторите попытку.",
        ["The current character cannot be forgotten."] = "Текущего персонажа нельзя забыть.",
        ["Nothing changed."] = "Ничего не изменилось.",
        ["Profile operation failed. Review the selection and try again."] = "Операция с профилем не выполнена. Проверьте выбор и повторите попытку.",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "Сбросить активный профиль «%s»? Будут изменены специализации: %d, другие ссылки: %d.",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "Забыть «%s»? Запись персонажа будет удалена, но настройки профилей сохранятся.",
        -- Templates:
        ["Auto (current: %s)"] = "Авто (сейчас: %s)",
        ["Western European text"] = "западноевропейский текст",
        ["Russian text"] = "русский текст",
        ["Korean text"] = "корейский текст",
        ["Simplified Chinese text"] = "текст на упрощённом китайском",
        ["Traditional Chinese text"] = "текст на традиционном китайском",
        ["text for the selected language"] = "текст выбранного языка",
        ["|cffffaa44⚠|r The selected font may not render %s correctly. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r Шрифт может некорректно отображать %s. Выберите шрифт SharedMedia с нужным покрытием.",
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
        -- ===== Settings UI (best-effort draft, native-speaker review welcome via Issues) =====
        -- Movement checkbox uses the long form to disambiguate from Haste="Tempo".
        ["Stats"] = "Werte", ["Layout"] = "Layout", ["Appearance"] = "Darstellung",
        ["Character"] = "Charakter", ["Item Level"] = "Gegenstandsstufe",
        ["Offensive"] = "Offensiv", ["Tertiary"] = "Tertiär",
        ["Gear"] = "Ausrüstung", ["Repair Cost"] = "Reparaturkosten",
        ["Side Panel Contains"] = "Seitenpanel enthält",
        ["Value Display"] = "Werteanzeige",
        ["Frame & Position"] = "Fenster & Position",
        ["Typography"] = "Typografie",
        ["Appearance Presets"] = "Darstellungsvorlagen", ["Preset:"] = "Vorlage:",
        ["Default"] = "Standard", ["Classic"] = "Klassisch", ["Clean Dark"] = "Klar Dunkel", ["Midnight"] = "Mitternacht",
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
        ["Raid Normal"] = "Raid Normal", ["Raid Heroic"] = "Raid Heroisch", ["Raid Mythic"] = "Raid Mythisch",
        ["Full"] = "Voll", ["Short"] = "Kurz", ["Hidden"] = "Versteckt",
        ["None"] = "Keine", ["Outline"] = "Kontur", ["Thick Outline"] = "Dicke Kontur",
        ["M+ Target"] = "M+ Ziel", ["Raid Target"] = "Raid-Ziel",
        ["M+ High Keys"] = "M+ hohe Schlüssel", ["Raid Mythic All Bosses"] = "Raid Mythisch alle Bosse",
        ["M+ Current"] = "M+ aktuell", ["Raid Normal All Bosses"] = "Raid Normal alle Bosse", ["Raid Heroic All Bosses"] = "Raid Heroisch alle Bosse",
        ["Target:"] = "Ziel:", ["Current:"] = "Aktuell:", ["Missing:"] = "Fehlt:",
        ["Over:"] = "Drüber:", ["Matched:"] = "Erreicht:", ["Snapshot:"] = "Datenstand:",
        ["Last known comparison"] = "Letzter bekannter Vergleich", ["Live values; comparison unavailable"] = "Live-Werte; Vergleich nicht verfügbar", ["Source:"] = "Quelle:",
        ["Stats panel shown"] = "Statpanel angezeigt", ["Stats panel hidden"] = "Statpanel ausgeblendet",
        ["Settings reset to defaults"] = "Einstellungen auf Standard zurückgesetzt",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help"] = "Befehle: /ss oder /statspro (Einstellungen), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "SwiftStats-Einstellungen sind nicht geladen. Aktiviere SwiftStats für eine Anmeldung, führe /reload aus und gib danach erneut /statspro import ein.",
        ["SwiftStats has no supported settings to import."] = "SwiftStats enthält keine unterstützten Einstellungen zum Importieren.",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "Diese Einstellungen verwenden ein neueres Schema und können von dieser StatsPro-Version nicht importiert werden.",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "Die Einstellungen sind schreibgeschützt, da sie mit einer neueren StatsPro-Version gespeichert wurden. Aktualisiere StatsPro, um sie zu ändern.",
        ["StatsPro saved data is corrupted and remains read-only. Use /ss wipe outside combat to reset it."] = "Gespeicherte StatsPro-Daten sind beschädigt und bleiben schreibgeschützt. Verwende außerhalb des Kampfes /ss wipe, um sie zurückzusetzen.",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "Der SwiftStats-Import ist im Kampf nicht verfügbar. Versuche es nach dem Kampf erneut.",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "Kompatible SwiftStats-Einstellungen in ein neues Profil für den aktuellen Charakter und die aktuelle Spezialisierung importieren? Bestehende Profile, andere Zuweisungen, Kontoeinstellungen und SwiftStats-Daten bleiben unverändert.",
        ["Import"] = "Importieren",
        ["SwiftStats settings imported into new profile \"%s\"."] = "SwiftStats-Einstellungen wurden in das neue Profil „%s“ importiert.",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "SwiftStats-Import fehlgeschlagen; Profile und Zuweisungen wurden beibehalten.",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "Alle StatsPro-Daten zurücksetzen? Dadurch werden dauerhaft alle Profile, Charakter- und Spezialisierungszuweisungen, Rollenvorlagen, Kontoeinstellungen und gespeicherten Positionen entfernt. SwiftStats-Daten bleiben unverändert.",
        ["Reset corrupted StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position."] = "Beschädigte StatsPro-Daten zurücksetzen? Dadurch werden dauerhaft alle Profile, Charakter- und Spezialisierungszuweisungen, Rollenvorlagen, Kontoeinstellungen und gespeicherten Positionen entfernt.",
        ["All StatsPro data reset to defaults."] = "Alle StatsPro-Daten wurden auf die Standardwerte zurückgesetzt.",
        ["Close"] = "Schließen",
        ["Contact"] = "Kontakt", ["Click to copy the link."] = "Klicken, um den Link zu kopieren.",
        ["Copy the link below (Ctrl+C)."] = "Kopiere den Link unten (Strg+C).",
        ["Open Settings"] = "Einstellungen öffnen", ["Settings"] = "Einstellungen",
        ["Profiles & sharing..."] = "Profile...", ["Profiles & sharing"] = "Profile und Freigabe",
        ["Shared with %d specializations"] = "Mit %d Spezialisierungen geteilt",
        ["Unknown specialization (%d)"] = "Unbekannte Spezialisierung (%d)",
        ["Copy settings from..."] = "Einstellungen kopieren von...", ["Use the same settings as..."] = "Dieselben Einstellungen verwenden wie...",
        ["Use these settings for..."] = "Diese Einstellungen verwenden für...", ["Stop sharing..."] = "Freigabe beenden...",
        ["Advanced..."] = "Erweitert...", ["Hide advanced"] = "Erweitert ausblenden",
        ["Reset these settings..."] = "Diese Einstellungen zurücksetzen...", ["Forget this character..."] = "Diesen Charakter vergessen...",
        ["Defaults for future specializations..."] = "Standardwerte für zukünftige Spezialisierungen...", ["Delete unused settings..."] = "Nicht verwendete Einstellungen löschen...",
        ["Copy %s from \"%s\" to \"%s\"? The destination will keep its own settings afterward."] = "%s von „%s“ nach „%s“ kopieren? Das Ziel behält danach eigene Einstellungen.",
        ["Use the same settings for \"%s\" and \"%s\"? Future changes will affect both."] = "Dieselben Einstellungen für „%s“ und „%s“ verwenden? Künftige Änderungen wirken sich auf beide aus.",
        ["Use the shared settings from \"%s\" for \"%s\"? They are already shared by %d specializations; future changes will affect all %d."] = "Die geteilten Einstellungen von „%s“ für „%s“ verwenden? Sie werden bereits von %d Spezialisierungen verwendet; künftige Änderungen betreffen alle %d.",
        ["Give \"%s\" its own copy of these settings? Future changes will no longer affect the other specializations."] = "„%s“ eine eigene Kopie dieser Einstellungen geben? Künftige Änderungen wirken sich nicht mehr auf die anderen Spezialisierungen aus.",
        ["Reset the settings used by \"%s\"? The same reset will affect %d specializations."] = "Die von „%s“ verwendeten Einstellungen zurücksetzen? Derselbe Reset betrifft %d Spezialisierungen.",
        ["Reset the settings used by \"%s\" to defaults?"] = "Die von „%s“ verwendeten Einstellungen auf Standardwerte zurücksetzen?",
        ["This profile is also a default for future specializations; they will use the reset settings."] = "Dieses Profil ist auch ein Standardwert für zukünftige Spezialisierungen; sie verwenden danach die zurückgesetzten Einstellungen.",
        ["Delete %d unused settings records? Settings currently used by a specialization or future-specialization default will be kept."] = "%d nicht verwendete Einstellungsdatensätze löschen? Verwendete Einstellungen und Standardwerte für zukünftige Spezialisierungen bleiben erhalten.",
        ["Switch pending until combat ends"] = "Wechsel nach Kampfende", ["Account default profile"] = "Standardprofil des Accounts",
        ["Current"] = "Aktuell", ["Active"] = "Aktiv",
        ["No visited characters"] = "Keine besuchten Charaktere",
        ["Spec %d"] = "Spezialisierung %d", ["Profile changes are unavailable during combat."] = "Profiländerungen sind im Kampf nicht verfügbar.",
        ["Waiting for a safe profile context."] = "Warten auf einen sicheren Profilkontext.",
        ["Compatibility mode - profiles are read-only."] = "Kompatibilitätsmodus – Profile sind schreibgeschützt.",
        ["Corrupted data - profiles are read-only. Use /ss wipe to reset."] = "Beschädigte Daten – Profile sind schreibgeschützt. Mit /ss wipe zurücksetzen.",
        ["All settings"] = "Alle Einstellungen", ["Stat and gear settings"] = "Werte und Ausrüstung", ["Layout settings"] = "Layout-Einstellungen", ["Appearance settings"] = "Darstellung", ["Choose settings to copy"] = "Zu kopierende Einstellungen auswählen",
        ["Confirm"] = "Bestätigen", ["Cancel"] = "Abbrechen",
        ["Tank"] = "Tank", ["Healer"] = "Heiler", ["Damage"] = "Schaden",
        ["Choose a role"] = "Rolle auswählen",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "„%s“ als Quelle für künftige Tank-Kontexte verwenden? Bestehende Zuweisungen ändern sich nicht; jeder neue Kontext erhält eine unabhängige Kopie.",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "„%s“ als Quelle für künftige Heiler-Kontexte verwenden? Bestehende Zuweisungen ändern sich nicht; jeder neue Kontext erhält eine unabhängige Kopie.",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "„%s“ als Quelle für künftige Schadenskontexte verwenden? Bestehende Zuweisungen ändern sich nicht; jeder neue Kontext erhält eine unabhängige Kopie.",
        ["Profile changes saved."] = "Profiländerungen gespeichert.", ["Enter a valid profile name."] = "Gib einen gültigen Profilnamen ein.",
        ["A profile with this name already exists."] = "Ein Profil mit diesem Namen existiert bereits.",
        ["Profiles changed; review and try again."] = "Die Profile wurden geändert. Prüfe die Auswahl und versuche es erneut.",
        ["The current character cannot be forgotten."] = "Der aktuelle Charakter kann nicht vergessen werden.",
        ["Nothing changed."] = "Es wurde nichts geändert.",
        ["Profile operation failed. Review the selection and try again."] = "Der Profilvorgang ist fehlgeschlagen. Prüfe die Auswahl und versuche es erneut.",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "Aktives Profil „%s“ auf Standardwerte zurücksetzen? Geändert werden %d zugewiesene Spezialisierungen und %d weitere Verweise.",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "„%s“ vergessen? Der Charaktereintrag wird entfernt, die Profileinstellungen bleiben erhalten.",
        ["Auto (current: %s)"] = "Auto (aktuell: %s)",
        ["Western European text"] = "westeuropäischen Text",
        ["Russian text"] = "russischen Text",
        ["Korean text"] = "koreanischen Text",
        ["Simplified Chinese text"] = "vereinfachtes Chinesisch",
        ["Traditional Chinese text"] = "traditionelles Chinesisch",
        ["text for the selected language"] = "Text der ausgewählten Sprache",
        ["|cffffaa44⚠|r The selected font may not render %s correctly. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r Die Schrift stellt %s möglicherweise nicht korrekt dar. Wähle eine SharedMedia-Schrift mit passender Zeichenabdeckung.",
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
        -- ===== Settings UI (best-effort draft, native-speaker review welcome via Issues) =====
        ["Stats"] = "Stats", ["Layout"] = "Disposition", ["Appearance"] = "Apparence",
        ["Character"] = "Personnage", ["Item Level"] = "Niveau d'objet",
        ["Offensive"] = "Offensif", ["Tertiary"] = "Tertiaire",
        ["Gear"] = "Équipement", ["Repair Cost"] = "Coût de réparation",
        ["Side Panel Contains"] = "Panneau latéral contient",
        ["Value Display"] = "Affichage des valeurs",
        ["Frame & Position"] = "Cadre & Position",
        ["Typography"] = "Typographie",
        ["Appearance Presets"] = "Préréglages d'apparence", ["Preset:"] = "Préréglage :",
        ["Default"] = "Par défaut", ["Classic"] = "Classique", ["Clean Dark"] = "Sombre épuré", ["Midnight"] = "Minuit",
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
        ["Raid Normal"] = "Raid normal", ["Raid Heroic"] = "Raid héroïque", ["Raid Mythic"] = "Raid mythique",
        ["Full"] = "Complet", ["Short"] = "Court", ["Hidden"] = "Masqué",
        ["None"] = "Aucun", ["Outline"] = "Contour", ["Thick Outline"] = "Contour épais",
        ["M+ Target"] = "Cible M+", ["Raid Target"] = "Cible raid",
        ["M+ High Keys"] = "M+ hautes clés", ["Raid Mythic All Bosses"] = "Raid mythique tous les boss",
        ["M+ Current"] = "M+ actuel", ["Raid Normal All Bosses"] = "Raid normal tous les boss", ["Raid Heroic All Bosses"] = "Raid héroïque tous les boss",
        ["Target:"] = "Cible :", ["Current:"] = "Actuel :", ["Missing:"] = "Manquant :",
        ["Over:"] = "Excès :", ["Matched:"] = "Atteint :", ["Snapshot:"] = "Instantané :",
        ["Last known comparison"] = "Dernière comparaison connue", ["Live values; comparison unavailable"] = "Valeurs en direct ; comparaison indisponible", ["Source:"] = "Source :",
        ["Stats panel shown"] = "Panneau de stats affiché", ["Stats panel hidden"] = "Panneau de stats masqué",
        ["Settings reset to defaults"] = "Paramètres réinitialisés",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help"] = "Commandes : /ss ou /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "Les réglages de SwiftStats ne sont pas chargés. Activez SwiftStats pour une connexion, exécutez /reload, puis relancez /statspro import.",
        ["SwiftStats has no supported settings to import."] = "SwiftStats ne contient aucun réglage pris en charge à importer.",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "Ces réglages utilisent un schéma plus récent et ne peuvent pas être importés par cette version de StatsPro.",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "Les paramètres sont en lecture seule, car ils ont été enregistrés par une version plus récente de StatsPro. Mettez StatsPro à jour pour les modifier.",
        ["StatsPro saved data is corrupted and remains read-only. Use /ss wipe outside combat to reset it."] = "Les données enregistrées de StatsPro sont corrompues et restent en lecture seule. Utilisez /ss wipe hors combat pour les réinitialiser.",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "L’importation SwiftStats est indisponible en combat. Réessayez après le combat.",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "Importer les réglages SwiftStats compatibles dans un nouveau profil pour le personnage et la spécialisation actuels ? Les profils existants, les autres affectations, les paramètres du compte et les données SwiftStats resteront inchangés.",
        ["Import"] = "Importer",
        ["SwiftStats settings imported into new profile \"%s\"."] = "Réglages SwiftStats importés dans le nouveau profil « %s ».",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "Échec de l’importation SwiftStats ; les profils et les affectations ont été conservés.",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "Réinitialiser toutes les données StatsPro ? Cela supprimera définitivement tous les profils, les affectations de personnages et de spécialisations, les modèles de rôle, les paramètres du compte et les positions enregistrées. Les données SwiftStats resteront inchangées.",
        ["Reset corrupted StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position."] = "Réinitialiser les données StatsPro corrompues ? Cela supprimera définitivement tous les profils, les affectations de personnages et de spécialisations, les modèles de rôle, les paramètres du compte et les positions enregistrées.",
        ["All StatsPro data reset to defaults."] = "Toutes les données StatsPro ont été réinitialisées aux valeurs par défaut.",
        ["Close"] = "Fermer",
        ["Contact"] = "Contact", ["Click to copy the link."] = "Cliquez pour copier le lien.",
        ["Copy the link below (Ctrl+C)."] = "Copiez le lien ci-dessous (Ctrl+C).",
        ["Open Settings"] = "Ouvrir les paramètres", ["Settings"] = "Paramètres",
        ["Profiles & sharing..."] = "Profils...", ["Profiles & sharing"] = "Profils et partage",
        ["Shared with %d specializations"] = "Partagé avec %d spécialisations",
        ["Unknown specialization (%d)"] = "Spécialisation inconnue (%d)",
        ["Copy settings from..."] = "Copier les réglages depuis...", ["Use the same settings as..."] = "Utiliser les mêmes réglages que...",
        ["Use these settings for..."] = "Utiliser ces réglages pour...", ["Stop sharing..."] = "Arrêter le partage...",
        ["Advanced..."] = "Avancé...", ["Hide advanced"] = "Masquer les options avancées",
        ["Reset these settings..."] = "Réinitialiser ces réglages...", ["Forget this character..."] = "Oublier ce personnage...",
        ["Defaults for future specializations..."] = "Réglages des futures spécialisations...", ["Delete unused settings..."] = "Supprimer les réglages inutilisés...",
        ["Copy %s from \"%s\" to \"%s\"? The destination will keep its own settings afterward."] = "Copier %s de « %s » vers « %s » ? La destination conservera ensuite ses propres réglages.",
        ["Use the same settings for \"%s\" and \"%s\"? Future changes will affect both."] = "Utiliser les mêmes réglages pour « %s » et « %s » ? Les futures modifications affecteront les deux.",
        ["Use the shared settings from \"%s\" for \"%s\"? They are already shared by %d specializations; future changes will affect all %d."] = "Utiliser les réglages partagés de « %s » pour « %s » ? Ils sont déjà partagés par %d spécialisations ; les futures modifications affecteront les %d.",
        ["Give \"%s\" its own copy of these settings? Future changes will no longer affect the other specializations."] = "Donner à « %s » sa propre copie de ces réglages ? Les futures modifications n’affecteront plus les autres spécialisations.",
        ["Reset the settings used by \"%s\"? The same reset will affect %d specializations."] = "Réinitialiser les réglages utilisés par « %s » ? La même réinitialisation affectera %d spécialisations.",
        ["Reset the settings used by \"%s\" to defaults?"] = "Réinitialiser les réglages utilisés par « %s » ?",
        ["This profile is also a default for future specializations; they will use the reset settings."] = "Ce profil sert aussi de réglage par défaut aux futures spécialisations ; elles utiliseront les réglages réinitialisés.",
        ["Delete %d unused settings records? Settings currently used by a specialization or future-specialization default will be kept."] = "Supprimer %d ensembles de réglages inutilisés ? Les réglages utilisés et ceux des futures spécialisations seront conservés.",
        ["Switch pending until combat ends"] = "Changement après le combat", ["Account default profile"] = "Profil de compte par défaut",
        ["Current"] = "Actuel", ["Active"] = "Actif",
        ["No visited characters"] = "Aucun personnage visité",
        ["Spec %d"] = "Spécialisation %d", ["Profile changes are unavailable during combat."] = "Les changements de profil sont indisponibles en combat.",
        ["Waiting for a safe profile context."] = "En attente d’un contexte de profil sûr.",
        ["Compatibility mode - profiles are read-only."] = "Mode de compatibilité – les profils sont en lecture seule.",
        ["Corrupted data - profiles are read-only. Use /ss wipe to reset."] = "Données corrompues – les profils sont en lecture seule. Utilisez /ss wipe pour réinitialiser.",
        ["All settings"] = "Tous les réglages", ["Stat and gear settings"] = "Caractéristiques et équipement", ["Layout settings"] = "Disposition", ["Appearance settings"] = "Apparence", ["Choose settings to copy"] = "Choisir les réglages à copier",
        ["Confirm"] = "Confirmer", ["Cancel"] = "Annuler",
        ["Tank"] = "Tank", ["Healer"] = "Soigneur", ["Damage"] = "Dégâts",
        ["Choose a role"] = "Choisir un rôle",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "Utiliser « %s » comme source des futurs contextes Tank ? Les attributions existantes ne changeront pas ; chaque nouveau contexte recevra une copie indépendante.",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "Utiliser « %s » comme source des futurs contextes Soigneur ? Les attributions existantes ne changeront pas ; chaque nouveau contexte recevra une copie indépendante.",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "Utiliser « %s » comme source des futurs contextes Dégâts ? Les attributions existantes ne changeront pas ; chaque nouveau contexte recevra une copie indépendante.",
        ["Profile changes saved."] = "Modifications des profils enregistrées.", ["Enter a valid profile name."] = "Saisissez un nom de profil valide.",
        ["A profile with this name already exists."] = "Un profil portant ce nom existe déjà.",
        ["Profiles changed; review and try again."] = "Les profils ont changé. Vérifiez la sélection et réessayez.",
        ["The current character cannot be forgotten."] = "Le personnage actuel ne peut pas être oublié.",
        ["Nothing changed."] = "Aucune modification.",
        ["Profile operation failed. Review the selection and try again."] = "L’opération sur le profil a échoué. Vérifiez la sélection et réessayez.",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "Réinitialiser le profil actif « %s » ? Cela modifie %d spécialisations attribuées et %d autres références.",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "Oublier « %s » ? Sa fiche de personnage sera supprimée, mais les réglages des profils seront conservés.",
        ["Auto (current: %s)"] = "Auto (actuel : %s)",
        ["Western European text"] = "le texte d’Europe occidentale",
        ["Russian text"] = "le texte russe",
        ["Korean text"] = "le texte coréen",
        ["Simplified Chinese text"] = "le chinois simplifié",
        ["Traditional Chinese text"] = "le chinois traditionnel",
        ["text for the selected language"] = "le texte de la langue sélectionnée",
        ["|cffffaa44⚠|r The selected font may not render %s correctly. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r La police sélectionnée peut ne pas afficher correctement %s. Choisissez une police SharedMedia avec une couverture adaptée.",
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
        -- ===== Settings UI (best-effort draft, native-speaker review welcome via Issues) =====
        ["Stats"] = "Atributos", ["Layout"] = "Diseño", ["Appearance"] = "Apariencia",
        ["Character"] = "Personaje", ["Item Level"] = "Nivel de objeto",
        ["Offensive"] = "Ofensivo", ["Tertiary"] = "Terciario",
        ["Gear"] = "Equipo", ["Repair Cost"] = "Coste reparación",
        ["Side Panel Contains"] = "Panel lateral contiene",
        ["Value Display"] = "Valores",
        ["Frame & Position"] = "Marco y Posición",
        ["Typography"] = "Tipografía",
        ["Appearance Presets"] = "Preajustes de apariencia", ["Preset:"] = "Preajuste:",
        ["Default"] = "Predeterminado", ["Classic"] = "Clásico", ["Clean Dark"] = "Oscuro limpio", ["Midnight"] = "Medianoche",
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
        ["Raid Normal"] = "Banda normal", ["Raid Heroic"] = "Banda heroica", ["Raid Mythic"] = "Banda mítica",
        ["Full"] = "Completo", ["Short"] = "Corto", ["Hidden"] = "Oculto",
        ["None"] = "Ninguno", ["Outline"] = "Contorno", ["Thick Outline"] = "Contorno grueso",
        ["M+ Target"] = "Objetivo M+", ["Raid Target"] = "Objetivo banda",
        ["M+ High Keys"] = "M+ llaves altas", ["Raid Mythic All Bosses"] = "Banda mítica todos los jefes",
        ["M+ Current"] = "M+ actual", ["Raid Normal All Bosses"] = "Banda normal todos los jefes", ["Raid Heroic All Bosses"] = "Banda heroica todos los jefes",
        ["Target:"] = "Objetivo:", ["Current:"] = "Actual:", ["Missing:"] = "Falta:",
        ["Over:"] = "Exceso:", ["Matched:"] = "Igualado:", ["Snapshot:"] = "Captura:",
        ["Last known comparison"] = "Última comparación conocida", ["Live values; comparison unavailable"] = "Valores en vivo; comparación no disponible", ["Source:"] = "Fuente:",
        ["Stats panel shown"] = "Panel de estadísticas mostrado", ["Stats panel hidden"] = "Panel de estadísticas oculto",
        ["Settings reset to defaults"] = "Ajustes restablecidos",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help"] = "Comandos: /ss o /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "Los ajustes de SwiftStats no están cargados. Activa SwiftStats durante un inicio de sesión, ejecuta /reload y vuelve a usar /statspro import.",
        ["SwiftStats has no supported settings to import."] = "SwiftStats no tiene ajustes compatibles para importar.",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "Estos ajustes usan un esquema más reciente y esta versión de StatsPro no puede importarlos.",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "Los ajustes son de solo lectura porque se guardaron con una versión más reciente de StatsPro. Actualiza StatsPro para modificarlos.",
        ["StatsPro saved data is corrupted and remains read-only. Use /ss wipe outside combat to reset it."] = "Los datos guardados de StatsPro están dañados y permanecen en modo de solo lectura. Usa /ss wipe fuera de combate para restablecerlos.",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "La importación de SwiftStats no está disponible en combate. Inténtalo de nuevo después.",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "¿Importar la configuración compatible de SwiftStats en un perfil nuevo para el personaje y la especialización actuales? Los perfiles existentes, las demás asignaciones, la configuración de la cuenta y los datos de SwiftStats no cambiarán.",
        ["Import"] = "Importar",
        ["SwiftStats settings imported into new profile \"%s\"."] = "La configuración de SwiftStats se importó al perfil nuevo «%s».",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "La importación de SwiftStats falló; se conservaron los perfiles y las asignaciones.",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "¿Restablecer todos los datos de StatsPro? Esto eliminará permanentemente todos los perfiles, las asignaciones de personajes y especializaciones, las plantillas de rol, la configuración de la cuenta y las posiciones guardadas. Los datos de SwiftStats no cambiarán.",
        ["Reset corrupted StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position."] = "¿Restablecer los datos dañados de StatsPro? Esto eliminará permanentemente todos los perfiles, las asignaciones de personajes y especializaciones, las plantillas de rol, la configuración de la cuenta y las posiciones guardadas.",
        ["All StatsPro data reset to defaults."] = "Todos los datos de StatsPro se restablecieron a los valores predeterminados.",
        ["Close"] = "Cerrar",
        ["Contact"] = "Contacto", ["Click to copy the link."] = "Haz clic para copiar el enlace.",
        ["Copy the link below (Ctrl+C)."] = "Copia el enlace de abajo (Ctrl+C).",
        ["Open Settings"] = "Abrir ajustes", ["Settings"] = "Ajustes",
        ["Profiles & sharing..."] = "Perfiles...", ["Profiles & sharing"] = "Perfiles y uso compartido",
        ["Shared with %d specializations"] = "Compartido con %d especializaciones",
        ["Unknown specialization (%d)"] = "Especialización desconocida (%d)",
        ["Copy settings from..."] = "Copiar ajustes desde...", ["Use the same settings as..."] = "Usar los mismos ajustes que...",
        ["Use these settings for..."] = "Usar estos ajustes para...", ["Stop sharing..."] = "Dejar de compartir...",
        ["Advanced..."] = "Avanzado...", ["Hide advanced"] = "Ocultar opciones avanzadas",
        ["Reset these settings..."] = "Restablecer estos ajustes...", ["Forget this character..."] = "Olvidar este personaje...",
        ["Defaults for future specializations..."] = "Ajustes para futuras especializaciones...", ["Delete unused settings..."] = "Eliminar ajustes sin usar...",
        ["Copy %s from \"%s\" to \"%s\"? The destination will keep its own settings afterward."] = "¿Copiar %s de «%s» a «%s»? El destino conservará sus propios ajustes después.",
        ["Use the same settings for \"%s\" and \"%s\"? Future changes will affect both."] = "¿Usar los mismos ajustes para «%s» y «%s»? Los cambios futuros afectarán a ambos.",
        ["Use the shared settings from \"%s\" for \"%s\"? They are already shared by %d specializations; future changes will affect all %d."] = "¿Usar los ajustes compartidos de «%s» para «%s»? Ya los comparten %d especializaciones; los cambios futuros afectarán a las %d.",
        ["Give \"%s\" its own copy of these settings? Future changes will no longer affect the other specializations."] = "¿Dar a «%s» su propia copia de estos ajustes? Los cambios futuros ya no afectarán a las otras especializaciones.",
        ["Reset the settings used by \"%s\"? The same reset will affect %d specializations."] = "¿Restablecer los ajustes que usa «%s»? El mismo restablecimiento afectará a %d especializaciones.",
        ["Reset the settings used by \"%s\" to defaults?"] = "¿Restablecer los ajustes que usa «%s» a los valores predeterminados?",
        ["This profile is also a default for future specializations; they will use the reset settings."] = "Este perfil también es predeterminado para futuras especializaciones; usarán los ajustes restablecidos.",
        ["Delete %d unused settings records? Settings currently used by a specialization or future-specialization default will be kept."] = "¿Eliminar %d conjuntos de ajustes sin usar? Se conservarán los ajustes usados y los predeterminados para futuras especializaciones.",
        ["Switch pending until combat ends"] = "Cambio al terminar el combate", ["Account default profile"] = "Perfil de cuenta predeterminado",
        ["Current"] = "Actual", ["Active"] = "Activo",
        ["No visited characters"] = "No hay personajes visitados",
        ["Spec %d"] = "Especialización %d", ["Profile changes are unavailable during combat."] = "Los cambios de perfil no están disponibles en combate.",
        ["Waiting for a safe profile context."] = "Esperando un contexto de perfil seguro.",
        ["Compatibility mode - profiles are read-only."] = "Modo de compatibilidad: los perfiles son de solo lectura.",
        ["Corrupted data - profiles are read-only. Use /ss wipe to reset."] = "Datos dañados: los perfiles son de solo lectura. Usa /ss wipe para restablecerlos.",
        ["All settings"] = "Todos los ajustes", ["Stat and gear settings"] = "Estadísticas y equipo", ["Layout settings"] = "Diseño", ["Appearance settings"] = "Apariencia", ["Choose settings to copy"] = "Elige los ajustes que copiar",
        ["Confirm"] = "Confirmar", ["Cancel"] = "Cancelar",
        ["Tank"] = "Tanque", ["Healer"] = "Sanador", ["Damage"] = "Daño",
        ["Choose a role"] = "Elige un rol",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "¿Usar «%s» como origen para futuros contextos de Tanque? Las asignaciones existentes no cambiarán; cada contexto nuevo recibirá una copia independiente.",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "¿Usar «%s» como origen para futuros contextos de Sanador? Las asignaciones existentes no cambiarán; cada contexto nuevo recibirá una copia independiente.",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "¿Usar «%s» como origen para futuros contextos de Daño? Las asignaciones existentes no cambiarán; cada contexto nuevo recibirá una copia independiente.",
        ["Profile changes saved."] = "Cambios de perfiles guardados.", ["Enter a valid profile name."] = "Introduce un nombre de perfil válido.",
        ["A profile with this name already exists."] = "Ya existe un perfil con este nombre.",
        ["Profiles changed; review and try again."] = "Los perfiles han cambiado. Revisa la selección e inténtalo de nuevo.",
        ["The current character cannot be forgotten."] = "No se puede olvidar al personaje actual.",
        ["Nothing changed."] = "No se ha cambiado nada.",
        ["Profile operation failed. Review the selection and try again."] = "La operación del perfil ha fallado. Revisa la selección e inténtalo de nuevo.",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "¿Restablecer el perfil activo «%s»? Esto cambia %d especializaciones asignadas y %d referencias más.",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "¿Olvidar a «%s»? Se eliminará su registro de personaje, pero se conservarán los ajustes de perfiles.",
        ["Auto (current: %s)"] = "Auto (actual: %s)",
        ["Western European text"] = "texto de Europa occidental",
        ["Russian text"] = "texto ruso",
        ["Korean text"] = "texto coreano",
        ["Simplified Chinese text"] = "chino simplificado",
        ["Traditional Chinese text"] = "chino tradicional",
        ["text for the selected language"] = "texto del idioma seleccionado",
        ["|cffffaa44⚠|r The selected font may not render %s correctly. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r La fuente seleccionada puede no mostrar correctamente %s. Elige una fuente SharedMedia con la cobertura adecuada.",
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
        -- ===== Settings UI (best-effort draft — mirrors esES with regional swaps:
        --   "ajustes" → "configuración" (esMX preferred); "haz clic" → "da clic".
        ["Stats"] = "Atributos", ["Layout"] = "Diseño", ["Appearance"] = "Apariencia",
        ["Character"] = "Personaje", ["Item Level"] = "Nivel de objeto",
        ["Offensive"] = "Ofensivo", ["Tertiary"] = "Terciario",
        ["Gear"] = "Equipo", ["Repair Cost"] = "Costo reparación",
        ["Side Panel Contains"] = "Panel lateral contiene",
        ["Value Display"] = "Valores",
        ["Frame & Position"] = "Marco y Posición",
        ["Typography"] = "Tipografía",
        ["Readability"] = "Legibilidad",
        ["Appearance Presets"] = "Preajustes de apariencia", ["Preset:"] = "Preajuste:",
        ["Default"] = "Predeterminado", ["Classic"] = "Clásico", ["Clean Dark"] = "Oscuro limpio", ["Midnight"] = "Medianoche",
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
        ["Raid Normal"] = "Banda normal", ["Raid Heroic"] = "Banda heroica", ["Raid Mythic"] = "Banda mítica",
        ["Full"] = "Completo", ["Short"] = "Corto", ["Hidden"] = "Oculto",
        ["None"] = "Ninguno", ["Outline"] = "Contorno", ["Thick Outline"] = "Contorno grueso",
        ["M+ Target"] = "Objetivo M+", ["Raid Target"] = "Objetivo banda",
        ["M+ High Keys"] = "M+ llaves altas", ["Raid Mythic All Bosses"] = "Banda mítica todos los jefes",
        ["M+ Current"] = "M+ actual", ["Raid Normal All Bosses"] = "Banda normal todos los jefes", ["Raid Heroic All Bosses"] = "Banda heroica todos los jefes",
        ["Target:"] = "Objetivo:", ["Current:"] = "Actual:", ["Missing:"] = "Falta:",
        ["Over:"] = "Exceso:", ["Matched:"] = "Igualado:", ["Snapshot:"] = "Captura:",
        ["Last known comparison"] = "Última comparación conocida", ["Live values; comparison unavailable"] = "Valores en vivo; comparación no disponible", ["Source:"] = "Fuente:",
        ["Stats panel shown"] = "Panel de estadísticas mostrado", ["Stats panel hidden"] = "Panel de estadísticas oculto",
        ["Settings reset to defaults"] = "Configuración restablecida",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help"] = "Comandos: /ss o /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "La configuración de SwiftStats no está cargada. Activa SwiftStats durante un inicio de sesión, ejecuta /reload y vuelve a usar /statspro import.",
        ["SwiftStats has no supported settings to import."] = "SwiftStats no tiene opciones compatibles para importar.",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "Esta configuración usa un esquema más reciente y esta versión de StatsPro no puede importarla.",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "La configuración es de solo lectura porque se guardó con una versión más reciente de StatsPro. Actualiza StatsPro para modificarla.",
        ["StatsPro saved data is corrupted and remains read-only. Use /ss wipe outside combat to reset it."] = "Los datos guardados de StatsPro están dañados y permanecen en modo de solo lectura. Usa /ss wipe fuera de combate para restablecerlos.",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "La importación de SwiftStats no está disponible en combate. Inténtalo de nuevo al terminar.",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "¿Importar los ajustes compatibles de SwiftStats en un perfil nuevo para el personaje y la especialización actuales? Los perfiles existentes, las demás asignaciones, los ajustes de la cuenta y los datos de SwiftStats no cambiarán.",
        ["Import"] = "Importar",
        ["SwiftStats settings imported into new profile \"%s\"."] = "Los ajustes de SwiftStats se importaron al nuevo perfil «%s».",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "La importación de SwiftStats falló; se conservaron los perfiles y las asignaciones.",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "¿Restablecer todos los datos de StatsPro? Esto eliminará permanentemente todos los perfiles, las asignaciones de personajes y especializaciones, las plantillas de rol, los ajustes de la cuenta y las posiciones guardadas. Los datos de SwiftStats no cambiarán.",
        ["Reset corrupted StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position."] = "¿Restablecer los datos dañados de StatsPro? Esto eliminará permanentemente todos los perfiles, las asignaciones de personajes y especializaciones, las plantillas de rol, los ajustes de la cuenta y las posiciones guardadas.",
        ["All StatsPro data reset to defaults."] = "Todos los datos de StatsPro se restablecieron a los valores predeterminados.",
        ["Close"] = "Cerrar",
        ["Contact"] = "Contacto", ["Click to copy the link."] = "Haz clic para copiar el enlace.",
        ["Copy the link below (Ctrl+C)."] = "Copia el enlace de abajo (Ctrl+C).",
        ["Open Settings"] = "Abrir configuración", ["Settings"] = "Configuración",
        ["Profiles & sharing..."] = "Perfiles...", ["Profiles & sharing"] = "Perfiles y uso compartido",
        ["Shared with %d specializations"] = "Compartido con %d especializaciones",
        ["Unknown specialization (%d)"] = "Especialización desconocida (%d)",
        ["Copy settings from..."] = "Copiar ajustes desde...", ["Use the same settings as..."] = "Usar los mismos ajustes que...",
        ["Use these settings for..."] = "Usar estos ajustes para...", ["Stop sharing..."] = "Dejar de compartir...",
        ["Advanced..."] = "Avanzado...", ["Hide advanced"] = "Ocultar opciones avanzadas",
        ["Reset these settings..."] = "Restablecer estos ajustes...", ["Forget this character..."] = "Olvidar este personaje...",
        ["Defaults for future specializations..."] = "Ajustes para futuras especializaciones...", ["Delete unused settings..."] = "Eliminar ajustes sin usar...",
        ["Copy %s from \"%s\" to \"%s\"? The destination will keep its own settings afterward."] = "¿Copiar %s de «%s» a «%s»? El destino conservará sus propios ajustes después.",
        ["Use the same settings for \"%s\" and \"%s\"? Future changes will affect both."] = "¿Usar los mismos ajustes para «%s» y «%s»? Los cambios futuros afectarán a ambos.",
        ["Use the shared settings from \"%s\" for \"%s\"? They are already shared by %d specializations; future changes will affect all %d."] = "¿Usar los ajustes compartidos de «%s» para «%s»? Ya los comparten %d especializaciones; los cambios futuros afectarán a las %d.",
        ["Give \"%s\" its own copy of these settings? Future changes will no longer affect the other specializations."] = "¿Dar a «%s» su propia copia de estos ajustes? Los cambios futuros ya no afectarán a las otras especializaciones.",
        ["Reset the settings used by \"%s\"? The same reset will affect %d specializations."] = "¿Restablecer los ajustes que usa «%s»? El mismo restablecimiento afectará a %d especializaciones.",
        ["Reset the settings used by \"%s\" to defaults?"] = "¿Restablecer los ajustes que usa «%s» a los valores predeterminados?",
        ["This profile is also a default for future specializations; they will use the reset settings."] = "Este perfil también es predeterminado para futuras especializaciones; usarán los ajustes restablecidos.",
        ["Delete %d unused settings records? Settings currently used by a specialization or future-specialization default will be kept."] = "¿Eliminar %d conjuntos de ajustes sin usar? Se conservarán los ajustes usados y los predeterminados para futuras especializaciones.",
        ["Switch pending until combat ends"] = "Cambio al terminar el combate", ["Account default profile"] = "Perfil predeterminado de la cuenta",
        ["Current"] = "Actual", ["Active"] = "Activo",
        ["No visited characters"] = "No hay personajes visitados",
        ["Spec %d"] = "Especialización %d", ["Profile changes are unavailable during combat."] = "Los cambios de perfil no están disponibles en combate.",
        ["Waiting for a safe profile context."] = "Esperando un contexto de perfil seguro.",
        ["Compatibility mode - profiles are read-only."] = "Modo de compatibilidad: los perfiles son de solo lectura.",
        ["Corrupted data - profiles are read-only. Use /ss wipe to reset."] = "Datos dañados: los perfiles son de solo lectura. Usa /ss wipe para restablecerlos.",
        ["All settings"] = "Todos los ajustes", ["Stat and gear settings"] = "Estadísticas y equipo", ["Layout settings"] = "Diseño", ["Appearance settings"] = "Apariencia", ["Choose settings to copy"] = "Elige los ajustes que copiar",
        ["Confirm"] = "Confirmar", ["Cancel"] = "Cancelar",
        ["Tank"] = "Tanque", ["Healer"] = "Sanador", ["Damage"] = "Daño",
        ["Choose a role"] = "Elige un rol",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "¿Usar «%s» como origen para futuros contextos de Tanque? Las asignaciones existentes no cambiarán; cada contexto nuevo recibirá una copia independiente.",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "¿Usar «%s» como origen para futuros contextos de Sanador? Las asignaciones existentes no cambiarán; cada contexto nuevo recibirá una copia independiente.",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "¿Usar «%s» como origen para futuros contextos de Daño? Las asignaciones existentes no cambiarán; cada contexto nuevo recibirá una copia independiente.",
        ["Profile changes saved."] = "Cambios de perfiles guardados.", ["Enter a valid profile name."] = "Ingresa un nombre de perfil válido.",
        ["A profile with this name already exists."] = "Ya existe un perfil con este nombre.",
        ["Profiles changed; review and try again."] = "Los perfiles cambiaron. Revisa la selección e inténtalo de nuevo.",
        ["The current character cannot be forgotten."] = "No se puede olvidar al personaje actual.",
        ["Nothing changed."] = "No se cambió nada.",
        ["Profile operation failed. Review the selection and try again."] = "La operación del perfil falló. Revisa la selección e inténtalo de nuevo.",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "¿Restablecer el perfil activo «%s»? Esto cambia %d especializaciones asignadas y %d referencias más.",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "¿Olvidar a «%s»? Se eliminará su registro de personaje, pero se conservarán los ajustes de perfiles.",
        ["Auto (current: %s)"] = "Auto (actual: %s)",
        ["Western European text"] = "texto de Europa occidental",
        ["Russian text"] = "texto ruso",
        ["Korean text"] = "texto coreano",
        ["Simplified Chinese text"] = "chino simplificado",
        ["Traditional Chinese text"] = "chino tradicional",
        ["text for the selected language"] = "texto del idioma seleccionado",
        ["|cffffaa44⚠|r The selected font may not render %s correctly. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r La fuente seleccionada puede no mostrar correctamente %s. Elige una fuente SharedMedia con la cobertura adecuada.",
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
        -- ===== Settings UI (best-effort draft, native-speaker review welcome via Issues) =====
        ["Stats"] = "Stat", ["Layout"] = "Layout", ["Appearance"] = "Aspetto",
        ["Character"] = "Personaggio", ["Item Level"] = "Livello oggetto",
        ["Offensive"] = "Offensivo", ["Tertiary"] = "Terziario",
        ["Gear"] = "Equipaggiamento", ["Repair Cost"] = "Costo riparazione",
        ["Side Panel Contains"] = "Pannello laterale contiene",
        ["Value Display"] = "Valori",
        ["Frame & Position"] = "Cornice e Posizione",
        ["Typography"] = "Tipografia",
        ["Readability"] = "Leggibilità",
        ["Appearance Presets"] = "Preimpostazioni aspetto", ["Preset:"] = "Preimpostazione:",
        ["Default"] = "Predefinito", ["Classic"] = "Classico", ["Clean Dark"] = "Scuro pulito", ["Midnight"] = "Mezzanotte",
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
        ["Raid Normal"] = "Incursione Normale", ["Raid Heroic"] = "Incursione Eroica", ["Raid Mythic"] = "Incursione Mitica",
        ["Full"] = "Completo", ["Short"] = "Corto", ["Hidden"] = "Nascosto",
        ["None"] = "Nessuno", ["Outline"] = "Contorno", ["Thick Outline"] = "Contorno spesso",
        ["M+ Target"] = "Bersaglio M+", ["Raid Target"] = "Bersaglio incursione",
        ["M+ High Keys"] = "M+ chiavi alte", ["Raid Mythic All Bosses"] = "Incursione Mitica tutti i boss",
        ["M+ Current"] = "M+ attuale", ["Raid Normal All Bosses"] = "Incursione Normale tutti i boss", ["Raid Heroic All Bosses"] = "Incursione Eroica tutti i boss",
        ["Target:"] = "Bersaglio:", ["Current:"] = "Attuale:", ["Missing:"] = "Manca:",
        ["Over:"] = "Oltre:", ["Matched:"] = "Raggiunto:", ["Snapshot:"] = "Istantanea:",
        ["Last known comparison"] = "Ultimo confronto noto", ["Live values; comparison unavailable"] = "Valori in tempo reale; confronto non disponibile", ["Source:"] = "Fonte:",
        ["Stats panel shown"] = "Pannello statistiche mostrato", ["Stats panel hidden"] = "Pannello statistiche nascosto",
        ["Settings reset to defaults"] = "Impostazioni ripristinate",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help"] = "Comandi: /ss o /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "Le impostazioni di SwiftStats non sono caricate. Abilita SwiftStats per un accesso, esegui /reload, quindi usa di nuovo /statspro import.",
        ["SwiftStats has no supported settings to import."] = "SwiftStats non contiene impostazioni supportate da importare.",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "Queste impostazioni usano uno schema più recente e non possono essere importate da questa versione di StatsPro.",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "Le impostazioni sono in sola lettura perché sono state salvate da una versione più recente di StatsPro. Aggiorna StatsPro per modificarle.",
        ["StatsPro saved data is corrupted and remains read-only. Use /ss wipe outside combat to reset it."] = "I dati salvati di StatsPro sono danneggiati e restano in sola lettura. Usa /ss wipe fuori dal combattimento per ripristinarli.",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "L’importazione di SwiftStats non è disponibile in combattimento. Riprova al termine.",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "Importare le impostazioni SwiftStats compatibili in un nuovo profilo per il personaggio e la specializzazione attuali? I profili esistenti, le altre assegnazioni, le impostazioni dell’account e i dati SwiftStats resteranno invariati.",
        ["Import"] = "Importa",
        ["SwiftStats settings imported into new profile \"%s\"."] = "Impostazioni SwiftStats importate nel nuovo profilo «%s».",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "Importazione di SwiftStats non riuscita; profili e assegnazioni sono stati conservati.",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "Ripristinare tutti i dati di StatsPro? Verranno rimossi definitivamente tutti i profili, le assegnazioni di personaggi e specializzazioni, i modelli di ruolo, le impostazioni dell’account e le posizioni salvate. I dati SwiftStats resteranno invariati.",
        ["Reset corrupted StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position."] = "Ripristinare i dati danneggiati di StatsPro? Verranno rimossi definitivamente tutti i profili, le assegnazioni di personaggi e specializzazioni, i modelli di ruolo, le impostazioni dell’account e le posizioni salvate.",
        ["All StatsPro data reset to defaults."] = "Tutti i dati di StatsPro sono stati ripristinati ai valori predefiniti.",
        ["Close"] = "Chiudi",
        ["Contact"] = "Contatti", ["Click to copy the link."] = "Fai clic per copiare il link.",
        ["Copy the link below (Ctrl+C)."] = "Copia il link qui sotto (Ctrl+C).",
        ["Open Settings"] = "Apri impostazioni", ["Settings"] = "Impostazioni",
        ["Profiles & sharing..."] = "Profili...", ["Profiles & sharing"] = "Profili e condivisione",
        ["Shared with %d specializations"] = "Condiviso con %d specializzazioni",
        ["Unknown specialization (%d)"] = "Specializzazione sconosciuta (%d)",
        ["Copy settings from..."] = "Copia impostazioni da...", ["Use the same settings as..."] = "Usa le stesse impostazioni di...",
        ["Use these settings for..."] = "Usa queste impostazioni per...", ["Stop sharing..."] = "Interrompi condivisione...",
        ["Advanced..."] = "Avanzate...", ["Hide advanced"] = "Nascondi opzioni avanzate",
        ["Reset these settings..."] = "Ripristina queste impostazioni...", ["Forget this character..."] = "Dimentica questo personaggio...",
        ["Defaults for future specializations..."] = "Impostazioni per specializzazioni future...", ["Delete unused settings..."] = "Elimina impostazioni inutilizzate...",
        ["Copy %s from \"%s\" to \"%s\"? The destination will keep its own settings afterward."] = "Copiare %s da «%s» a «%s»? La destinazione manterrà poi le proprie impostazioni.",
        ["Use the same settings for \"%s\" and \"%s\"? Future changes will affect both."] = "Usare le stesse impostazioni per «%s» e «%s»? Le modifiche future influiranno su entrambe.",
        ["Use the shared settings from \"%s\" for \"%s\"? They are already shared by %d specializations; future changes will affect all %d."] = "Usare le impostazioni condivise di «%s» per «%s»? Sono già condivise da %d specializzazioni; le modifiche future interesseranno tutte e %d.",
        ["Give \"%s\" its own copy of these settings? Future changes will no longer affect the other specializations."] = "Dare a «%s» una copia separata di queste impostazioni? Le modifiche future non influiranno più sulle altre specializzazioni.",
        ["Reset the settings used by \"%s\"? The same reset will affect %d specializations."] = "Ripristinare le impostazioni usate da «%s»? Lo stesso ripristino influirà su %d specializzazioni.",
        ["Reset the settings used by \"%s\" to defaults?"] = "Ripristinare ai valori predefiniti le impostazioni usate da «%s»?",
        ["This profile is also a default for future specializations; they will use the reset settings."] = "Questo profilo è anche predefinito per le specializzazioni future; useranno le impostazioni ripristinate.",
        ["Delete %d unused settings records? Settings currently used by a specialization or future-specialization default will be kept."] = "Eliminare %d gruppi di impostazioni inutilizzati? Le impostazioni in uso e quelle per le specializzazioni future saranno mantenute.",
        ["Switch pending until combat ends"] = "Cambio dopo il combattimento", ["Account default profile"] = "Profilo account predefinito",
        ["Current"] = "Attuale", ["Active"] = "Attivo",
        ["No visited characters"] = "Nessun personaggio visitato",
        ["Spec %d"] = "Specializzazione %d", ["Profile changes are unavailable during combat."] = "Le modifiche ai profili non sono disponibili in combattimento.",
        ["Waiting for a safe profile context."] = "In attesa di un contesto profilo sicuro.",
        ["Compatibility mode - profiles are read-only."] = "Modalità compatibilità – i profili sono in sola lettura.",
        ["Corrupted data - profiles are read-only. Use /ss wipe to reset."] = "Dati danneggiati – i profili sono in sola lettura. Usa /ss wipe per ripristinare.",
        ["All settings"] = "Tutte le impostazioni", ["Stat and gear settings"] = "Statistiche ed equipaggiamento", ["Layout settings"] = "Disposizione", ["Appearance settings"] = "Aspetto", ["Choose settings to copy"] = "Scegli le impostazioni da copiare",
        ["Confirm"] = "Conferma", ["Cancel"] = "Annulla",
        ["Tank"] = "Difensore", ["Healer"] = "Guaritore", ["Damage"] = "Assaltatore",
        ["Choose a role"] = "Scegli un ruolo",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "Usare «%s» come origine per i futuri contesti Difensore? Le assegnazioni esistenti non cambieranno; ogni nuovo contesto riceverà una copia indipendente.",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "Usare «%s» come origine per i futuri contesti Guaritore? Le assegnazioni esistenti non cambieranno; ogni nuovo contesto riceverà una copia indipendente.",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "Usare «%s» come origine per i futuri contesti Assaltatore? Le assegnazioni esistenti non cambieranno; ogni nuovo contesto riceverà una copia indipendente.",
        ["Profile changes saved."] = "Modifiche ai profili salvate.", ["Enter a valid profile name."] = "Inserisci un nome profilo valido.",
        ["A profile with this name already exists."] = "Esiste già un profilo con questo nome.",
        ["Profiles changed; review and try again."] = "I profili sono cambiati. Controlla la selezione e riprova.",
        ["The current character cannot be forgotten."] = "Il personaggio attuale non può essere dimenticato.",
        ["Nothing changed."] = "Nessuna modifica.",
        ["Profile operation failed. Review the selection and try again."] = "Operazione sul profilo non riuscita. Controlla la selezione e riprova.",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "Ripristinare il profilo attivo «%s»? Verranno modificate %d specializzazioni assegnate e %d altri riferimenti.",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "Dimenticare «%s»? Il record del personaggio verrà rimosso, ma le impostazioni dei profili saranno conservate.",
        ["Auto (current: %s)"] = "Auto (attuale: %s)",
        ["Western European text"] = "testo dell’Europa occidentale",
        ["Russian text"] = "testo russo",
        ["Korean text"] = "testo coreano",
        ["Simplified Chinese text"] = "cinese semplificato",
        ["Traditional Chinese text"] = "cinese tradizionale",
        ["text for the selected language"] = "testo della lingua selezionata",
        ["|cffffaa44⚠|r The selected font may not render %s correctly. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r Il font selezionato potrebbe non visualizzare correttamente %s. Scegli un font SharedMedia con copertura adeguata.",
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
        -- ===== Settings UI (best-effort draft, native-speaker review welcome via Issues) =====
        ["Stats"] = "Atributos", ["Layout"] = "Layout", ["Appearance"] = "Aparência",
        ["Character"] = "Personagem", ["Item Level"] = "Nível de item",
        ["Offensive"] = "Ofensivo", ["Tertiary"] = "Terciário",
        ["Gear"] = "Equipamento", ["Repair Cost"] = "Custo de reparo",
        ["Side Panel Contains"] = "Painel lateral contém",
        ["Value Display"] = "Valores",
        ["Frame & Position"] = "Janela e Posição",
        ["Typography"] = "Tipografia",
        ["Readability"] = "Legibilidade",
        ["Appearance Presets"] = "Predefinições de aparência", ["Preset:"] = "Predefinição:",
        ["Default"] = "Padrão", ["Classic"] = "Clássico", ["Clean Dark"] = "Escuro limpo", ["Midnight"] = "Meia-noite",
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
        ["Raid Normal"] = "Raide Normal", ["Raid Heroic"] = "Raide Heroico", ["Raid Mythic"] = "Raide Mítico",
        ["Full"] = "Completo", ["Short"] = "Curto", ["Hidden"] = "Oculto",
        ["None"] = "Nenhum", ["Outline"] = "Contorno", ["Thick Outline"] = "Contorno grosso",
        ["M+ Target"] = "Alvo M+", ["Raid Target"] = "Alvo de raide",
        ["M+ High Keys"] = "M+ chaves altas", ["Raid Mythic All Bosses"] = "Raide Mítico todos os chefes",
        ["M+ Current"] = "M+ atual", ["Raid Normal All Bosses"] = "Raide Normal todos os chefes", ["Raid Heroic All Bosses"] = "Raide Heroico todos os chefes",
        ["Target:"] = "Alvo:", ["Current:"] = "Atual:", ["Missing:"] = "Falta:",
        ["Over:"] = "Acima:", ["Matched:"] = "Igualado:", ["Snapshot:"] = "Registro:",
        ["Last known comparison"] = "Última comparação conhecida", ["Live values; comparison unavailable"] = "Valores em tempo real; comparação indisponível", ["Source:"] = "Fonte:",
        ["Stats panel shown"] = "Painel de atributos mostrado", ["Stats panel hidden"] = "Painel de atributos oculto",
        ["Settings reset to defaults"] = "Configurações restauradas",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help"] = "Comandos: /ss ou /statspro (configurações), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "As configurações do SwiftStats não estão carregadas. Ative o SwiftStats por um login, execute /reload e use /statspro import novamente.",
        ["SwiftStats has no supported settings to import."] = "O SwiftStats não tem configurações compatíveis para importar.",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "Estas configurações usam um esquema mais recente e não podem ser importadas por esta versão do StatsPro.",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "As configurações estão somente para leitura porque foram salvas por uma versão mais recente do StatsPro. Atualize o StatsPro para alterá-las.",
        ["StatsPro saved data is corrupted and remains read-only. Use /ss wipe outside combat to reset it."] = "Os dados salvos do StatsPro estão corrompidos e permanecem somente leitura. Use /ss wipe fora de combate para redefini-los.",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "A importação do SwiftStats não está disponível em combate. Tente novamente depois.",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "Importar as configurações compatíveis do SwiftStats para um novo perfil do personagem e da especialização atuais? Os perfis existentes, as outras atribuições, as configurações da conta e os dados do SwiftStats permanecerão inalterados.",
        ["Import"] = "Importar",
        ["SwiftStats settings imported into new profile \"%s\"."] = "Configurações do SwiftStats importadas para o novo perfil “%s”.",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "Falha ao importar o SwiftStats; os perfis e as atribuições foram preservados.",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "Redefinir todos os dados do StatsPro? Isso removerá permanentemente todos os perfis, as atribuições de personagens e especializações, os modelos de função, as configurações da conta e as posições salvas. Os dados do SwiftStats permanecerão inalterados.",
        ["Reset corrupted StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position."] = "Redefinir os dados corrompidos do StatsPro? Isso removerá permanentemente todos os perfis, as atribuições de personagens e especializações, os modelos de função, as configurações da conta e as posições salvas.",
        ["All StatsPro data reset to defaults."] = "Todos os dados do StatsPro foram redefinidos para os padrões.",
        ["Close"] = "Fechar",
        ["Contact"] = "Contato", ["Click to copy the link."] = "Clique para copiar o link.",
        ["Copy the link below (Ctrl+C)."] = "Copie o link abaixo (Ctrl+C).",
        ["Open Settings"] = "Abrir configurações", ["Settings"] = "Configurações",
        ["Profiles & sharing..."] = "Perfis...", ["Profiles & sharing"] = "Perfis e compartilhamento",
        ["Shared with %d specializations"] = "Compartilhado com %d especializações",
        ["Unknown specialization (%d)"] = "Especialização desconhecida (%d)",
        ["Copy settings from..."] = "Copiar configurações de...", ["Use the same settings as..."] = "Usar as mesmas configurações de...",
        ["Use these settings for..."] = "Usar estas configurações para...", ["Stop sharing..."] = "Parar de compartilhar...",
        ["Advanced..."] = "Avançado...", ["Hide advanced"] = "Ocultar opções avançadas",
        ["Reset these settings..."] = "Redefinir estas configurações...", ["Forget this character..."] = "Esquecer este personagem...",
        ["Defaults for future specializations..."] = "Configurações para especializações futuras...", ["Delete unused settings..."] = "Excluir configurações não usadas...",
        ["Copy %s from \"%s\" to \"%s\"? The destination will keep its own settings afterward."] = "Copiar %s de “%s” para “%s”? O destino manterá suas próprias configurações depois.",
        ["Use the same settings for \"%s\" and \"%s\"? Future changes will affect both."] = "Usar as mesmas configurações para “%s” e “%s”? Alterações futuras afetarão ambos.",
        ["Use the shared settings from \"%s\" for \"%s\"? They are already shared by %d specializations; future changes will affect all %d."] = "Usar as configurações compartilhadas de “%s” para “%s”? Elas já são compartilhadas por %d especializações; alterações futuras afetarão todas as %d.",
        ["Give \"%s\" its own copy of these settings? Future changes will no longer affect the other specializations."] = "Dar a “%s” uma cópia própria destas configurações? Alterações futuras não afetarão mais as outras especializações.",
        ["Reset the settings used by \"%s\"? The same reset will affect %d specializations."] = "Redefinir as configurações usadas por “%s”? A mesma redefinição afetará %d especializações.",
        ["Reset the settings used by \"%s\" to defaults?"] = "Redefinir as configurações usadas por “%s” para os padrões?",
        ["This profile is also a default for future specializations; they will use the reset settings."] = "Este perfil também é padrão para especializações futuras; elas usarão as configurações redefinidas.",
        ["Delete %d unused settings records? Settings currently used by a specialization or future-specialization default will be kept."] = "Excluir %d conjuntos de configurações não usados? Configurações em uso e padrões para especializações futuras serão mantidos.",
        ["Switch pending until combat ends"] = "Troca após o combate", ["Account default profile"] = "Perfil padrão da conta",
        ["Current"] = "Atual", ["Active"] = "Ativo",
        ["No visited characters"] = "Nenhum personagem visitado",
        ["Spec %d"] = "Especialização %d", ["Profile changes are unavailable during combat."] = "Alterações de perfil não estão disponíveis em combate.",
        ["Waiting for a safe profile context."] = "Aguardando um contexto de perfil seguro.",
        ["Compatibility mode - profiles are read-only."] = "Modo de compatibilidade – os perfis são somente leitura.",
        ["Corrupted data - profiles are read-only. Use /ss wipe to reset."] = "Dados corrompidos – os perfis são somente leitura. Use /ss wipe para redefinir.",
        ["All settings"] = "Todas as configurações", ["Stat and gear settings"] = "Atributos e equipamento", ["Layout settings"] = "Layout", ["Appearance settings"] = "Aparência", ["Choose settings to copy"] = "Escolha as configurações para copiar",
        ["Confirm"] = "Confirmar", ["Cancel"] = "Cancelar",
        ["Tank"] = "Tanque", ["Healer"] = "Cura", ["Damage"] = "Dano",
        ["Choose a role"] = "Escolha uma função",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "Usar «%s» como origem para futuros contextos de Tanque? As atribuições existentes não mudarão; cada novo contexto receberá uma cópia independente.",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "Usar «%s» como origem para futuros contextos de Cura? As atribuições existentes não mudarão; cada novo contexto receberá uma cópia independente.",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "Usar «%s» como origem para futuros contextos de Dano? As atribuições existentes não mudarão; cada novo contexto receberá uma cópia independente.",
        ["Profile changes saved."] = "Alterações de perfil salvas.", ["Enter a valid profile name."] = "Digite um nome de perfil válido.",
        ["A profile with this name already exists."] = "Já existe um perfil com este nome.",
        ["Profiles changed; review and try again."] = "Os perfis mudaram. Revise a seleção e tente novamente.",
        ["The current character cannot be forgotten."] = "O personagem atual não pode ser esquecido.",
        ["Nothing changed."] = "Nada foi alterado.",
        ["Profile operation failed. Review the selection and try again."] = "A operação do perfil falhou. Revise a seleção e tente novamente.",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "Redefinir o perfil ativo “%s” para os padrões? Isso altera %d especializações atribuídas e %d outras referências.",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "Esquecer “%s”? O registro do personagem será removido, mas as configurações dos perfis serão mantidas.",
        ["Auto (current: %s)"] = "Auto (atual: %s)",
        ["Western European text"] = "texto da Europa Ocidental",
        ["Russian text"] = "texto russo",
        ["Korean text"] = "texto coreano",
        ["Simplified Chinese text"] = "chinês simplificado",
        ["Traditional Chinese text"] = "chinês tradicional",
        ["text for the selected language"] = "texto do idioma selecionado",
        ["|cffffaa44⚠|r The selected font may not render %s correctly. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r A fonte selecionada pode não exibir corretamente %s. Escolha uma fonte SharedMedia com cobertura adequada.",
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
        -- ===== Settings UI (best-effort draft — native review welcomed via Issues) =====
        ["Stats"] = "능력치", ["Layout"] = "배치", ["Appearance"] = "외형",
        ["Character"] = "캐릭터", ["Item Level"] = "아이템 레벨",
        ["Offensive"] = "공격", ["Tertiary"] = "보조",
        ["Gear"] = "장비", ["Repair Cost"] = "수리 비용",
        ["Side Panel Contains"] = "보조 패널 포함",
        ["Value Display"] = "값 표시",
        ["Frame & Position"] = "창 및 위치",
        ["Typography"] = "글꼴",
        ["Readability"] = "가독성",
        ["Appearance Presets"] = "외형 프리셋", ["Preset:"] = "프리셋:",
        ["Default"] = "기본", ["Classic"] = "클래식", ["Clean Dark"] = "깔끔한 어둠", ["Midnight"] = "한밤",
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
        ["Raid Normal"] = "일반 공격대", ["Raid Heroic"] = "영웅 공격대", ["Raid Mythic"] = "신화 공격대",
        ["Full"] = "전체", ["Short"] = "짧게", ["Hidden"] = "숨김",
        ["None"] = "없음", ["Outline"] = "외곽선", ["Thick Outline"] = "굵은 외곽선",
        ["M+ Target"] = "쐐기+ 목표", ["Raid Target"] = "공격대 목표",
        ["M+ High Keys"] = "쐐기+ 고단", ["Raid Mythic All Bosses"] = "신화 공격대 모든 우두머리",
        ["M+ Current"] = "현재 쐐기+", ["Raid Normal All Bosses"] = "일반 공격대 모든 우두머리", ["Raid Heroic All Bosses"] = "영웅 공격대 모든 우두머리",
        ["Target:"] = "목표:", ["Current:"] = "현재:", ["Missing:"] = "부족:",
        ["Over:"] = "초과:", ["Matched:"] = "일치:", ["Snapshot:"] = "스냅샷:",
        ["Last known comparison"] = "마지막으로 확인된 비교", ["Live values; comparison unavailable"] = "실시간 값; 비교할 수 없음", ["Source:"] = "출처:",
        ["Stats panel shown"] = "능력치 패널 표시됨", ["Stats panel hidden"] = "능력치 패널 숨김",
        ["Settings reset to defaults"] = "설정이 기본값으로 초기화되었습니다",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help"] = "명령어: /ss 또는 /statspro (설정), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "SwiftStats 설정이 로드되지 않았습니다. 한 번 로그인하는 동안 SwiftStats를 활성화하고 /reload 후 /statspro import를 다시 실행하세요.",
        ["SwiftStats has no supported settings to import."] = "SwiftStats에 가져올 수 있는 지원 설정이 없습니다.",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "이 설정은 더 새로운 스키마를 사용하므로 현재 StatsPro 버전에서 가져올 수 없습니다.",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "더 최신 StatsPro 버전에서 저장한 설정이므로 읽기 전용입니다. 설정을 변경하려면 StatsPro를 업데이트하세요.",
        ["StatsPro saved data is corrupted and remains read-only. Use /ss wipe outside combat to reset it."] = "저장된 StatsPro 데이터가 손상되어 읽기 전용 상태입니다. 전투 중이 아닐 때 /ss wipe로 초기화하세요.",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "전투 중에는 SwiftStats 설정을 가져올 수 없습니다. 전투 후 다시 시도하세요.",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "현재 캐릭터와 전문화용 새 프로필로 호환되는 SwiftStats 설정을 가져오시겠습니까? 기존 프로필, 다른 할당, 계정 설정 및 SwiftStats 데이터는 변경되지 않습니다.",
        ["Import"] = "가져오기",
        ["SwiftStats settings imported into new profile \"%s\"."] = "SwiftStats 설정을 새 프로필 \"%s\"에 가져왔습니다.",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "SwiftStats 설정 가져오기에 실패했습니다. 프로필과 할당은 유지되었습니다.",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "모든 StatsPro 데이터를 초기화하시겠습니까? 모든 프로필, 캐릭터 및 전문화 할당, 역할 템플릿, 계정 설정, 저장된 위치가 영구적으로 삭제됩니다. SwiftStats 데이터는 변경되지 않습니다.",
        ["Reset corrupted StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position."] = "손상된 StatsPro 데이터를 초기화하시겠습니까? 모든 프로필, 캐릭터 및 전문화 할당, 역할 템플릿, 계정 설정, 저장된 위치가 영구적으로 삭제됩니다.",
        ["All StatsPro data reset to defaults."] = "모든 StatsPro 데이터를 기본값으로 초기화했습니다.",
        ["Close"] = "닫기",
        ["Contact"] = "문의", ["Click to copy the link."] = "클릭하여 링크를 복사하세요.",
        ["Copy the link below (Ctrl+C)."] = "아래 링크를 복사하세요 (Ctrl+C).",
        ["Open Settings"] = "설정 열기", ["Settings"] = "설정",
        ["Profiles & sharing..."] = "프로필 및 공유...", ["Profiles & sharing"] = "프로필 및 공유",
        ["Shared with %d specializations"] = "전문화 %d개와 공유",
        ["Unknown specialization (%d)"] = "알 수 없는 전문화 (%d)",
        ["Copy settings from..."] = "설정 복사 원본...", ["Use the same settings as..."] = "같은 설정 사용...",
        ["Use these settings for..."] = "이 설정을 사용할 전문화...", ["Stop sharing..."] = "공유 중지...",
        ["Advanced..."] = "고급...", ["Hide advanced"] = "고급 옵션 숨기기",
        ["Reset these settings..."] = "이 설정 초기화...", ["Forget this character..."] = "이 캐릭터 기록 삭제...",
        ["Defaults for future specializations..."] = "새 전문화의 기본 설정...", ["Delete unused settings..."] = "사용하지 않는 설정 삭제...",
        ["Copy %s from \"%s\" to \"%s\"? The destination will keep its own settings afterward."] = "%s 설정을 “%s”에서 “%s”로 복사하시겠습니까? 대상은 이후 별도 설정을 유지합니다.",
        ["Use the same settings for \"%s\" and \"%s\"? Future changes will affect both."] = "“%s”와 “%s”에 같은 설정을 사용하시겠습니까? 이후 변경 사항이 둘 다에 적용됩니다.",
        ["Use the shared settings from \"%s\" for \"%s\"? They are already shared by %d specializations; future changes will affect all %d."] = "“%s”의 공유 설정을 “%s”에도 사용하시겠습니까? 이미 전문화 %d개가 공유 중이며 이후 변경 사항은 전문화 %d개 모두에 적용됩니다.",
        ["Give \"%s\" its own copy of these settings? Future changes will no longer affect the other specializations."] = "“%s”에 이 설정의 별도 사본을 만드시겠습니까? 이후 변경 사항은 다른 전문화에 영향을 주지 않습니다.",
        ["Reset the settings used by \"%s\"? The same reset will affect %d specializations."] = "“%s”이(가) 사용하는 설정을 초기화하시겠습니까? 같은 초기화가 전문화 %d개에 적용됩니다.",
        ["Reset the settings used by \"%s\" to defaults?"] = "“%s”이(가) 사용하는 설정을 기본값으로 초기화하시겠습니까?",
        ["This profile is also a default for future specializations; they will use the reset settings."] = "이 프로필은 향후 전문화의 기본 설정으로도 사용되며 초기화된 설정이 적용됩니다.",
        ["Delete %d unused settings records? Settings currently used by a specialization or future-specialization default will be kept."] = "사용하지 않는 설정 %d개를 삭제하시겠습니까? 현재 사용 중인 설정과 새 전문화의 기본 설정은 유지됩니다.",
        ["Switch pending until combat ends"] = "전투 종료 후 전환", ["Account default profile"] = "계정 기본 프로필",
        ["Current"] = "현재", ["Active"] = "활성",
        ["No visited characters"] = "방문한 캐릭터 없음",
        ["Spec %d"] = "전문화 %d", ["Profile changes are unavailable during combat."] = "전투 중에는 프로필을 변경할 수 없습니다.",
        ["Waiting for a safe profile context."] = "안전한 프로필 상태를 기다리는 중입니다.",
        ["Compatibility mode - profiles are read-only."] = "호환 모드 – 프로필이 읽기 전용입니다.",
        ["Corrupted data - profiles are read-only. Use /ss wipe to reset."] = "데이터 손상 – 프로필이 읽기 전용입니다. /ss wipe로 초기화하세요.",
        ["All settings"] = "모든 설정", ["Stat and gear settings"] = "능력치 및 장비 설정", ["Layout settings"] = "배치 설정", ["Appearance settings"] = "외형 설정", ["Choose settings to copy"] = "복사할 설정 선택",
        ["Confirm"] = "확인", ["Cancel"] = "취소",
        ["Tank"] = "방어 전담", ["Healer"] = "치유 전담", ["Damage"] = "공격 전담",
        ["Choose a role"] = "역할 선택",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "%s 프로필을 향후 방어 전담 컨텍스트의 원본으로 사용하시겠습니까? 기존 할당은 바뀌지 않으며 새 컨텍스트마다 독립 복사본이 생성됩니다.",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "%s 프로필을 향후 치유 전담 컨텍스트의 원본으로 사용하시겠습니까? 기존 할당은 바뀌지 않으며 새 컨텍스트마다 독립 복사본이 생성됩니다.",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "%s 프로필을 향후 공격 전담 컨텍스트의 원본으로 사용하시겠습니까? 기존 할당은 바뀌지 않으며 새 컨텍스트마다 독립 복사본이 생성됩니다.",
        ["Profile changes saved."] = "프로필 변경 사항을 저장했습니다.", ["Enter a valid profile name."] = "올바른 프로필 이름을 입력하세요.",
        ["A profile with this name already exists."] = "같은 이름의 프로필이 이미 있습니다.",
        ["Profiles changed; review and try again."] = "프로필이 변경되었습니다. 선택을 확인하고 다시 시도하세요.",
        ["The current character cannot be forgotten."] = "현재 캐릭터의 기록은 삭제할 수 없습니다.",
        ["Nothing changed."] = "변경된 내용이 없습니다.",
        ["Profile operation failed. Review the selection and try again."] = "프로필 작업에 실패했습니다. 선택을 확인하고 다시 시도하세요.",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "활성 프로필 \"%s\"을(를) 기본값으로 초기화하시겠습니까? 할당된 전문화 %d개와 기타 참조 %d개가 변경됩니다.",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "\"%s\"의 기록을 삭제하시겠습니까? 캐릭터 기록만 제거되고 프로필 설정은 유지됩니다.",
        ["Auto (current: %s)"] = "자동 (현재: %s)",
        ["Western European text"] = "서유럽 언어 텍스트",
        ["Russian text"] = "러시아어 텍스트",
        ["Korean text"] = "한국어 텍스트",
        ["Simplified Chinese text"] = "중국어 간체",
        ["Traditional Chinese text"] = "중국어 번체",
        ["text for the selected language"] = "선택한 언어의 텍스트",
        ["|cffffaa44⚠|r The selected font may not render %s correctly. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r 선택한 글꼴이 %s을(를) 올바르게 표시하지 못할 수 있습니다. SharedMedia에서 적합한 글꼴을 선택하세요.",
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
        -- ===== Settings UI (best-effort draft, native-speaker review welcome via Issues) =====
        ["Stats"] = "属性", ["Layout"] = "布局", ["Appearance"] = "外观",
        ["Character"] = "角色", ["Item Level"] = "装等",
        ["Offensive"] = "进攻", ["Tertiary"] = "第三属性",
        ["Gear"] = "装备", ["Repair Cost"] = "修理费用",
        ["Side Panel Contains"] = "侧面板包含",
        ["Value Display"] = "数值显示",
        ["Frame & Position"] = "窗口与位置",
        ["Typography"] = "字体",
        ["Readability"] = "可读性",
        ["Appearance Presets"] = "外观预设", ["Preset:"] = "预设：",
        ["Default"] = "默认", ["Classic"] = "经典", ["Clean Dark"] = "简洁深色", ["Midnight"] = "午夜",
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
        ["Raid Normal"] = "普通团队", ["Raid Heroic"] = "英雄团队", ["Raid Mythic"] = "史诗团队",
        ["Full"] = "完整", ["Short"] = "简短", ["Hidden"] = "隐藏",
        ["None"] = "无", ["Outline"] = "描边", ["Thick Outline"] = "粗描边",
        ["M+ Target"] = "史诗+目标", ["Raid Target"] = "团队目标",
        ["M+ High Keys"] = "史诗+高层", ["Raid Mythic All Bosses"] = "史诗团队全部首领",
        ["M+ Current"] = "当前史诗+", ["Raid Normal All Bosses"] = "普通团队全部首领", ["Raid Heroic All Bosses"] = "英雄团队全部首领",
        ["Target:"] = "目标:", ["Current:"] = "当前:", ["Missing:"] = "缺少:",
        ["Over:"] = "超出:", ["Matched:"] = "已达成:", ["Snapshot:"] = "快照:",
        ["Last known comparison"] = "上次已知对比", ["Live values; comparison unavailable"] = "实时数值；无法比较", ["Source:"] = "来源:",
        ["Stats panel shown"] = "属性面板已显示", ["Stats panel hidden"] = "属性面板已隐藏",
        ["Settings reset to defaults"] = "设置已恢复默认",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help"] = "命令: /ss 或 /statspro (设置), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "未加载 SwiftStats 设置。请启用 SwiftStats 登录一次，执行 /reload，然后再次运行 /statspro import。",
        ["SwiftStats has no supported settings to import."] = "SwiftStats 中没有可导入的受支持设置。",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "这些设置使用较新的数据结构，当前版本的 StatsPro 无法导入。",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "这些设置由较新版本的 StatsPro 保存，因此当前为只读。请更新 StatsPro 后再进行修改。",
        ["StatsPro saved data is corrupted and remains read-only. Use /ss wipe outside combat to reset it."] = "StatsPro 保存的数据已损坏，当前保持只读。请在非战斗状态下使用 /ss wipe 重置。",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "战斗中无法导入 SwiftStats 设置。请在战斗结束后重试。",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "要将兼容的 SwiftStats 设置导入到当前角色和专精的新配置中吗？现有配置、其他分配、账号设置和 SwiftStats 数据均不会更改。",
        ["Import"] = "导入",
        ["SwiftStats settings imported into new profile \"%s\"."] = "SwiftStats 设置已导入新配置“%s”。",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "SwiftStats 导入失败；配置和分配已保留。",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "要重置所有 StatsPro 数据吗？这将永久删除所有配置、角色和专精分配、职责模板、账号设置及保存的位置。SwiftStats 数据不会更改。",
        ["Reset corrupted StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position."] = "要重置损坏的 StatsPro 数据吗？这将永久删除所有配置、角色和专精分配、职责模板、账号设置及保存的位置。",
        ["All StatsPro data reset to defaults."] = "所有 StatsPro 数据已重置为默认值。",
        ["Close"] = "关闭",
        ["Contact"] = "联系", ["Click to copy the link."] = "点击复制链接。",
        ["Copy the link below (Ctrl+C)."] = "复制下方链接（Ctrl+C）。",
        ["Open Settings"] = "打开设置", ["Settings"] = "设置",
        ["Profiles & sharing..."] = "配置与共享...", ["Profiles & sharing"] = "配置与共享",
        ["Shared with %d specializations"] = "与 %d 个专精共享",
        ["Unknown specialization (%d)"] = "未知专精（%d）",
        ["Copy settings from..."] = "复制设置自...", ["Use the same settings as..."] = "使用相同设置...",
        ["Use these settings for..."] = "将这些设置用于...", ["Stop sharing..."] = "停止共享...",
        ["Advanced..."] = "高级...", ["Hide advanced"] = "隐藏高级选项",
        ["Reset these settings..."] = "重置这些设置...", ["Forget this character..."] = "忘记此角色...",
        ["Defaults for future specializations..."] = "未来专精的默认设置...", ["Delete unused settings..."] = "删除未使用的设置...",
        ["Copy %s from \"%s\" to \"%s\"? The destination will keep its own settings afterward."] = "将%s从“%s”复制到“%s”？之后目标将保留独立设置。",
        ["Use the same settings for \"%s\" and \"%s\"? Future changes will affect both."] = "让“%s”和“%s”使用相同设置？今后的更改会同时影响两者。",
        ["Use the shared settings from \"%s\" for \"%s\"? They are already shared by %d specializations; future changes will affect all %d."] = "让“%s”的共享设置也用于“%s”？已有 %d 个专精共享这些设置；今后的更改会影响全部 %d 个专精。",
        ["Give \"%s\" its own copy of these settings? Future changes will no longer affect the other specializations."] = "为“%s”创建这些设置的独立副本？今后的更改将不再影响其他专精。",
        ["Reset the settings used by \"%s\"? The same reset will affect %d specializations."] = "重置“%s”使用的设置？同一次重置会影响 %d 个专精。",
        ["Reset the settings used by \"%s\" to defaults?"] = "将“%s”使用的设置重置为默认值？",
        ["This profile is also a default for future specializations; they will use the reset settings."] = "此配置也是未来专精的默认配置；重置后它们将使用重置后的设置。",
        ["Delete %d unused settings records? Settings currently used by a specialization or future-specialization default will be kept."] = "删除 %d 组未使用的设置？正在使用的设置和未来专精的默认设置将保留。",
        ["Switch pending until combat ends"] = "战斗结束后切换", ["Account default profile"] = "账号默认配置",
        ["Current"] = "当前", ["Active"] = "激活",
        ["No visited characters"] = "没有已访问角色",
        ["Spec %d"] = "专精 %d", ["Profile changes are unavailable during combat."] = "战斗中无法更改配置。",
        ["Waiting for a safe profile context."] = "正在等待安全的配置环境。",
        ["Compatibility mode - profiles are read-only."] = "兼容模式 – 配置为只读。",
        ["Corrupted data - profiles are read-only. Use /ss wipe to reset."] = "数据已损坏 – 配置为只读。请使用 /ss wipe 重置。",
        ["All settings"] = "所有设置", ["Stat and gear settings"] = "属性与装备设置", ["Layout settings"] = "布局设置", ["Appearance settings"] = "外观设置", ["Choose settings to copy"] = "选择要复制的设置",
        ["Confirm"] = "确认", ["Cancel"] = "取消",
        ["Tank"] = "坦克", ["Healer"] = "治疗", ["Damage"] = "输出",
        ["Choose a role"] = "选择职责",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "将“%s”作为未来坦克环境的来源？现有分配不会改变；每个新环境都会获得独立副本。",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "将“%s”作为未来治疗环境的来源？现有分配不会改变；每个新环境都会获得独立副本。",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "将“%s”作为未来输出环境的来源？现有分配不会改变；每个新环境都会获得独立副本。",
        ["Profile changes saved."] = "配置更改已保存。", ["Enter a valid profile name."] = "请输入有效的配置名称。",
        ["A profile with this name already exists."] = "已存在同名配置。",
        ["Profiles changed; review and try again."] = "配置已发生变化。请检查选择后重试。",
        ["The current character cannot be forgotten."] = "无法移除当前角色的记录。",
        ["Nothing changed."] = "没有任何更改。",
        ["Profile operation failed. Review the selection and try again."] = "配置操作失败。请检查选择后重试。",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "将当前配置“%s”重置为默认值？这会更改 %d 个已分配专精和 %d 个其他引用。",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "移除“%s”的记录？角色记录将被删除，但配置设置会保留。",
        ["Auto (current: %s)"] = "自动（当前: %s）",
        ["Western European text"] = "西欧语言文本",
        ["Russian text"] = "俄语文本",
        ["Korean text"] = "韩语文本",
        ["Simplified Chinese text"] = "简体中文",
        ["Traditional Chinese text"] = "繁体中文",
        ["text for the selected language"] = "所选语言的文本",
        ["|cffffaa44⚠|r The selected font may not render %s correctly. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r 所选字体可能无法正确显示%s。请从 SharedMedia 选择覆盖完整的字体。",
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
        -- ===== Settings UI (best-effort draft, Traditional script) =====
        ["Stats"] = "屬性", ["Layout"] = "版面", ["Appearance"] = "外觀",
        ["Character"] = "角色", ["Item Level"] = "裝等",
        ["Offensive"] = "攻擊", ["Tertiary"] = "第三屬性",
        ["Gear"] = "裝備", ["Repair Cost"] = "修理費用",
        ["Side Panel Contains"] = "側面板包含",
        ["Value Display"] = "數值顯示",
        ["Frame & Position"] = "視窗與位置",
        ["Typography"] = "字型",
        ["Readability"] = "可讀性",
        ["Appearance Presets"] = "外觀預設", ["Preset:"] = "預設：",
        ["Default"] = "預設", ["Classic"] = "經典", ["Clean Dark"] = "簡潔深色", ["Midnight"] = "午夜",
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
        ["Raid Normal"] = "普通團隊", ["Raid Heroic"] = "英雄團隊", ["Raid Mythic"] = "傳奇團隊",
        ["Full"] = "完整", ["Short"] = "簡短", ["Hidden"] = "隱藏",
        ["None"] = "無", ["Outline"] = "描邊", ["Thick Outline"] = "粗描邊",
        ["M+ Target"] = "傳奇+目標", ["Raid Target"] = "團隊目標",
        ["M+ High Keys"] = "傳奇+高層", ["Raid Mythic All Bosses"] = "傳奇團隊全部首領",
        ["M+ Current"] = "目前傳奇+", ["Raid Normal All Bosses"] = "普通團隊全部首領", ["Raid Heroic All Bosses"] = "英雄團隊全部首領",
        ["Target:"] = "目標:", ["Current:"] = "目前:", ["Missing:"] = "缺少:",
        ["Over:"] = "超出:", ["Matched:"] = "已達成:", ["Snapshot:"] = "快照:",
        ["Last known comparison"] = "上次已知比較", ["Live values; comparison unavailable"] = "即時數值；無法比較", ["Source:"] = "來源:",
        ["Stats panel shown"] = "屬性面板已顯示", ["Stats panel hidden"] = "屬性面板已隱藏",
        ["Settings reset to defaults"] = "設定已恢復預設",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help"] = "指令: /ss 或 /statspro (設定), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "未載入 SwiftStats 設定。請啟用 SwiftStats 登入一次，執行 /reload，然後再次輸入 /statspro import。",
        ["SwiftStats has no supported settings to import."] = "SwiftStats 中沒有可匯入的支援設定。",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "這些設定使用較新的資料結構，目前版本的 StatsPro 無法匯入。",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "這些設定由較新版本的 StatsPro 儲存，因此目前為唯讀。請更新 StatsPro 後再進行修改。",
        ["StatsPro saved data is corrupted and remains read-only. Use /ss wipe outside combat to reset it."] = "StatsPro 儲存的資料已損壞，目前維持唯讀。請在非戰鬥狀態下使用 /ss wipe 重設。",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "戰鬥中無法匯入 SwiftStats 設定。請在戰鬥結束後重試。",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "要將相容的 SwiftStats 設定匯入目前角色與專精的新設定檔嗎？現有設定檔、其他指派、帳號設定和 SwiftStats 資料都不會變更。",
        ["Import"] = "匯入",
        ["SwiftStats settings imported into new profile \"%s\"."] = "SwiftStats 設定已匯入新設定檔「%s」。",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "SwiftStats 匯入失敗；設定檔和指派已保留。",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "要重設所有 StatsPro 資料嗎？這將永久刪除所有設定檔、角色與專精指派、職責範本、帳號設定和已儲存的位置。SwiftStats 資料不會變更。",
        ["Reset corrupted StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position."] = "要重設損壞的 StatsPro 資料嗎？這將永久刪除所有設定檔、角色與專精指派、職責範本、帳號設定和已儲存的位置。",
        ["All StatsPro data reset to defaults."] = "所有 StatsPro 資料已重設為預設值。",
        ["Close"] = "關閉",
        ["Contact"] = "聯絡", ["Click to copy the link."] = "點擊複製連結。",
        ["Copy the link below (Ctrl+C)."] = "複製下方連結（Ctrl+C）。",
        ["Open Settings"] = "開啟設定", ["Settings"] = "設定",
        ["Profiles & sharing..."] = "設定檔與共用...", ["Profiles & sharing"] = "設定檔與共用",
        ["Shared with %d specializations"] = "與 %d 個專精共用",
        ["Unknown specialization (%d)"] = "未知專精（%d）",
        ["Copy settings from..."] = "複製設定自...", ["Use the same settings as..."] = "使用相同設定...",
        ["Use these settings for..."] = "將這些設定用於...", ["Stop sharing..."] = "停止共用...",
        ["Advanced..."] = "進階...", ["Hide advanced"] = "隱藏進階選項",
        ["Reset these settings..."] = "重設這些設定...", ["Forget this character..."] = "忘記此角色...",
        ["Defaults for future specializations..."] = "未來專精的預設設定...", ["Delete unused settings..."] = "刪除未使用的設定...",
        ["Copy %s from \"%s\" to \"%s\"? The destination will keep its own settings afterward."] = "將%s從「%s」複製到「%s」？之後目標會保留獨立設定。",
        ["Use the same settings for \"%s\" and \"%s\"? Future changes will affect both."] = "讓「%s」與「%s」使用相同設定？之後的變更會同時影響兩者。",
        ["Use the shared settings from \"%s\" for \"%s\"? They are already shared by %d specializations; future changes will affect all %d."] = "讓「%s」的共用設定也用於「%s」？已有 %d 個專精共用這些設定；之後的變更會影響全部 %d 個專精。",
        ["Give \"%s\" its own copy of these settings? Future changes will no longer affect the other specializations."] = "為「%s」建立這些設定的獨立副本？之後的變更將不再影響其他專精。",
        ["Reset the settings used by \"%s\"? The same reset will affect %d specializations."] = "重設「%s」使用的設定？同一次重設會影響 %d 個專精。",
        ["Reset the settings used by \"%s\" to defaults?"] = "將「%s」使用的設定重設為預設值？",
        ["This profile is also a default for future specializations; they will use the reset settings."] = "此設定檔也是未來專精的預設設定檔；重設後它們會使用重設後的設定。",
        ["Delete %d unused settings records? Settings currently used by a specialization or future-specialization default will be kept."] = "刪除 %d 組未使用的設定？使用中的設定與未來專精的預設設定會保留。",
        ["Switch pending until combat ends"] = "戰鬥結束後切換", ["Account default profile"] = "帳號預設設定檔",
        ["Current"] = "目前", ["Active"] = "啟用",
        ["No visited characters"] = "沒有已造訪角色",
        ["Spec %d"] = "專精 %d", ["Profile changes are unavailable during combat."] = "戰鬥中無法變更設定檔。",
        ["Waiting for a safe profile context."] = "正在等待安全的設定檔環境。",
        ["Compatibility mode - profiles are read-only."] = "相容模式 – 設定檔為唯讀。",
        ["Corrupted data - profiles are read-only. Use /ss wipe to reset."] = "資料已損壞 – 設定檔為唯讀。請使用 /ss wipe 重設。",
        ["All settings"] = "所有設定", ["Stat and gear settings"] = "屬性與裝備設定", ["Layout settings"] = "版面設定", ["Appearance settings"] = "外觀設定", ["Choose settings to copy"] = "選擇要複製的設定",
        ["Confirm"] = "確認", ["Cancel"] = "取消",
        ["Tank"] = "坦克", ["Healer"] = "治療", ["Damage"] = "輸出",
        ["Choose a role"] = "選擇職責",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "將「%s」作為未來坦克環境的來源？現有指派不會變更；每個新環境都會取得獨立副本。",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "將「%s」作為未來治療環境的來源？現有指派不會變更；每個新環境都會取得獨立副本。",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "將「%s」作為未來輸出環境的來源？現有指派不會變更；每個新環境都會取得獨立副本。",
        ["Profile changes saved."] = "設定檔變更已儲存。", ["Enter a valid profile name."] = "請輸入有效的設定檔名稱。",
        ["A profile with this name already exists."] = "已有同名設定檔。",
        ["Profiles changed; review and try again."] = "設定檔已發生變更。請檢查選擇後再試一次。",
        ["The current character cannot be forgotten."] = "無法移除目前角色的記錄。",
        ["Nothing changed."] = "沒有任何變更。",
        ["Profile operation failed. Review the selection and try again."] = "設定檔操作失敗。請檢查選擇後再試一次。",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "將目前設定檔「%s」重設為預設值？這會變更 %d 個已指派專精和 %d 個其他參照。",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "移除「%s」的記錄？角色記錄將被刪除，但設定檔內容會保留。",
        ["Auto (current: %s)"] = "自動（目前: %s）",
        ["Western European text"] = "西歐語言文字",
        ["Russian text"] = "俄語文字",
        ["Korean text"] = "韓語文字",
        ["Simplified Chinese text"] = "簡體中文",
        ["Traditional Chinese text"] = "繁體中文",
        ["text for the selected language"] = "所選語言的文字",
        ["|cffffaa44⚠|r The selected font may not render %s correctly. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r 所選字型可能無法正確顯示%s。請從 SharedMedia 選擇涵蓋完整的字型。",
        ["Stats and gear HUD: item level, durability, repair cost and Archon stat targets. Click below to open the full settings window."] = "屬性與裝備 HUD：裝等、耐久度、修理費用及 Archon 屬性目標。點擊下方開啟完整設定視窗。",
    },
}

-- Profile-transfer copy is kept as a compact overlay so the versioned exchange
-- vocabulary stays reviewable as one unit across all shipped locales.
do
    local profileTransferLabels = {
    enUS = {
        ["Export / import profile..."] = "Export / import profile...",
        ["Export this profile"] = "Export this profile",
        ["Import into a new profile"] = "Import into a new profile",
        ["Export profile"] = "Export profile",
        ["Import profile"] = "Import profile",
        ["Select all"] = "Select all",
        ["Preview"] = "Preview",
        ["Imported profile"] = "Imported profile",
        ["Export string ready. Select it, then press Ctrl+C to copy."] = "Export string ready. Select it, then press Ctrl+C to copy.",
        ["Paste a StatsPro profile string, then preview it before importing."] = "Paste a StatsPro profile string, then preview it before importing.",
        ["StatsPro profile: %s"] = "StatsPro profile: %s",
        ["Format version: %d"] = "Format version: %d",
        ["Included: %s"] = "Included: %s",
        ["Choose at least one section."] = "Choose at least one section.",
        ["The profile string is invalid or damaged."] = "The profile string is invalid or damaged.",
        ["This profile string uses a newer unsupported format."] = "This profile string uses a newer unsupported format.",
        ["Import selected sections as a new independent profile for \"%s\"? Existing profiles and unselected settings will stay unchanged."] = "Import selected sections as a new independent profile for \"%s\"? Existing profiles and unselected settings will stay unchanged.",
        ["Imported profile \"%s\" was created."] = "Imported profile \"%s\" was created.",
    },
    ruRU = {
        ["Export / import profile..."] = "Экспорт / импорт профиля...",
        ["Export this profile"] = "Экспортировать этот профиль",
        ["Import into a new profile"] = "Импортировать в новый профиль",
        ["Export profile"] = "Экспорт профиля",
        ["Import profile"] = "Импорт профиля",
        ["Select all"] = "Выделить всё",
        ["Preview"] = "Предпросмотр",
        ["Imported profile"] = "Импортированный профиль",
        ["Export string ready. Select it, then press Ctrl+C to copy."] = "Строка готова. Выделите её и нажмите Ctrl+C.",
        ["Paste a StatsPro profile string, then preview it before importing."] = "Вставьте строку профиля StatsPro и проверьте её перед импортом.",
        ["StatsPro profile: %s"] = "Профиль StatsPro: %s",
        ["Format version: %d"] = "Версия формата: %d",
        ["Included: %s"] = "Включено: %s",
        ["Choose at least one section."] = "Выберите хотя бы один раздел.",
        ["The profile string is invalid or damaged."] = "Строка профиля недействительна или повреждена.",
        ["This profile string uses a newer unsupported format."] = "Строка создана в более новой неподдерживаемой версии формата.",
        ["Import selected sections as a new independent profile for \"%s\"? Existing profiles and unselected settings will stay unchanged."] = "Импортировать выбранные разделы как новый независимый профиль для «%s»? Существующие профили и невыбранные настройки не изменятся.",
        ["Imported profile \"%s\" was created."] = "Импортированный профиль «%s» создан.",
    },
    deDE = {
        ["Export / import profile..."] = "Profil exportieren / importieren...",
        ["Export this profile"] = "Dieses Profil exportieren",
        ["Import into a new profile"] = "In ein neues Profil importieren",
        ["Export profile"] = "Profil exportieren",
        ["Import profile"] = "Profil importieren",
        ["Select all"] = "Alles markieren",
        ["Preview"] = "Vorschau",
        ["Imported profile"] = "Importiertes Profil",
        ["Export string ready. Select it, then press Ctrl+C to copy."] = "Exportzeichenfolge ist bereit. Markiere sie und drücke Strg+C.",
        ["Paste a StatsPro profile string, then preview it before importing."] = "Füge eine StatsPro-Profilzeichenfolge ein und prüfe sie vor dem Import.",
        ["StatsPro profile: %s"] = "StatsPro-Profil: %s",
        ["Format version: %d"] = "Formatversion: %d",
        ["Included: %s"] = "Enthalten: %s",
        ["Choose at least one section."] = "Wähle mindestens einen Bereich.",
        ["The profile string is invalid or damaged."] = "Die Profilzeichenfolge ist ungültig oder beschädigt.",
        ["This profile string uses a newer unsupported format."] = "Diese Profilzeichenfolge verwendet ein neueres, nicht unterstütztes Format.",
        ["Import selected sections as a new independent profile for \"%s\"? Existing profiles and unselected settings will stay unchanged."] = "Ausgewählte Bereiche als neues unabhängiges Profil für „%s“ importieren? Bestehende Profile und nicht ausgewählte Einstellungen bleiben unverändert.",
        ["Imported profile \"%s\" was created."] = "Das importierte Profil „%s“ wurde erstellt.",
    },
    frFR = {
        ["Export / import profile..."] = "Exporter / importer un profil...",
        ["Export this profile"] = "Exporter ce profil",
        ["Import into a new profile"] = "Importer dans un nouveau profil",
        ["Export profile"] = "Exporter le profil",
        ["Import profile"] = "Importer le profil",
        ["Select all"] = "Tout sélectionner",
        ["Preview"] = "Aperçu",
        ["Imported profile"] = "Profil importé",
        ["Export string ready. Select it, then press Ctrl+C to copy."] = "La chaîne est prête. Sélectionnez-la puis appuyez sur Ctrl+C.",
        ["Paste a StatsPro profile string, then preview it before importing."] = "Collez une chaîne de profil StatsPro puis vérifiez-la avant l’importation.",
        ["StatsPro profile: %s"] = "Profil StatsPro : %s",
        ["Format version: %d"] = "Version du format : %d",
        ["Included: %s"] = "Inclus : %s",
        ["Choose at least one section."] = "Sélectionnez au moins une section.",
        ["The profile string is invalid or damaged."] = "La chaîne de profil est invalide ou endommagée.",
        ["This profile string uses a newer unsupported format."] = "Cette chaîne utilise un format plus récent non pris en charge.",
        ["Import selected sections as a new independent profile for \"%s\"? Existing profiles and unselected settings will stay unchanged."] = "Importer les sections sélectionnées dans un nouveau profil indépendant pour « %s » ? Les profils existants et les réglages non sélectionnés resteront inchangés.",
        ["Imported profile \"%s\" was created."] = "Le profil importé « %s » a été créé.",
    },
    esES = {
        ["Export / import profile..."] = "Exportar / importar perfil...",
        ["Export this profile"] = "Exportar este perfil",
        ["Import into a new profile"] = "Importar a un perfil nuevo",
        ["Export profile"] = "Exportar perfil",
        ["Import profile"] = "Importar perfil",
        ["Select all"] = "Seleccionar todo",
        ["Preview"] = "Vista previa",
        ["Imported profile"] = "Perfil importado",
        ["Export string ready. Select it, then press Ctrl+C to copy."] = "La cadena está lista. Selecciónala y pulsa Ctrl+C.",
        ["Paste a StatsPro profile string, then preview it before importing."] = "Pega una cadena de perfil de StatsPro y revísala antes de importarla.",
        ["StatsPro profile: %s"] = "Perfil de StatsPro: %s",
        ["Format version: %d"] = "Versión del formato: %d",
        ["Included: %s"] = "Incluye: %s",
        ["Choose at least one section."] = "Elige al menos una sección.",
        ["The profile string is invalid or damaged."] = "La cadena de perfil no es válida o está dañada.",
        ["This profile string uses a newer unsupported format."] = "Esta cadena usa un formato más reciente no compatible.",
        ["Import selected sections as a new independent profile for \"%s\"? Existing profiles and unselected settings will stay unchanged."] = "¿Importar las secciones seleccionadas como un perfil independiente nuevo para «%s»? Los perfiles existentes y los ajustes no seleccionados no cambiarán.",
        ["Imported profile \"%s\" was created."] = "Se ha creado el perfil importado «%s».",
    },
    itIT = {
        ["Export / import profile..."] = "Esporta / importa profilo...",
        ["Export this profile"] = "Esporta questo profilo",
        ["Import into a new profile"] = "Importa in un nuovo profilo",
        ["Export profile"] = "Esporta profilo",
        ["Import profile"] = "Importa profilo",
        ["Select all"] = "Seleziona tutto",
        ["Preview"] = "Anteprima",
        ["Imported profile"] = "Profilo importato",
        ["Export string ready. Select it, then press Ctrl+C to copy."] = "La stringa è pronta. Selezionala e premi Ctrl+C.",
        ["Paste a StatsPro profile string, then preview it before importing."] = "Incolla una stringa profilo StatsPro e controllala prima di importarla.",
        ["StatsPro profile: %s"] = "Profilo StatsPro: %s",
        ["Format version: %d"] = "Versione formato: %d",
        ["Included: %s"] = "Incluso: %s",
        ["Choose at least one section."] = "Scegli almeno una sezione.",
        ["The profile string is invalid or damaged."] = "La stringa del profilo non è valida o è danneggiata.",
        ["This profile string uses a newer unsupported format."] = "Questa stringa usa un formato più recente non supportato.",
        ["Import selected sections as a new independent profile for \"%s\"? Existing profiles and unselected settings will stay unchanged."] = "Importare le sezioni selezionate come nuovo profilo indipendente per «%s»? I profili esistenti e le impostazioni non selezionate resteranno invariati.",
        ["Imported profile \"%s\" was created."] = "Il profilo importato «%s» è stato creato.",
    },
    ptBR = {
        ["Export / import profile..."] = "Exportar / importar perfil...",
        ["Export this profile"] = "Exportar este perfil",
        ["Import into a new profile"] = "Importar para um novo perfil",
        ["Export profile"] = "Exportar perfil",
        ["Import profile"] = "Importar perfil",
        ["Select all"] = "Selecionar tudo",
        ["Preview"] = "Prévia",
        ["Imported profile"] = "Perfil importado",
        ["Export string ready. Select it, then press Ctrl+C to copy."] = "A string está pronta. Selecione-a e pressione Ctrl+C.",
        ["Paste a StatsPro profile string, then preview it before importing."] = "Cole uma string de perfil do StatsPro e confira antes de importar.",
        ["StatsPro profile: %s"] = "Perfil do StatsPro: %s",
        ["Format version: %d"] = "Versão do formato: %d",
        ["Included: %s"] = "Incluído: %s",
        ["Choose at least one section."] = "Escolha pelo menos uma seção.",
        ["The profile string is invalid or damaged."] = "A string do perfil é inválida ou está danificada.",
        ["This profile string uses a newer unsupported format."] = "Esta string usa um formato mais recente sem suporte.",
        ["Import selected sections as a new independent profile for \"%s\"? Existing profiles and unselected settings will stay unchanged."] = "Importar as seções selecionadas como um novo perfil independente para “%s”? Os perfis existentes e as configurações não selecionadas permanecerão inalterados.",
        ["Imported profile \"%s\" was created."] = "O perfil importado “%s” foi criado.",
    },
    koKR = {
        ["Export / import profile..."] = "프로필 내보내기 / 가져오기...",
        ["Export this profile"] = "이 프로필 내보내기",
        ["Import into a new profile"] = "새 프로필로 가져오기",
        ["Export profile"] = "프로필 내보내기",
        ["Import profile"] = "프로필 가져오기",
        ["Select all"] = "모두 선택",
        ["Preview"] = "미리 보기",
        ["Imported profile"] = "가져온 프로필",
        ["Export string ready. Select it, then press Ctrl+C to copy."] = "내보내기 문자열이 준비되었습니다. 선택한 뒤 Ctrl+C를 누르세요.",
        ["Paste a StatsPro profile string, then preview it before importing."] = "StatsPro 프로필 문자열을 붙여넣고 가져오기 전에 확인하세요.",
        ["StatsPro profile: %s"] = "StatsPro 프로필: %s",
        ["Format version: %d"] = "형식 버전: %d",
        ["Included: %s"] = "포함: %s",
        ["Choose at least one section."] = "하나 이상의 섹션을 선택하세요.",
        ["The profile string is invalid or damaged."] = "프로필 문자열이 잘못되었거나 손상되었습니다.",
        ["This profile string uses a newer unsupported format."] = "이 문자열은 지원되지 않는 새 형식을 사용합니다.",
        ["Import selected sections as a new independent profile for \"%s\"? Existing profiles and unselected settings will stay unchanged."] = "선택한 섹션을 “%s”의 새 독립 프로필로 가져오시겠습니까? 기존 프로필과 선택하지 않은 설정은 변경되지 않습니다.",
        ["Imported profile \"%s\" was created."] = "가져온 프로필 “%s”을(를) 만들었습니다.",
    },
    zhCN = {
        ["Export / import profile..."] = "导出 / 导入配置...",
        ["Export this profile"] = "导出此配置",
        ["Import into a new profile"] = "导入为新配置",
        ["Export profile"] = "导出配置",
        ["Import profile"] = "导入配置",
        ["Select all"] = "全选",
        ["Preview"] = "预览",
        ["Imported profile"] = "导入的配置",
        ["Export string ready. Select it, then press Ctrl+C to copy."] = "导出字符串已就绪。选中后按 Ctrl+C 复制。",
        ["Paste a StatsPro profile string, then preview it before importing."] = "粘贴 StatsPro 配置字符串，并在导入前预览。",
        ["StatsPro profile: %s"] = "StatsPro 配置：%s",
        ["Format version: %d"] = "格式版本：%d",
        ["Included: %s"] = "包含：%s",
        ["Choose at least one section."] = "请至少选择一个部分。",
        ["The profile string is invalid or damaged."] = "配置字符串无效或已损坏。",
        ["This profile string uses a newer unsupported format."] = "此字符串使用了尚不支持的新版格式。",
        ["Import selected sections as a new independent profile for \"%s\"? Existing profiles and unselected settings will stay unchanged."] = "将所选部分作为“%s”的新独立配置导入？现有配置和未选设置不会改变。",
        ["Imported profile \"%s\" was created."] = "已创建导入配置“%s”。",
    },
    zhTW = {
        ["Export / import profile..."] = "匯出 / 匯入設定檔...",
        ["Export this profile"] = "匯出此設定檔",
        ["Import into a new profile"] = "匯入為新設定檔",
        ["Export profile"] = "匯出設定檔",
        ["Import profile"] = "匯入設定檔",
        ["Select all"] = "全選",
        ["Preview"] = "預覽",
        ["Imported profile"] = "匯入的設定檔",
        ["Export string ready. Select it, then press Ctrl+C to copy."] = "匯出字串已就緒。選取後按 Ctrl+C 複製。",
        ["Paste a StatsPro profile string, then preview it before importing."] = "貼上 StatsPro 設定檔字串，並在匯入前預覽。",
        ["StatsPro profile: %s"] = "StatsPro 設定檔：%s",
        ["Format version: %d"] = "格式版本：%d",
        ["Included: %s"] = "包含：%s",
        ["Choose at least one section."] = "請至少選擇一個區段。",
        ["The profile string is invalid or damaged."] = "設定檔字串無效或已損毀。",
        ["This profile string uses a newer unsupported format."] = "此字串使用尚未支援的新版格式。",
        ["Import selected sections as a new independent profile for \"%s\"? Existing profiles and unselected settings will stay unchanged."] = "將所選區段作為「%s」的新獨立設定檔匯入？現有設定檔與未選設定不會變更。",
        ["Imported profile \"%s\" was created."] = "已建立匯入的設定檔「%s」。",
    },
}
    profileTransferLabels.esMX = profileTransferLabels.esES
    for locale, transferLabels in pairs(profileTransferLabels) do
        for key, value in pairs(transferLabels) do LABELS_BY_LOCALE[locale][key] = value end
    end
end

-- Keep the small Quick Setup vocabulary together so every shipped locale gets
-- the same first-run surface without expanding the already-large base tables.
do
    local quickSetupLabels = {
    enUS = {
        ["Quick Setup"] = "Quick Setup",
        ["Compact"] = "Compact",
        ["DPS"] = "DPS",
        ["Secondary stats only"] = "Secondary stats only",
        ["DPS and tertiary stats with gear status"] = "DPS and tertiary stats with gear status",
        ["DPS, tertiary, and defensive stats with gear status"] = "DPS, tertiary, and defensive stats with gear status",
        ["Choose a finished HUD layout. Click a card to preview it."] = "Choose a finished HUD layout. Click a card to preview it.",
        ["Current setup: %s"] = "Current setup: %s",
        ["Use this setup"] = "Use this setup",
        ["Stat rows, value display, durability summary, and panel layout can change. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "Stat rows, value display, durability summary, and panel layout can change. Appearance, scale, positions, language, and profile assignments stay unchanged.",
        ["This sets up the current profile. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "This sets up the current profile. Appearance, scale, positions, language, and profile assignments stay unchanged.",
    },
    ruRU = {
        ["Quick Setup"] = "Быстрая настройка",
        ["Compact"] = "Компактный",
        ["DPS"] = "ДПС",
        ["Secondary stats only"] = "Только вторичные характеристики",
        ["DPS and tertiary stats with gear status"] = "ДПС, третичные характеристики и экипировка",
        ["DPS, tertiary, and defensive stats with gear status"] = "ДПС, третичные, защитные характеристики и экипировка",
        ["Choose a finished HUD layout. Click a card to preview it."] = "Выберите готовую раскладку HUD. Нажмите карточку для предпросмотра.",
        ["Current setup: %s"] = "Текущая раскладка: %s",
        ["Use this setup"] = "Использовать",
        ["Stat rows, value display, durability summary, and panel layout can change. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "Могут измениться строки характеристик, отображение значений, сводка прочности и раскладка панелей. Внешний вид, масштаб, позиции, язык и назначения профилей сохраняются.",
        ["This sets up the current profile. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "Это настроит текущий профиль. Внешний вид, масштаб, позиции, язык и назначения профилей сохраняются.",
    },
    deDE = {
        ["Quick Setup"] = "Schnelleinrichtung",
        ["Compact"] = "Kompakt",
        ["DPS"] = "DPS",
        ["Secondary stats only"] = "Nur Sekundärwerte",
        ["DPS and tertiary stats with gear status"] = "DPS- und Tertiärwerte mit Ausrüstung",
        ["DPS, tertiary, and defensive stats with gear status"] = "DPS-, Tertiär- und Defensivwerte mit Ausrüstung",
        ["Choose a finished HUD layout. Click a card to preview it."] = "Wähle ein fertiges HUD-Layout. Klicke auf eine Karte für die Vorschau.",
        ["Current setup: %s"] = "Aktuelles Layout: %s",
        ["Use this setup"] = "Dieses Layout verwenden",
        ["Stat rows, value display, durability summary, and panel layout can change. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "Wertezeilen, Wertanzeige, Haltbarkeitsübersicht und Panel-Layout können sich ändern. Aussehen, Skalierung, Positionen, Sprache und Profilzuweisungen bleiben unverändert.",
        ["This sets up the current profile. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "Damit wird das aktuelle Profil eingerichtet. Aussehen, Skalierung, Positionen, Sprache und Profilzuweisungen bleiben unverändert.",
    },
    frFR = {
        ["Quick Setup"] = "Configuration rapide",
        ["Compact"] = "Compact",
        ["DPS"] = "DPS",
        ["Secondary stats only"] = "Caractéristiques secondaires uniquement",
        ["DPS and tertiary stats with gear status"] = "DPS, tertiaires et état de l’équipement",
        ["DPS, tertiary, and defensive stats with gear status"] = "DPS, tertiaires, défense et équipement",
        ["Choose a finished HUD layout. Click a card to preview it."] = "Choisissez une disposition HUD prête à l’emploi. Cliquez sur une carte pour l’aperçu.",
        ["Current setup: %s"] = "Disposition actuelle : %s",
        ["Use this setup"] = "Utiliser cette disposition",
        ["Stat rows, value display, durability summary, and panel layout can change. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "Les lignes de caractéristiques, l’affichage des valeurs, le résumé de durabilité et la disposition peuvent changer. Apparence, échelle, positions, langue et affectations restent inchangées.",
        ["This sets up the current profile. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "Cela configure le profil actuel. Apparence, échelle, positions, langue et affectations restent inchangées.",
    },
    esES = {
        ["Quick Setup"] = "Configuración rápida",
        ["Compact"] = "Compacto",
        ["DPS"] = "DPS",
        ["Secondary stats only"] = "Solo estadísticas secundarias",
        ["DPS and tertiary stats with gear status"] = "DPS, estadísticas terciarias y estado del equipo",
        ["DPS, tertiary, and defensive stats with gear status"] = "DPS, terciarias, defensas y estado del equipo",
        ["Choose a finished HUD layout. Click a card to preview it."] = "Elige un diseño de HUD listo. Haz clic en una tarjeta para previsualizarlo.",
        ["Current setup: %s"] = "Diseño actual: %s",
        ["Use this setup"] = "Usar este diseño",
        ["Stat rows, value display, durability summary, and panel layout can change. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "Pueden cambiar las filas de estadísticas, los valores, el resumen de durabilidad y el diseño. La apariencia, escala, posiciones, idioma y asignaciones de perfil no cambian.",
        ["This sets up the current profile. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "Esto configura el perfil actual. La apariencia, escala, posiciones, idioma y asignaciones de perfil no cambian.",
    },
    itIT = {
        ["Quick Setup"] = "Configurazione rapida",
        ["Compact"] = "Compatto",
        ["DPS"] = "DPS",
        ["Secondary stats only"] = "Solo statistiche secondarie",
        ["DPS and tertiary stats with gear status"] = "DPS, statistiche terziarie e stato equipaggiamento",
        ["DPS, tertiary, and defensive stats with gear status"] = "DPS, terziarie, difese e stato equipaggiamento",
        ["Choose a finished HUD layout. Click a card to preview it."] = "Scegli un layout HUD completo. Fai clic su una scheda per l’anteprima.",
        ["Current setup: %s"] = "Layout attuale: %s",
        ["Use this setup"] = "Usa questo layout",
        ["Stat rows, value display, durability summary, and panel layout can change. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "Possono cambiare le righe delle statistiche, i valori, il riepilogo durabilità e il layout. Aspetto, scala, posizioni, lingua e assegnazioni restano invariati.",
        ["This sets up the current profile. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "Questo configura il profilo attuale. Aspetto, scala, posizioni, lingua e assegnazioni restano invariati.",
    },
    ptBR = {
        ["Quick Setup"] = "Configuração rápida",
        ["Compact"] = "Compacto",
        ["DPS"] = "DPS",
        ["Secondary stats only"] = "Somente atributos secundários",
        ["DPS and tertiary stats with gear status"] = "DPS, atributos terciários e estado do equipamento",
        ["DPS, tertiary, and defensive stats with gear status"] = "DPS, terciários, defesas e estado do equipamento",
        ["Choose a finished HUD layout. Click a card to preview it."] = "Escolha um layout de HUD pronto. Clique em um cartão para visualizar.",
        ["Current setup: %s"] = "Layout atual: %s",
        ["Use this setup"] = "Usar este layout",
        ["Stat rows, value display, durability summary, and panel layout can change. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "As linhas de atributos, os valores, o resumo de durabilidade e o layout podem mudar. Aparência, escala, posições, idioma e atribuições de perfil não mudam.",
        ["This sets up the current profile. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "Isso configura o perfil atual. Aparência, escala, posições, idioma e atribuições de perfil não mudam.",
    },
    koKR = {
        ["Quick Setup"] = "빠른 설정",
        ["Compact"] = "간단히",
        ["DPS"] = "공격",
        ["Secondary stats only"] = "보조 능력치만 표시",
        ["DPS and tertiary stats with gear status"] = "공격 및 3차 능력치와 장비 상태",
        ["DPS, tertiary, and defensive stats with gear status"] = "공격, 3차 및 방어 능력치와 장비 상태",
        ["Choose a finished HUD layout. Click a card to preview it."] = "완성된 HUD 구성을 선택하세요. 카드를 클릭하면 미리 볼 수 있습니다.",
        ["Current setup: %s"] = "현재 구성: %s",
        ["Use this setup"] = "이 구성 사용",
        ["Stat rows, value display, durability summary, and panel layout can change. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "능력치 행, 값 표시, 내구도 요약 및 패널 배치가 변경될 수 있습니다. 외형, 크기, 위치, 언어 및 프로필 지정은 유지됩니다.",
        ["This sets up the current profile. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "현재 프로필을 설정합니다. 외형, 크기, 위치, 언어 및 프로필 지정은 유지됩니다.",
    },
    zhCN = {
        ["Quick Setup"] = "快速设置",
        ["Compact"] = "紧凑",
        ["DPS"] = "输出",
        ["Secondary stats only"] = "仅显示次要属性",
        ["DPS and tertiary stats with gear status"] = "输出、第三属性和装备状态",
        ["DPS, tertiary, and defensive stats with gear status"] = "输出、第三属性、防御属性和装备状态",
        ["Choose a finished HUD layout. Click a card to preview it."] = "选择一套完整的 HUD 布局。点击卡片即可预览。",
        ["Current setup: %s"] = "当前布局：%s",
        ["Use this setup"] = "使用此布局",
        ["Stat rows, value display, durability summary, and panel layout can change. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "属性行、数值显示、耐久度汇总和面板布局可能会更改。外观、缩放、位置、语言和配置分配保持不变。",
        ["This sets up the current profile. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "这会设置当前配置。外观、缩放、位置、语言和配置分配保持不变。",
    },
    zhTW = {
        ["Quick Setup"] = "快速設定",
        ["Compact"] = "精簡",
        ["DPS"] = "輸出",
        ["Secondary stats only"] = "僅顯示次要屬性",
        ["DPS and tertiary stats with gear status"] = "輸出、第三屬性和裝備狀態",
        ["DPS, tertiary, and defensive stats with gear status"] = "輸出、第三屬性、防禦屬性和裝備狀態",
        ["Choose a finished HUD layout. Click a card to preview it."] = "選擇一套完整的 HUD 版面。點擊卡片即可預覽。",
        ["Current setup: %s"] = "目前版面：%s",
        ["Use this setup"] = "使用此版面",
        ["Stat rows, value display, durability summary, and panel layout can change. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "屬性列、數值顯示、耐久度摘要和面板版面可能會變更。外觀、縮放、位置、語言和設定檔指派保持不變。",
        ["This sets up the current profile. Appearance, scale, positions, language, and profile assignments stay unchanged."] = "這會設定目前的設定檔。外觀、縮放、位置、語言和設定檔指派保持不變。",
    },
}
    quickSetupLabels.esMX = quickSetupLabels.esES
    for locale, setupLabels in pairs(quickSetupLabels) do
        for key, value in pairs(setupLabels) do LABELS_BY_LOCALE[locale][key] = value end
    end
end

-- WARNING: must precede ResolveActiveLocale — forward-ref to GetDB resolves as _G.GetDB at parse time.
local function GetDB(key)
    local db = addon.dbRuntime.GetSettingStore(key)
    local v = db[key]
    local secretOK, secret = pcall(issecretvalue, v)
    if not secretOK or secret or v == nil then v = defaults[key] end
    if addon.presetRuntime and addon.presetRuntime.ResolveValue then
        v = addon.presetRuntime.ResolveValue(key, v)
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
    if addon.presetRuntime and addon.presetRuntime.ResolveValue then
        value = addon.presetRuntime.ResolveValue(key, value)
    end
    return value == true
end

local function GetFontDB()
    local db = addon.dbRuntime.GetActiveSettings()
    local usable, status
    if addon.fontRuntime.usablePath then
        usable, status = addon.fontRuntime.usablePath(db.font)
    end
    if usable then return usable end
    if status == "pending" and addon.fontRuntime.catalogEntry then
        local catalogPath = addon.fontRuntime.catalogEntry(db.font)
        if catalogPath then return catalogPath end
    end
    if addon.fontRuntime.safeDefaultPath then return addon.fontRuntime.safeDefaultPath() end
    return "Fonts\\FRIZQT__.TTF"
end

local function GetSavedAutoFontDB()
    local db = addon.dbRuntime.GetActiveSettings()
    if not addon.fontRuntime.usablePath then return nil end
    local usable, status = addon.fontRuntime.usablePath(db.fontBeforeAutoSwitch)
    if usable then return usable end
    if status == "pending" and addon.fontRuntime.catalogEntry then
        return addon.fontRuntime.catalogEntry(db.fontBeforeAutoSwitch)
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

addon.positionRuntime = {
    legacyOffsetFloor = 3000,
}

function addon.positionRuntime.GetOffsetBound(axis)
    local fallback = addon.positionRuntime.legacyOffsetFloor
    if not UIParent then return fallback end
    local getter = axis == "y" and UIParent.GetHeight or UIParent.GetWidth
    if type(getter) ~= "function" then return fallback end
    local readOK, extent = pcall(getter, UIParent)
    if not readOK then return fallback end
    local secretOK, secret = pcall(issecretvalue, extent)
    if not secretOK or secret or not IsFiniteNumber(extent) or extent <= 0 then
        return fallback
    end
    -- WHY: mixed anchors can require a full-parent offset while remaining on-screen.
    -- Retaining the legacy floor avoids invalidating existing positions on smaller UIs.
    return math.max(fallback, extent)
end

function addon.positionRuntime.IsValidOffset(value, axis)
    local secretOK, secret = pcall(issecretvalue, value)
    if not secretOK or secret or not IsFiniteNumber(value) then return false end
    local bound = addon.positionRuntime.GetOffsetBound(axis)
    return value >= -bound and value <= bound
end

local function NormalizePositionOffset(value, fallback, axis)
    if addon.positionRuntime.IsValidOffset(value, axis) then return value end
    if addon.positionRuntime.IsValidOffset(fallback, axis) then return fallback end
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
    if addon.presetRuntime and addon.presetRuntime.ResolveValue then
        v = addon.presetRuntime.ResolveValue(key, v)
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
        local lower = addon.fontRuntime.asciiLower(
            string.match(fontPath, "[^\\/]+$") or fontPath)
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
-- removed. On a cold client, a loose font can require activation through an attached
-- FontObject before ordinary FontStrings expose it. SetFont's boolean alone is not
-- authoritative: attempt activation, read back the effective font, and keep inconclusive
-- assets pending instead of destructively replacing the user's saved preference.
addon.fontRuntime.probeFontString = UIParent:CreateFontString(nil, "OVERLAY")
addon.fontRuntime.probeFontString:Hide()
addon.fontRuntime.probeResults = {}
addon.fontRuntime.ownedFontObjects = {}
addon.fontRuntime.ownedFontObjectSequence = 0
addon.fontRuntime.fontActivatorObject = nil
addon.fontRuntime.fontActivatorString = nil
addon.fontRuntime.fontActivatorAttached = false
addon.fontRuntime.pendingSavedFont = nil
addon.fontRuntime.pendingRetryAttempt = 0
addon.fontRuntime.pendingRetryGeneration = 0
addon.fontRuntime.pendingRetryScheduled = false
addon.fontRuntime.pendingRetryDelays = { 0.2, 1, 3, 5 }

function addon.fontRuntime.initializeFontActivator()
    if addon.fontRuntime.fontActivatorObject and addon.fontRuntime.fontActivatorAttached then
        return addon.fontRuntime.fontActivatorObject
    end

    local fontObject = addon.fontRuntime.fontActivatorObject
    if not fontObject then
        if type(_G.CreateFont) ~= "function" then return nil end
        local created
        created, fontObject = pcall(_G.CreateFont, "StatsProFontAssetActivator")
        if not created or not fontObject or type(fontObject.SetFont) ~= "function" then return nil end
        addon.fontRuntime.fontActivatorObject = fontObject
    end

    local holder = addon.fontRuntime.fontActivatorString
    if not holder then
        holder = UIParent:CreateFontString(nil, "OVERLAY")
        if not holder or type(holder.SetFontObject) ~= "function" then return nil end
        addon.fontRuntime.fontActivatorString = holder
    end
    local attached = pcall(holder.SetFontObject, holder, fontObject)
    if not attached then return nil end
    holder:Hide()

    addon.fontRuntime.fontActivatorAttached = true
    return fontObject
end

function addon.fontRuntime.activateLooseFont(fontPath, size)
    local fontObject = addon.fontRuntime.initializeFontActivator()
    if not fontObject then return false end
    -- FontObject:SetFont is a void API. Its nil result is normal; pcall only
    -- establishes that the client accepted the asset before the real FontString
    -- probe below verifies the effective path, size, and flags.
    return pcall(fontObject.SetFont, fontObject, fontPath, size, "")
end

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

function addon.fontRuntime.isKnownAsset(fontPath)
    if type(C_UIFileAsset) ~= "table" or type(C_UIFileAsset.IsKnownFile) ~= "function" then
        return nil
    end
    local ok, known = pcall(C_UIFileAsset.IsKnownFile, fontPath)
    if not ok then return nil end
    local secretOK, secret = pcall(issecretvalue, known)
    if not secretOK or secret or type(known) ~= "boolean" then return nil end
    return known
end

function addon.fontRuntime.matchesAppliedFont(region, fontPath, size, flags)
    if not region or type(region.GetFont) ~= "function" then return false end
    local ok, actualFont, actualSize, actualFlags = pcall(region.GetFont, region)
    if not ok or not SameFontPath(actualFont, fontPath) then return false end
    local sizeSecretOK, sizeSecret = pcall(issecretvalue, actualSize)
    local flagsSecretOK, flagsSecret = pcall(issecretvalue, actualFlags)
    if not sizeSecretOK or sizeSecret or not flagsSecretOK or flagsSecret then return false end
    if not IsFiniteNumber(actualSize) or not IsFiniteNumber(size) then return false end
    if math.abs(actualSize - size) > 0.01 then return false end
    local actualNormalized = actualFlags == nil and "" or actualFlags
    local expectedNormalized = flags == nil and "" or flags
    return type(actualNormalized) == "string"
        and type(expectedNormalized) == "string"
        and actualNormalized == expectedNormalized
end

function addon.fontRuntime.trySetFont(region, fontPath, size, flags)
    if not region or type(region.SetFont) ~= "function" then return "invalid" end
    local ok = pcall(region.SetFont, region, fontPath, size, flags)
    if not ok then return "invalid" end
    -- SetFont's pseudo-return varies by client state and font source. Only the
    -- effective path, size, and flags reported by GetFont prove application.
    if addon.fontRuntime.matchesAppliedFont(region, fontPath, size, flags) then return "applied" end
    -- A missing Blizzard asset is definitive because its file table is fixed before
    -- addons load. External loose files are different: IsKnownFile does not prove
    -- existence/openability or distinguish failure from an inconclusive cold readback.
    if IsBlizzardFontPath(fontPath) and addon.fontRuntime.isKnownAsset(fontPath) == false then
        return "invalid"
    end
    return "pending"
end

function addon.fontRuntime.getOwnedFontObject(ownerKey)
    if type(ownerKey) ~= "string" or ownerKey == "" then return nil end
    local existing = addon.fontRuntime.ownedFontObjects[ownerKey]
    if existing then return existing end
    if type(_G.CreateFont) ~= "function" then return nil end

    addon.fontRuntime.ownedFontObjectSequence = addon.fontRuntime.ownedFontObjectSequence + 1
    local objectName = "StatsProOwnedFont" .. addon.fontRuntime.ownedFontObjectSequence
    local created, fontObject = pcall(_G.CreateFont, objectName)
    if not created or not fontObject
        or type(fontObject.SetFont) ~= "function"
        or type(fontObject.GetFont) ~= "function" then
        return nil
    end
    addon.fontRuntime.ownedFontObjects[ownerKey] = fontObject
    return fontObject
end

function addon.fontRuntime.attachOwnedFontObject(region, fontObject)
    if not region
        or type(region.SetFontObject) ~= "function"
        or type(region.GetFontObject) ~= "function"
        or not fontObject then
        return false
    end
    local attached = pcall(region.SetFontObject, region, fontObject)
    if not attached then return false end
    local readOK, actualObject = pcall(region.GetFontObject, region)
    if not readOK or not rawequal(actualObject, fontObject) then return false end
    return true
end

function addon.fontRuntime.ownedRegionsMatch(regions, fontObject, fontPath, size, flags)
    for _, region in ipairs(regions) do
        if type(region.GetFontObject) ~= "function" then return false end
        local readOK, actualObject = pcall(region.GetFontObject, region)
        if not readOK or not rawequal(actualObject, fontObject) then return false end
        if not addon.fontRuntime.matchesAppliedFont(region, fontPath, size, flags) then
            return false
        end
    end
    return true
end

function addon.fontRuntime.setOwnedFont(fontObject, regions, fontPath, size, flags)
    if not fontObject then return false, "invalid" end
    -- SimpleFont:SetFont is void and requires a non-nil TBFFlags value. Effective
    -- object state plus every attached region's inherited state are authoritative.
    local status = addon.fontRuntime.trySetFont(fontObject, fontPath, size, flags or "")
    if status ~= "applied" then return false, status end
    if regions and not addon.fontRuntime.ownedRegionsMatch(
            regions, fontObject, fontPath, size, flags) then
        return false, "pending"
    end
    return true, "applied"
end

function addon.fontRuntime.probeStatus(fontPath, size, flags)
    local key = FontPathKey(fontPath)
    if not key then return "invalid" end
    local cacheKey = key .. "\031" .. (flags or "") .. "\031" .. tostring(size)
    local cachedResult = addon.fontRuntime.probeResults[cacheKey]
    if cachedResult ~= nil then return cachedResult end
    local status = addon.fontRuntime.trySetFont(
        addon.fontRuntime.probeFontString, fontPath, size, flags)
    -- On a cold client, loose SharedMedia files can return false from a direct
    -- FontString:SetFont until any attached FontObject has loaded that asset.
    -- Keep the activator isolated: direct SetFont would break its inheritance,
    -- and sharing it with HUD/config regions would couple unrelated sizes/flags.
    if status == "pending" and not IsBlizzardFontPath(fontPath)
        and addon.fontRuntime.activateLooseFont(fontPath, size) then
        status = addon.fontRuntime.trySetFont(
            addon.fontRuntime.probeFontString, fontPath, size, flags)
    end
    -- A pending result is deliberately retried: a cold client can keep returning
    -- an inconclusive SetFont/GetFont observation without any LSM catalogue change.
    if status ~= "pending" then addon.fontRuntime.probeResults[cacheKey] = status end
    return status
end

function addon.fontRuntime.usableCatalogPath(fontPath)
    if not FontPathKey(fontPath) then return nil, "invalid" end
    local status = addon.fontRuntime.probeStatus(fontPath, defaults.fontSize, nil)
    if status == "applied" then return fontPath, status end
    return nil, status
end

function addon.fontRuntime.usablePath(fontPath)
    if not FontPathKey(fontPath) then return nil, "invalid" end
    local catalogPath = addon.fontRuntime.catalogEntry(fontPath)
    if not catalogPath then return nil, "invalid" end
    return addon.fontRuntime.usableCatalogPath(catalogPath)
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
    if not FontPathKey(usable) then return nil, nil, "invalid" end
    local requestedStatus
    if requestedFlags then
        requestedStatus = addon.fontRuntime.probeStatus(usable, size, requestedFlags)
        if requestedStatus == "applied" then return usable, requestedFlags, requestedStatus end
    end
    local baseStatus = addon.fontRuntime.probeStatus(usable, size, nil)
    if baseStatus == "applied" then return usable, nil, baseStatus end
    if requestedStatus == "pending" or baseStatus == "pending" then return nil, nil, "pending" end
    return nil, nil, "invalid"
end

function addon.fontRuntime.resolveFlags(fontPath, size, requestedFlags)
    local usable, status = addon.fontRuntime.usablePath(fontPath)
    if not usable then return nil, nil, status end
    return addon.fontRuntime.resolveUsableFlags(usable, size, requestedFlags)
end

function addon.fontRuntime.setRegionFont(region, fontPath, size, flags)
    local status = addon.fontRuntime.trySetFont(region, fontPath, size, flags)
    return status == "applied", status
end

function addon.fontRuntime.applyExact(regions, fontPath, size, requestedFlags)
    local resolvedFont, effectiveFlags, status = addon.fontRuntime.resolveFlags(fontPath, size, requestedFlags)
    if not resolvedFont then return false, nil, nil, status end
    for _, region in ipairs(regions) do
        local applied, regionStatus = addon.fontRuntime.setRegionFont(region, resolvedFont, size, effectiveFlags)
        if not applied then
            return false, nil, nil, regionStatus
        end
    end
    return true, resolvedFont, effectiveFlags, "applied"
end

function addon.fontRuntime.applyOwnedExact(fontObject, regions, fontPath, size, requestedFlags)
    local resolvedFont, effectiveFlags, status =
        addon.fontRuntime.resolveFlags(fontPath, size, requestedFlags)
    if not resolvedFont then return false, nil, nil, status end
    local applied, objectStatus = addon.fontRuntime.setOwnedFont(
        fontObject, regions, resolvedFont, size, effectiveFlags)
    if not applied then return false, nil, nil, objectStatus end
    return true, resolvedFont, effectiveFlags, "applied"
end

function addon.fontRuntime.restore(regions, fontPath, size, flags)
    if not fontPath then return false end
    local restored = true
    for _, region in ipairs(regions) do
        if not addon.fontRuntime.setRegionFont(region, fontPath, size, flags) then
            restored = false
        end
    end
    return restored
end

-- WHY this stays a single lookup: enUS is the canonical source table, with a
-- few intentional display aliases. Before CacheSettings the empty table falls
-- through to the English key; both paths remain O(1).
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
    -- Reuse the Settings secondary-text neutral: brighter than the old gray,
    -- still subordinate to stat colors, with the default outline helping on terrain.
    return string.format("|cffb3bdb8— %s —|r", L(labelKey))
end

function addon.fontRuntime.restoreOwned(fontObject, regions, fontPath, size, flags)
    if not fontPath then return false end
    return addon.fontRuntime.setOwnedFont(fontObject, regions, fontPath, size, flags)
end

-- pcall every stat API so 12.x failures stay nil rather than rendering fake values.
-- Raw secret returns may flow only to the whitelisted display formatter. Clean
-- companion returns remain the sole authority for metadata, comparisons, and caches.
local function safeCall(fn, ...)
    local ok, val = pcall(fn, ...)
    if ok then return val end
    return nil
end

local SAFE_NUM = {
    IsCleanFiniteNumber = addon.IsCleanFiniteNumber,
}

-- PTR stat APIs can return secret-tagged numbers in combat. FontString's C-side
-- formatter is allowed to consume those values with normal printf precision, while
-- Lua's string.format is not. This hidden scratch region is never shown or measured;
-- its secret Text aspect is cleared before and after every use. If any part of that
-- contract is unavailable, FormatDisplayNumber keeps the integer C_StringUtil path.
SAFE_NUM.secretFormatterFrame = CreateFrame("Frame")
SAFE_NUM.secretFormatterFrame:Hide()
SAFE_NUM.secretFormatter = SAFE_NUM.secretFormatterFrame:CreateFontString(
    nil, "OVERLAY", "GameFontNormal")

function SAFE_NUM.IsRenderableNumberValue(value)
    if issecretvalue(value) then return true end
    return SAFE_NUM.IsCleanFiniteNumber(value)
end

function SAFE_NUM.ResolveDisplayNumber(value, requireNonNegative)
    if issecretvalue(value) then return value, nil end
    if not SAFE_NUM.IsCleanFiniteNumber(value)
        or (requireNonNegative and value < 0) then
        return nil, nil
    end
    return value, value
end

-- One formatter for every display-only numeric path. Restricted values go only
-- through Blizzard's C formatter; the returned clean flag is separate so callers
-- never have to compare or branch on the possibly secret result string.
function SAFE_NUM.FormatDisplayNumber(value, cleanFormat, secretSuffix)
    if issecretvalue(value) then
        local formatter = SAFE_NUM.secretFormatter
        if formatter then
            local preClearOK = pcall(formatter.ClearText, formatter)
            local setOK, getOK, text = false, false, nil
            if preClearOK then
                setOK = pcall(formatter.SetFormattedText, formatter, cleanFormat, value)
                if setOK then
                    getOK, text = pcall(formatter.GetText, formatter)
                end
            end
            local postClearOK = pcall(formatter.ClearText, formatter)
            if not preClearOK or not setOK or not getOK or not postClearOK then
                -- A failed holder is never reused this session: a sticky Text secret
                -- aspect would make its later output and dimensions untrustworthy.
                SAFE_NUM.secretFormatter = nil
            elseif getOK then
                -- WARNING: text may itself be secret. Do not inspect, compare, cache,
                -- or reformat it; callers may only concatenate and pass it to SetText.
                return text, true
            end
        end
        if not _G.C_StringUtil
            or type(_G.C_StringUtil.RoundToNearestString) ~= "function" then
            return "?", true
        end
        return _G.C_StringUtil.RoundToNearestString(value)
            .. (secretSuffix or ""), true
    end
    if not SAFE_NUM.IsCleanFiniteNumber(value) then return nil, false end
    return string.format(cleanFormat, value), true
end

function SAFE_NUM.SafeDisplayPercent(fn, ...)
    local value = safeCall(fn, ...)
    return SAFE_NUM.ResolveDisplayNumber(value, false)
end

function addon.movementRuntime.NativePercentFormatterAvailable()
    local runtime = addon.movementRuntime
    if runtime.nativePercentFormatterState ~= nil then
        return runtime.nativePercentFormatterState == true
    end

    runtime.nativePercentFormatterState = false
    local formatter = _G.AbbreviateNumbers
    if type(formatter) ~= "function" then return false end

    -- Validate only clean inputs, so comparing the returned strings cannot branch
    -- on a secret. This fails closed if Blizzard changes breakpoint semantics.
    local baseOK, baseText = pcall(formatter, 7, runtime.nativePercentOptions)
    local boostOK, boostText = pcall(formatter, 10.5, runtime.nativePercentOptions)
    if not baseOK or not boostOK then return false end
    local baseSecretOK, baseSecret = pcall(issecretvalue, baseText)
    local boostSecretOK, boostSecret = pcall(issecretvalue, boostText)
    if not baseSecretOK or baseSecret or not boostSecretOK or boostSecret then return false end
    if type(baseText) ~= "string" or type(boostText) ~= "string" then return false end
    local baseMatches = baseText == "100%" or baseText == "100.0%"
    local boostMatches = boostText == "150%" or boostText == "150.0%"
    runtime.nativePercentFormatterState = baseMatches and boostMatches
    return runtime.nativePercentFormatterState
end

function addon.movementRuntime.FormatRestricted(runSpeed)
    local runtime = addon.movementRuntime
    if runtime.NativePercentFormatterAvailable() then
        local ok, text = pcall(_G.AbbreviateNumbers, runSpeed, runtime.nativePercentOptions)
        if ok then
            -- WARNING: text is secret. Callers may only concatenate it and pass it
            -- through the existing FontString render path; never inspect, compare,
            -- or reformat it.
            return text, true
        end
        runtime.nativePercentFormatterState = false
    end

    -- A future API restriction must degrade to the exact live ground speed, not
    -- a stale percentage. FontString formatting is already the shared secret-safe
    -- fallback used by other live stats.
    return SAFE_NUM.FormatDisplayNumber(runSpeed, "%.1f yd/s", " yd/s")
end

-- GetUnitSpeed returns ground run speed in yards/second rather than a
-- percentage. Clean values can be converted normally. Restricted values are
-- scaled by Blizzard's tainted-safe abbreviation API and remain display-only.
function addon.movementRuntime.ResolvePercent(runSpeed)
    local displaySpeed, cleanSpeed = SAFE_NUM.ResolveDisplayNumber(runSpeed, true)
    if cleanSpeed ~= nil then
        return (cleanSpeed / addon.movementRuntime.baseSpeed)
            * addon.movementRuntime.percentAtBaseSpeed, nil, false, false
    end
    if not issecretvalue(displaySpeed) then return nil, nil, false, false end
    local text, hasText = addon.movementRuntime.FormatRestricted(displaySpeed)
    return nil, text, hasText, true
end

function SAFE_NUM.SafeCompositePercent(fn, ...)
    local ok, value, state = pcall(fn, ...)
    if not ok then return nil, nil, "unavailable" end
    local display, clean = SAFE_NUM.ResolveDisplayNumber(value, false)
    return display, clean, state
end

function SAFE_NUM.ReadRatingValue(fn, ...)
    local value = safeCall(fn, ...)
    return SAFE_NUM.ResolveDisplayNumber(value, true)
end

-- WHY dedicated helper for UnitStat: the API returns FOUR values
--   (stat, effectiveStat, posBuff, negBuff)
-- where `stat` is base (level + items, no temporary buffs) and `effectiveStat`
-- includes raid/food/flask/cooldown buffs. Blizzard's own CharacterFrame
-- displays `effectiveStat`, so users expect the same. `safeCall` only returns
-- the first value (stat), which would silently understate Primary stats for
-- any buffed player. Fall back to base only when effectiveStat is genuinely nil;
-- restricted or malformed values remain unavailable instead of becoming fake 0.
local function GetEffectiveStat(statId)
    local ok, stat, effectiveStat = pcall(UnitStat, "player", statId)
    if not ok then return nil end
    if issecretvalue(effectiveStat) then return effectiveStat end
    if effectiveStat ~= nil then
        if SAFE_NUM.IsCleanFiniteNumber(effectiveStat) then return effectiveStat end
        return nil
    end
    if issecretvalue(stat) then return stat end
    if SAFE_NUM.IsCleanFiniteNumber(stat) then return stat end
    return nil
end

local function IsCleanNonNegativeNumber(value)
    return not issecretvalue(value) and SAFE_NUM.IsCleanFiniteNumber(value) and value >= 0
end

local function RefreshItemLevelCache()
    local runtime = addon.itemLevelRuntime
    runtime.attempt = runtime.attempt + 1
    if not GetAverageItemLevel then
        cached.itemLevelComplete = false
        itemLevelDirty = false
        return
    end
    local ok, overall, equipped = pcall(GetAverageItemLevel)
    if not ok or not IsCleanNonNegativeNumber(overall) or not IsCleanNonNegativeNumber(equipped) then
        cached.itemLevelComplete = false
        if runtime.attempt >= runtime.maxAttempts then itemLevelDirty = false end
        return
    end
    cached.itemLevelOverall = overall
    cached.itemLevelEquipped = equipped
    cached.itemLevelComplete = true
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

-- Unknown is not evidence of non-zero. Keep the row visible when Hide Zero is
-- off; otherwise preserve only a prior clean non-zero decision. Rating
-- visibility is evaluated independently by each caller.
local function shouldShowUnknown(rowKey, isUnknown, hideZero)
    if not isUnknown then return false end
    if not hideZero then return true end
    return rowKey and cached.cleanRowVisibility[rowKey] == true
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
-- current code reads profile settings and account-wide settings only through
-- these accessors. Re-evaluate every attempted mutation so root/version/profile changes
-- invalidate stale modal callbacks before they can write into a different payload.
addon.dbRuntime = {
    readOnly = false,
    mode = "legacy",
    version = 0,
    versionDisplay = "0",
    warned = false,
    warnedMode = nil,
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
    maxGraphDepth = 64,
    maxGraphNodes = 20000,
    accountSettingKeys = {
        forceLocale = true,
        updateInterval = true,
        quickSetupSeen = true,
    },
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
    corruptRollbackRetryCount = 0,
    corruptRollbackRetryToken = nil,
    corruptRollbackRoot = nil,
    contextRetryCount = 0,
    contextRetryToken = nil,
    contextRetryPositionSettings = nil,
    contextRetryPositionSnapshot = nil,
    bootstrapStarted = false,
    bootstrapPending = false,
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
    structuralCommitCount = 0,
    contextReadCount = 0,
}

addon.profileUI = {
    refreshCount = 0,
    selectedGUID = nil,
    selectedSpecID = nil,
}

addon.settingsUI = {
    frame = nil,
    context = nil,
    fontPicker = {
        buttons = {},
        cachedFontsList = nil,
        cachedFontsListLen = -1,
        cachedFontsListHasPending = false,
        initialized = false,
        retryGeneration = 0,
        catalogRefreshScheduled = false,
        lsmCallbackRegistered = false,
        previewedPath = nil,
        hoverGeneration = 0,
    },
    localization = {
        previewActive = false,
        previewSwappedFont = false,
        previewLocale = nil,
    },
}

addon.profileOps = {
    inProgress = false,
    operationCount = 0,
    maxNameCodepoints = 40,
    maxUniqueNameCandidates = 9999,
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

-- Profile strings are deliberately field-driven. They never serialize arbitrary
-- SavedVariables tables and are never evaluated as Lua, so pasted text cannot add
-- unknown keys, aliases, functions, or account-wide settings. Format v1 is a
-- canonical payload wrapped in Base64 plus Adler-32 for accidental-damage detection.
addon.profileTransfer = {
    formatVersion = 1,
    prefix = "SPP1:",
    maxEncodedBytes = 16384,
    maxPayloadBytes = 12000,
    maxFontBytes = 512,
    validationToken = {},
    sectionOrder = { "stats", "layout", "appearance" },
    sectionLabelKeys = {
        stats = "Stat and gear settings",
        layout = "Layout settings",
        appearance = "Appearance settings",
    },
    allowedStrings = {
        targetSnapshot = {
            mythicPlus = true, mythicPlusCurrent = true, mythicPlusHighKeys = true,
            raid = true, raidNormal = true, raidHeroic = true, raidMythic = true,
        },
        displayMode = { flat = true, sectioned = true, split = true },
        labelStyle = { full = true, short = true, hidden = true },
        textOutlineStyle = { none = true, outline = true, thick = true },
    },
    fields = {
        { id="showRating", section="stats", kind="boolean" },
        { id="showPercentage", section="stats", kind="boolean" },
        { id="targetSnapshot", section="stats", kind="enum" },
        { id="showTertiary", section="stats", kind="boolean" },
        { id="hideZeroTertiary", section="stats", kind="boolean" },
        { id="showLeech", section="stats", kind="boolean" },
        { id="showAvoidance", section="stats", kind="boolean" },
        { id="showSpeed", section="stats", kind="boolean" },
        { id="showMainStat", section="stats", kind="boolean" },
        { id="showStamina", section="stats", kind="boolean" },
        { id="showItemLevel", section="stats", kind="boolean" },
        { id="showDefensive", section="stats", kind="boolean" },
        { id="hideZeroDefensive", section="stats", kind="boolean" },
        { id="showDodge", section="stats", kind="boolean" },
        { id="showParry", section="stats", kind="boolean" },
        { id="showBlock", section="stats", kind="boolean" },
        { id="showArmor", section="stats", kind="boolean" },
        { id="showStagger", section="stats", kind="boolean" },
        { id="showOffensive", section="stats", kind="boolean" },
        { id="hideZeroOffensive", section="stats", kind="boolean" },
        { id="showCrit", section="stats", kind="boolean" },
        { id="showHaste", section="stats", kind="boolean" },
        { id="showMastery", section="stats", kind="boolean" },
        { id="showVersatility", section="stats", kind="boolean" },
        { id="showDurability", section="stats", kind="boolean" },
        { id="showRepairCost", section="stats", kind="boolean" },
        { id="useWorstDurability", section="stats", kind="boolean" },

        { id="point", section="layout", kind="anchor" },
        { id="relativePoint", section="layout", kind="anchor" },
        { id="xOfs", section="layout", kind="offset", axis="x" },
        { id="yOfs", section="layout", kind="offset", axis="y" },
        { id="defensive_point", section="layout", kind="anchor" },
        { id="defensive_relativePoint", section="layout", kind="anchor" },
        { id="defensive_xOfs", section="layout", kind="offset", axis="x" },
        { id="defensive_yOfs", section="layout", kind="offset", axis="y" },
        { id="scale", section="layout", kind="number-setting" },
        { id="isVisible", section="layout", kind="boolean" },
        { id="isLocked", section="layout", kind="boolean" },
        { id="displayMode", section="layout", kind="enum" },
        { id="labelStyle", section="layout", kind="enum" },
        { id="splitCharacter", section="layout", kind="boolean" },
        { id="splitItemLevel", section="layout", kind="boolean" },
        { id="splitOffensive", section="layout", kind="boolean" },
        { id="splitTertiary", section="layout", kind="boolean" },
        { id="splitDefensive", section="layout", kind="boolean" },
        { id="splitDurability", section="layout", kind="boolean" },
        { id="splitRepairCost", section="layout", kind="boolean" },

        { id="font", section="appearance", kind="font" },
        { id="fontSize", section="appearance", kind="number-setting" },
        { id="textAlpha", section="appearance", kind="number-setting" },
        { id="panelBackgroundAlpha", section="appearance", kind="number-setting" },
        { id="textOutlineStyle", section="appearance", kind="enum" },
        { id="appearancePresetID", section="appearance", kind="preset" },
        { id="matchValueColorToStat", section="appearance", kind="boolean" },
        { id="useAutoColorDurability", section="appearance", kind="boolean" },
    },
}

do
    local transfer = addon.profileTransfer
    transfer.fieldByID = {}
    transfer.sectionFieldCounts = { stats = 0, layout = 0, appearance = 0 }
    transfer.base64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    transfer.base64Reverse = {}
    for index = 1, #transfer.base64Alphabet do
        transfer.base64Reverse[string.sub(transfer.base64Alphabet, index, index)] = index - 1
    end
    for _, colorName in ipairs({
        "crit", "haste", "mastery", "versatility", "rating", "percentage",
        "leech", "avoidance", "speed", "mainStat", "stamina", "itemLevel",
        "dodge", "parry", "block", "armor", "stagger", "durability",
    }) do
        for _, channel in ipairs({ "r", "g", "b" }) do
            transfer.fields[#transfer.fields + 1] = {
                id = "colors." .. colorName .. "." .. channel,
                section = "appearance",
                kind = "color",
                color = colorName,
                channel = channel,
            }
        end
    end
    for _, field in ipairs(transfer.fields) do
        transfer.fieldByID[field.id] = field
        transfer.sectionFieldCounts[field.section] =
            transfer.sectionFieldCounts[field.section] + 1
    end
end

function addon.profileTransfer.Adler32(value)
    local a, b = 1, 0
    for index = 1, #value do
        a = (a + string.byte(value, index)) % 65521
        b = (b + a) % 65521
    end
    return string.format("%08x", b * 65536 + a)
end

function addon.profileTransfer.Base64Encode(value)
    local alphabet = addon.profileTransfer.base64Alphabet
    local out = {}
    for index = 1, #value, 3 do
        local a = string.byte(value, index)
        local b = string.byte(value, index + 1)
        local c = string.byte(value, index + 2)
        local combined = a * 65536 + (b or 0) * 256 + (c or 0)
        local first = math.floor(combined / 262144) % 64
        local second = math.floor(combined / 4096) % 64
        local third = math.floor(combined / 64) % 64
        local fourth = combined % 64
        out[#out + 1] = string.sub(alphabet, first + 1, first + 1)
        out[#out + 1] = string.sub(alphabet, second + 1, second + 1)
        out[#out + 1] = b and string.sub(alphabet, third + 1, third + 1) or "="
        out[#out + 1] = c and string.sub(alphabet, fourth + 1, fourth + 1) or "="
    end
    return table.concat(out)
end

function addon.profileTransfer.Base64Decode(value)
    if type(value) ~= "string" or #value == 0 or #value % 4 ~= 0
        or #value > addon.profileTransfer.maxEncodedBytes then
        return nil
    end
    local reverse = addon.profileTransfer.base64Reverse
    local out = {}
    for index = 1, #value, 4 do
        local c1, c2 = string.sub(value, index, index), string.sub(value, index + 1, index + 1)
        local c3, c4 = string.sub(value, index + 2, index + 2), string.sub(value, index + 3, index + 3)
        local v1, v2, v3, v4 = reverse[c1], reverse[c2], reverse[c3], reverse[c4]
        local finalBlock = index + 3 == #value
        if v1 == nil or v2 == nil or (c3 ~= "=" and v3 == nil)
            or (c4 ~= "=" and v4 == nil) or (c3 == "=" and c4 ~= "=")
            or ((c3 == "=" or c4 == "=") and not finalBlock) then
            return nil
        end
        -- Reject alternate spellings of the same bytes. Unused Base64 pad bits
        -- must be zero so every v1 payload has one canonical wire form.
        if (c3 == "=" and v2 % 16 ~= 0)
            or (c4 == "=" and c3 ~= "=" and v3 % 4 ~= 0) then
            return nil
        end
        local combined = v1 * 262144 + v2 * 4096 + (v3 or 0) * 64 + (v4 or 0)
        out[#out + 1] = string.char(math.floor(combined / 65536) % 256)
        if c3 ~= "=" then out[#out + 1] = string.char(math.floor(combined / 256) % 256) end
        if c4 ~= "=" then out[#out + 1] = string.char(combined % 256) end
        if #out > addon.profileTransfer.maxPayloadBytes then return nil end
    end
    local decoded = table.concat(out)
    if #decoded > addon.profileTransfer.maxPayloadBytes then return nil end
    return decoded
end

function addon.profileTransfer.HexEncode(value)
    return (value:gsub(".", function(byte)
        return string.format("%02X", string.byte(byte))
    end))
end

function addon.profileTransfer.HexDecode(value)
    if type(value) ~= "string" or #value % 2 ~= 0 or value:find("[^0-9A-Fa-f]") then
        return nil
    end
    local out = {}
    for index = 1, #value, 2 do
        out[#out + 1] = string.char(tonumber(string.sub(value, index, index + 1), 16))
    end
    return table.concat(out)
end

function addon.profileTransfer.ReadField(settings, field)
    local value
    if field.kind == "color" then
        local colors = addon.dbRuntime.IsCleanTable(settings) and rawget(settings, "colors") or nil
        local color = addon.dbRuntime.IsCleanTable(colors) and rawget(colors, field.color) or nil
        value = addon.dbRuntime.IsCleanTable(color) and rawget(color, field.channel) or nil
        if not addon.IsCleanFiniteNumber(value) or value < 0 or value > 1 then
            value = defaults.colors[field.color][field.channel]
        end
        return value
    end
    if addon.dbRuntime.IsCleanTable(settings) then
        value = rawget(settings, field.id)
    end
    if field.kind == "boolean" then
        if not addon.dbRuntime.IsCleanType(value, "boolean") then value = defaults[field.id] == true end
    elseif field.kind == "number-setting" then
        value = NormalizeNumberSetting(field.id, value)
    elseif field.kind == "offset" then
        value = NormalizePositionOffset(value, defaults[field.id], field.axis)
    elseif field.kind == "anchor" then
        value = NormalizeAnchorPoint(value, defaults[field.id])
    elseif field.kind == "enum" then
        local allowed = addon.profileTransfer.allowedStrings[field.id]
        if not addon.dbRuntime.IsCleanType(value, "string") or not allowed[value] then
            value = defaults[field.id]
        end
    elseif field.kind == "preset" then
        value = addon.appearancePresets.CurrentID(settings)
    elseif field.kind == "font" then
        if not addon.dbRuntime.IsCleanType(value, "string") or #value > addon.profileTransfer.maxFontBytes
            or value:find("[%z\1-\31\127]") or not FontPathKey(value) then
            value = defaults.font
        end
    end
    return value
end

function addon.profileTransfer.EncodeFieldValue(field, value)
    if field.kind == "boolean" then return value and "1" or "0" end
    if field.kind == "number-setting" or field.kind == "offset" or field.kind == "color" then
        return string.format("%.17g", value)
    end
    if field.kind == "font" then return addon.profileTransfer.HexEncode(value) end
    return value
end

function addon.profileTransfer.DecodeFieldValue(field, encoded)
    if field.kind == "boolean" then
        if encoded == "1" then return true, true end
        if encoded == "0" then return false, true end
        return nil, false
    end
    if field.kind == "number-setting" or field.kind == "offset" or field.kind == "color" then
        local value = tonumber(encoded)
        if not addon.IsCleanFiniteNumber(value) then return nil, false end
        if field.kind == "number-setting" then
            local normalized = NormalizeNumberSetting(field.id, value)
            if math.abs(normalized - value) > 0.0000001 then return nil, false end
            return normalized, true
        end
        if field.kind == "offset" then
            if math.abs(value) > 100000 then return nil, false end
            return NormalizePositionOffset(value, defaults[field.id], field.axis), true
        end
        if value < 0 or value > 1 then return nil, false end
        return value, true
    end
    if field.kind == "font" then
        local value = addon.profileTransfer.HexDecode(encoded)
        if not value or #value == 0 or #value > addon.profileTransfer.maxFontBytes
            or value:find("[%z\1-\31\127]") or not FontPathKey(value) then
            return nil, false
        end
        return value, true
    end
    if field.kind == "anchor" then
        return encoded, VALID_ANCHOR_POINTS[encoded] == true
    end
    if field.kind == "enum" then
        local allowed = addon.profileTransfer.allowedStrings[field.id]
        return encoded, allowed and allowed[encoded] == true
    end
    if field.kind == "preset" then
        if encoded == "custom" then return encoded, true end
        for _, presetID in ipairs(addon.appearancePresets.order) do
            if encoded == presetID then return encoded, true end
        end
        -- The concrete appearance fields remain authoritative when a newer preset
        -- name reaches an older v1 reader.
        if encoded:match("^[a-z0-9%-]+$") and #encoded <= 32 then return "custom", true end
    end
    return nil, false
end

function addon.profileTransfer.NormalizeSections(sections, available)
    local normalized, count = {}, 0
    if type(sections) ~= "table" then return nil end
    for _, section in ipairs(addon.profileTransfer.sectionOrder) do
        if sections[section] == true then
            if available and available[section] ~= true then return nil end
            normalized[section] = true
            count = count + 1
        end
    end
    if count == 0 then return nil end
    for section, selected in pairs(sections) do
        if selected and not addon.profileTransfer.sectionLabelKeys[section] then return nil end
    end
    return normalized
end

function addon.profileTransfer.Serialize(profileName, settings, sections)
    local normalizedName = addon.profileOps.NormalizeNameShape(
        profileName, addon.profileOps.maxNameCodepoints, false)
    local selected = addon.profileTransfer.NormalizeSections(sections)
    if not normalizedName or not selected or not addon.dbRuntime.IsCleanTable(settings) then
        return nil, "invalid"
    end
    local sectionNames = {}
    for _, section in ipairs(addon.profileTransfer.sectionOrder) do
        if selected[section] then sectionNames[#sectionNames + 1] = section end
    end
    local lines = {
        "name=" .. addon.profileTransfer.HexEncode(normalizedName),
        "sections=" .. table.concat(sectionNames, ","),
    }
    for _, field in ipairs(addon.profileTransfer.fields) do
        if selected[field.section] then
            local value = addon.profileTransfer.ReadField(settings, field)
            local encoded = addon.profileTransfer.EncodeFieldValue(field, value)
            if type(encoded) ~= "string" or encoded:find("[\r\n]") then return nil, "invalid" end
            lines[#lines + 1] = field.id .. "=" .. encoded
        end
    end
    local payload = table.concat(lines, "\n")
    if #payload > addon.profileTransfer.maxPayloadBytes then return nil, "too-large" end
    local encoded = addon.profileTransfer.Base64Encode(payload)
    local result = addon.profileTransfer.prefix
        .. addon.profileTransfer.Adler32(payload) .. ":" .. encoded
    if #result > addon.profileTransfer.maxEncodedBytes then return nil, "too-large" end
    return result
end

function addon.profileTransfer.Parse(value)
    if not addon.dbRuntime.IsCleanType(value, "string") then return nil, "invalid", "type" end
    if #value == 0 or #value > addon.profileTransfer.maxEncodedBytes then
        return nil, "invalid", "size"
    end
    value = value:match("^%s*(.-)%s*$")
    if value == "" then return nil, "invalid", "size" end
    local version = value:match("^SPP(%d+):")
    if version then
        local numericVersion = tonumber(version)
        if numericVersion and numericVersion > addon.profileTransfer.formatVersion then
            return nil, "future-format"
        end
        if numericVersion ~= addon.profileTransfer.formatVersion then
            return nil, "invalid", "version"
        end
    end
    local checksum, encoded = value:match("^SPP1:([0-9A-Fa-f]+):([A-Za-z0-9+/=]+)$")
    if not checksum or #checksum ~= 8 then return nil, "invalid", "envelope" end
    local payload = addon.profileTransfer.Base64Decode(encoded)
    if not payload or addon.profileTransfer.Adler32(payload) ~= string.lower(checksum)
        or payload:find("[\r%z]") then
        return nil, "invalid", "checksum"
    end
    local lines = {}
    for line in (payload .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    if #lines < 3 or #lines > #addon.profileTransfer.fields + 2 then
        return nil, "invalid", "line-count"
    end
    local nameHex = lines[1]:match("^name=([0-9A-Fa-f]+)$")
    local sectionText = lines[2]:match("^sections=([a-z,]+)$")
    local profileName = nameHex and addon.profileTransfer.HexDecode(nameHex) or nil
    profileName = profileName and addon.profileOps.NormalizeNameShape(
        profileName, addon.profileOps.maxNameCodepoints, false) or nil
    if not profileName or not sectionText then return nil, "invalid", "header" end

    local sections, canonicalSections = {}, {}
    for section in sectionText:gmatch("[^,]+") do
        if not addon.profileTransfer.sectionLabelKeys[section] or sections[section] then
            return nil, "invalid", "section"
        end
        sections[section] = true
    end
    for _, section in ipairs(addon.profileTransfer.sectionOrder) do
        if sections[section] then canonicalSections[#canonicalSections + 1] = section end
    end
    if table.concat(canonicalSections, ",") ~= sectionText
        or not addon.profileTransfer.NormalizeSections(sections) then
        return nil, "invalid", "section-order"
    end

    local package = {
        formatVersion = addon.profileTransfer.formatVersion,
        profileName = profileName,
        sections = sections,
        values = {},
        originalString = value,
        validationToken = addon.profileTransfer.validationToken,
    }
    local seen, fieldCount = {}, 0
    for index = 3, #lines do
        local fieldID, encodedValue = lines[index]:match("^([%w_%.]+)=(.*)$")
        local field = fieldID and addon.profileTransfer.fieldByID[fieldID] or nil
        if not field or seen[fieldID] or not sections[field.section] then
            return nil, "invalid", "field:" .. tostring(fieldID)
        end
        local decoded, valid = addon.profileTransfer.DecodeFieldValue(field, encodedValue)
        if not valid then return nil, "invalid", "value:" .. tostring(fieldID) end
        package.values[fieldID] = decoded
        seen[fieldID] = true
        fieldCount = fieldCount + 1
    end
    local expectedCount = 0
    for _, section in ipairs(addon.profileTransfer.sectionOrder) do
        if sections[section] then
            expectedCount = expectedCount + addon.profileTransfer.sectionFieldCounts[section]
        end
    end
    if fieldCount ~= expectedCount then return nil, "invalid", "field-count" end
    for _, field in ipairs(addon.profileTransfer.fields) do
        if sections[field.section] and not seen[field.id] then
            return nil, "invalid", "missing:" .. field.id
        end
    end
    return package
end

function addon.profileTransfer.BuildImportedSettings(targetSettings, package, sections, cloneBudget)
    if type(package) ~= "table"
        or not rawequal(package.validationToken, addon.profileTransfer.validationToken)
        or package.formatVersion ~= addon.profileTransfer.formatVersion
        or type(package.values) ~= "table"
        or not addon.dbRuntime.IsCleanTable(package.values) then
        return nil, "invalid"
    end
    local selected = addon.profileTransfer.NormalizeSections(sections, package.sections)
    if not selected then return nil, "invalid-sections" end
    local settings, copied = addon.dbRuntime.CloneSerializable(
        targetSettings, nil, cloneBudget)
    if not copied or not addon.dbRuntime.IsCleanTable(settings) then return nil, "clone-failed" end
    for _, field in ipairs(addon.profileTransfer.fields) do
        if selected[field.section] then
            local fieldID = field.id
            if type(fieldID) ~= "string" then return nil, "invalid" end
            local value = rawget(package.values, fieldID)
            if value == nil then return nil, "invalid" end
            if field.kind == "color" then
                local colorName, channel = field.color, field.channel
                if type(colorName) ~= "string" or type(channel) ~= "string" then
                    return nil, "invalid"
                end
                local colors = rawget(settings, "colors")
                if type(colors) ~= "table" or not addon.dbRuntime.IsCleanTable(colors) then
                    colors = {}
                    settings.colors = colors
                end
                local color = rawget(colors, colorName)
                if type(color) ~= "table" or not addon.dbRuntime.IsCleanTable(color) then
                    color = {}
                    colors[colorName] = color
                end
                color[channel] = value
            else
                settings[fieldID] = value
            end
        end
    end
    if not addon.dbRuntime.StripAccountSettings(settings) then
        return nil, "clone-failed"
    end
    return settings, selected
end

function addon.profileUI.RefreshSafe()
    if addon.hudPresets
        and type(addon.hudPresets.FlushPendingWelcomeSeen) == "function" then
        pcall(addon.hudPresets.FlushPendingWelcomeSeen)
    end
    local refresh = addon.profileUI.refreshAll
    if type(refresh) == "function" then pcall(refresh) end
    local design = addon.settingsDesign
    if design and type(design.RefreshMutationControls) == "function" then
        pcall(design.RefreshMutationControls)
    end
    if addon.appearancePresets and type(addon.appearancePresets.RefreshUI) == "function" then
        pcall(addon.appearancePresets.RefreshUI)
    end
    if addon.hudPresets and type(addon.hudPresets.RefreshUI) == "function" then
        pcall(addon.hudPresets.RefreshUI)
    end
end

function addon.profileOps.CountAllReferences(root)
    local countsByProfile = {}
    local function newCounts()
        return {
            specs = 0,
            characterDefaults = 0,
            accountDefault = 0,
            roleTemplates = 0,
            total = 0,
        }
    end
    local function add(profileID, field)
        if type(profileID) ~= "string" then return end
        local counts = countsByProfile[profileID]
        if not counts then
            counts = newCounts()
            countsByProfile[profileID] = counts
        end
        counts[field] = counts[field] + 1
        counts.total = counts.total + 1
    end

    for profileID in pairs(root.profiles or {}) do
        countsByProfile[profileID] = newCounts()
    end
    add(root.account and root.account.defaultProfileID, "accountDefault")
    for _, profileID in pairs(root.roleTemplates or {}) do
        add(profileID, "roleTemplates")
    end
    for _, character in pairs(root.characters or {}) do
        add(character.defaultProfileID, "characterDefaults")
        for _, profileID in pairs(character.specProfiles or {}) do
            add(profileID, "specs")
        end
    end
    return countsByProfile
end

function addon.profileUI.BuildViewModel()
    local root = addon.dbRuntime.Refresh()
    local runtime = addon.profileRuntime
    local pending = runtime.pendingResolution or runtime.scheduledToken ~= nil
        or runtime.noSpecRetryToken ~= nil or runtime.contextRetryToken ~= nil
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
        unusedProfileCount = 0,
        roleTemplates = {},
        characters = {},
        profiles = {},
    }
    if runtime.bootstrapPending then model.activeProfileID = nil end
    local registryReadable = addon.dbRuntime.registryReady
    if not registryReadable and model.mode == "future" then
        -- Future roots remain globally unactivated and immutable. A root that still
        -- satisfies the complete current registry contract can nevertheless be
        -- projected read-only so its known profile fields can be exported.
        registryReadable = addon.dbRuntime.ValidateRegistry(root) == true
    end
    if not registryReadable then return model end

    model.canMutate = not model.readOnly and combat == false and not pending
        and not runtime.transitioning and not addon.profileOps.inProgress
    local referenceCounts = addon.profileOps.CountAllReferences(root)
    for _, role in ipairs(addon.profileOps.roleOrder) do
        local profileID = root.roleTemplates[role]
        model.roleTemplates[role] = {
            profileID = profileID,
        }
    end

    for guid, character in pairs(root.characters) do
        local characterModel = {
            guid = guid,
            displayName = character.displayName or L("Character"),
            lastSeen = character.lastSeen or 0,
            isCurrent = guid == model.activeGUID,
            specs = {},
        }
        for specID, profileID in pairs(character.specProfiles or {}) do
            characterModel.specs[#characterModel.specs + 1] = {
                specID = specID,
                specName = runtime.knownSpecNames[specID],
                profileID = profileID,
                sharedCount = referenceCounts[profileID]
                    and referenceCounts[profileID].specs or 0,
                isActive = guid == model.activeGUID and specID == model.activeSpecID
                    and profileID == model.activeProfileID,
            }
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
    for profileID in pairs(root.profiles) do
        local references = referenceCounts[profileID]
        model.profiles[profileID] = { profileID = profileID, references = references }
        if references.total == 0 then
            model.unusedProfileCount = model.unusedProfileCount + 1
        end
    end
    return model
end

function addon.profileRuntime.BlocksUserWrites()
    return not addon.profileRuntime.transitioning
        and (addon.profileRuntime.pendingResolution
            or addon.profileRuntime.scheduledToken ~= nil
            or addon.profileRuntime.contextRetryToken ~= nil)
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

function addon.dbRuntime.StripAccountSettings(settings)
    if not addon.dbRuntime.IsCleanTable(settings) then return false end
    for key in pairs(addon.dbRuntime.accountSettingKeys) do settings[key] = nil end
    return true
end

function addon.dbRuntime.ContainsAccountSettings(settings)
    if not addon.dbRuntime.IsCleanTable(settings) then return false end
    for key in pairs(addon.dbRuntime.accountSettingKeys) do
        if rawget(settings, key) ~= nil then return true end
    end
    return false
end

-- One budget spans all sibling traversals in a logical phase. Charging both table
-- entries and visited values bounds wide scalar maps as well as recursive graphs.
function addon.dbRuntime.NewGraphBudget()
    return { nodes = 0, failure = nil }
end

function addon.dbRuntime.FailGraphBudget(budget, reason)
    if budget and not budget.failure then budget.failure = reason end
    return false
end

function addon.dbRuntime.ConsumeGraphBudget(budget, depth)
    if not budget or depth > addon.dbRuntime.maxGraphDepth
        or budget.nodes >= addon.dbRuntime.maxGraphNodes then
        return addon.dbRuntime.FailGraphBudget(budget, "budget")
    end
    budget.nodes = budget.nodes + 1
    return true
end

function addon.dbRuntime.IsInspectableGraphTable(value, budget)
    if type(value) ~= "table" then return false end
    local secretOK, secret = pcall(issecretvalue, value)
    if not secretOK then
        return addon.dbRuntime.FailGraphBudget(budget, "inspection")
    end
    if secret then return false end
    if type(_G.issecrettable) == "function" then
        local tableOK, secretTable = pcall(_G.issecrettable, value)
        if not tableOK then
            return addon.dbRuntime.FailGraphBudget(budget, "inspection")
        end
        if secretTable then return false end
    end
    local nextOK = pcall(next, value, nil)
    if not nextOK then
        return addon.dbRuntime.FailGraphBudget(budget, "iterator")
    end
    return true
end

-- Serializable clone with per-operation depth/work limits and ancestry-only cycle
-- detection. Repeated source tables are copied independently, so profile payloads
-- cannot retain aliases from hand-edited or legacy SavedVariables.
function addon.dbRuntime.CloneSerializable(value, ancestors, budget, depth)
    budget = budget or addon.dbRuntime.NewGraphBudget()
    depth = depth or 0
    if not addon.dbRuntime.ConsumeGraphBudget(budget, depth) then return nil, false end
    local secretOK, secret = pcall(issecretvalue, value)
    if not secretOK then
        addon.dbRuntime.FailGraphBudget(budget, "inspection")
        return nil, false
    end
    if secret then return nil, false end
    local valueType = type(value)
    if valueType == "nil" or valueType == "boolean"
        or valueType == "number" or valueType == "string" then
        return value, true
    end
    if valueType ~= "table"
        or not addon.dbRuntime.IsInspectableGraphTable(value, budget) then return nil, false end
    ancestors = ancestors or {}
    if ancestors[value] then return nil, false end
    ancestors[value] = true
    local copy = {}
    local key = nil
    while true do
        local nextOK, nextKey, nextValue = pcall(next, value, key)
        if not nextOK then
            ancestors[value] = nil
            addon.dbRuntime.FailGraphBudget(budget, "iterator")
            return nil, false
        end
        if type(nextKey) == "nil" then break end
        if not addon.dbRuntime.ConsumeGraphBudget(budget, depth + 1) then
            ancestors[value] = nil
            return nil, false
        end
        local keyType = type(nextKey)
        local cleanKey = addon.dbRuntime.IsCleanType(nextKey, keyType)
        if not cleanKey or (keyType ~= "string" and keyType ~= "number") then
            ancestors[value] = nil
            return nil, false
        end
        local clonedValue, cloned = addon.dbRuntime.CloneSerializable(
            nextValue, ancestors, budget, depth + 1)
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
function addon.dbRuntime.CollectTableReferences(
    value, seen, ancestors, rejectAliases, forbidden, budget, depth)
    budget = budget or addon.dbRuntime.NewGraphBudget()
    depth = depth or 0
    if not addon.dbRuntime.ConsumeGraphBudget(budget, depth) then return false end
    local secretOK, secret = pcall(issecretvalue, value)
    if not secretOK then
        return addon.dbRuntime.FailGraphBudget(budget, "inspection")
    end
    if secret then return false end
    local valueType = type(value)
    if valueType == "nil" or valueType == "boolean"
        or valueType == "number" or valueType == "string" then
        return true
    end
    if valueType ~= "table"
        or not addon.dbRuntime.IsInspectableGraphTable(value, budget) then return false end
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
            return addon.dbRuntime.FailGraphBudget(budget, "iterator")
        end
        if type(nextKey) == "nil" then break end
        if not addon.dbRuntime.ConsumeGraphBudget(budget, depth + 1) then
            ancestors[value] = nil
            return false
        end
        local keyType = type(nextKey)
        if (keyType ~= "string" and keyType ~= "number")
            or not addon.dbRuntime.IsCleanType(nextKey, keyType)
            or not addon.dbRuntime.CollectTableReferences(
                nextValue, seen, ancestors, rejectAliases, forbidden, budget, depth + 1) then
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
-- observed safely, but fail closed on bounded-work or iterator failures so a partial
-- scan cannot hide a registry alias.
function addon.dbRuntime.CollectShadowTableReferences(
    value, references, visited, budget, depth)
    budget = budget or addon.dbRuntime.NewGraphBudget()
    depth = depth or 0
    if not addon.dbRuntime.ConsumeGraphBudget(budget, depth) then return false end
    if type(value) ~= "table" then return true end
    references[value] = true
    visited = visited or {}
    if visited[value] then return true end
    visited[value] = true
    local secretOK, secret = pcall(issecretvalue, value)
    if not secretOK then
        return addon.dbRuntime.FailGraphBudget(budget, "inspection")
    end
    if secret then return true end
    if type(_G.issecrettable) == "function" then
        local tableOK, secretTable = pcall(_G.issecrettable, value)
        if not tableOK then
            return addon.dbRuntime.FailGraphBudget(budget, "inspection")
        end
        if secretTable then return true end
    end
    local key = nil
    while true do
        local nextOK, nextKey, nextValue = pcall(next, value, key)
        if not nextOK then
            return addon.dbRuntime.FailGraphBudget(budget, "iterator")
        end
        if type(nextKey) == "nil" then return true end
        if not addon.dbRuntime.CollectShadowTableReferences(
                nextKey, references, visited, budget, depth + 1)
            or not addon.dbRuntime.CollectShadowTableReferences(
                nextValue, references, visited, budget, depth + 1) then
            return false
        end
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
    local budget = addon.dbRuntime.NewGraphBudget()
    if not addon.dbRuntime.ConsumeGraphBudget(budget, 0)
        or not addon.dbRuntime.IsInspectableGraphTable(source, budget) then return nil end
    local copy = {}
    local key = nil
    while true do
        local nextOK, nextKey, nextValue = pcall(next, source, key)
        if not nextOK then
            addon.dbRuntime.FailGraphBudget(budget, "iterator")
            return nil
        end
        if type(nextKey) == "nil" then break end
        if not addon.dbRuntime.ConsumeGraphBudget(budget, 1) then return nil end
        local keyType = type(nextKey)
        if (keyType ~= "string" and keyType ~= "number")
            or not addon.dbRuntime.IsCleanType(nextKey, keyType) then
            return nil
        end
        if keyType == "string" and not addon.dbRuntime.registryRootKeys[nextKey] then
            local clonedValue, cloned = addon.dbRuntime.CloneSerializable(
                nextValue, nil, budget, 1)
            if cloned then
                copy[nextKey] = clonedValue
            elseif budget.failure then
                return nil
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
    local budget = addon.dbRuntime.NewGraphBudget()
    if not addon.dbRuntime.ConsumeGraphBudget(budget, 0)
        or not addon.dbRuntime.IsInspectableGraphTable(root, budget) then return false end
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
        if not nextOK then
            addon.dbRuntime.FailGraphBudget(budget, "iterator")
            return false
        end
        if type(nextKey) == "nil" then break end
        local registryKey = addon.dbRuntime.IsCleanType(nextKey, "string")
            and addon.dbRuntime.registryRootKeys[nextKey]
        if registryKey then
            if not addon.dbRuntime.ConsumeGraphBudget(budget, 1) then return false end
        elseif not addon.dbRuntime.CollectShadowTableReferences(
                nextKey, shadowReferences, shadowVisited, budget, 1)
            or not addon.dbRuntime.CollectShadowTableReferences(
                nextValue, shadowReferences, shadowVisited, budget, 1) then
                return false
        end
        rootKey = nextKey
    end
    local registryReferences = {}
    for _, value in ipairs({ account, profiles, roleTemplates, characters }) do
        if not addon.dbRuntime.CollectTableReferences(
            value, registryReferences, nil, true, shadowReferences, budget, 1) then
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
        or account.updateInterval > NUMBER_SETTING_META.updateInterval.max
        or (type(account.quickSetupSeen) ~= "nil"
            and not addon.dbRuntime.IsCleanType(account.quickSetupSeen, "boolean")) then
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
            or addon.dbRuntime.ContainsAccountSettings(profile.settings) then
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

    -- Future and unreadable schema markers stay in the compatibility state set
    -- above, even if this table previously failed current-schema validation.
    if version <= CURRENT_DB_VERSION
        and rawequal(addon.dbRuntime.migrationFailedRoot, root) then
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
    if not addon.dbRuntime.readOnly then
        addon.dbRuntime.warned = false
        addon.dbRuntime.warnedMode = nil
    end
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
    local mode = addon.dbRuntime.mode
    if showGuidance == true and addon.dbRuntime.warnedMode ~= mode then
        addon.dbRuntime.warned = true
        addon.dbRuntime.warnedMode = mode
        if mode == "corrupt" then
            PrintMsg(L("StatsPro saved data is corrupted and remains read-only. Use /ss wipe outside combat to reset it."))
        else
            PrintMsg(L("Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."))
        end
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

function addon.dbRuntime.BuildRegistry(flat, quickSetupSeen)
    local budget = addon.dbRuntime.NewGraphBudget()
    if not addon.dbRuntime.ConsumeGraphBudget(budget, 0)
        or not addon.dbRuntime.IsInspectableGraphTable(flat, budget) then return nil end
    local settings = {}
    local key = nil
    while true do
        local nextOK, nextKey, value = pcall(next, flat, key)
        if not nextOK then return nil end
        if type(nextKey) == "nil" then break end
        if not addon.dbRuntime.ConsumeGraphBudget(budget, 1) then return nil end
        key = nextKey
        if type(key) == "string"
            and not addon.dbRuntime.registryRootKeys[key]
            and not addon.dbRuntime.accountSettingKeys[key]
            and not addon.dbRuntime.legacySettingKeys[key] then
            local cloned, clonedOK = addon.dbRuntime.CloneSerializable(value, nil, budget, 1)
            if not clonedOK then return nil end
            settings[key] = cloned
        end
    end
    if type(flat.fontBeforeAutoSwitch) ~= "nil" then
        local savedFont, savedOK = addon.dbRuntime.CloneSerializable(
            flat.fontBeforeAutoSwitch, nil, budget, 1)
        if not savedOK then return nil end
        settings.fontBeforeAutoSwitch = savedFont
    end
    local registry = {
        dbVersion = CURRENT_DB_VERSION,
        account = {
            forceLocale = addon.NormalizeForceLocale(flat.forceLocale),
            updateInterval = NormalizeNumberSetting("updateInterval", flat.updateInterval),
            -- Missing means "existing install" for backward compatibility. Only
            -- a truly empty first install passes false and receives onboarding.
            quickSetupSeen = quickSetupSeen ~= false,
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

function addon.profileRuntime.ReadBooleanDecision(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if not ok then return nil end
    local secretOK, secret = pcall(issecretvalue, value)
    if not secretOK or secret or type(value) ~= "boolean" then return nil end
    local compareOK, isTrue = pcall(function() return value == true end)
    if not compareOK then return nil end
    return isTrue
end

function addon.profileRuntime.ReadCombatState()
    return addon.profileRuntime.ReadBooleanDecision(InCombatLockdown)
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

function addon.profileRuntime.SpecProfileName(context, profiles)
    local displayName = addon.dbRuntime.IsCleanType(context.displayName, "string")
        and context.displayName or L("Character")
    local fallbackLabel = string.format(L("Spec %d"), context.specID)
    local label = addon.dbRuntime.IsCleanType(context.specName, "string")
        and context.specName or fallbackLabel
    local maxCodepoints = addon.profileOps.maxNameCodepoints
    local safeLabel, labelCount = addon.profileOps.NormalizeNameShape(
        label, maxCodepoints - 4, true)
    if not safeLabel then
        safeLabel, labelCount = addon.profileOps.NormalizeNameShape(
            fallbackLabel, maxCodepoints - 4, true)
    end
    if not safeLabel then return nil, "invalid-name" end
    local displayLimit = maxCodepoints - labelCount - 3
    local safeDisplay = addon.profileOps.NormalizeNameShape(
        displayName, displayLimit, true)
    if not safeDisplay then
        safeDisplay = addon.profileOps.NormalizeNameShape(
            L("Character"), displayLimit, true)
    end
    if not safeDisplay then return nil, "invalid-name" end
    local fallback = L("Character") .. " - " .. fallbackLabel
    return addon.profileOps.UniqueProfileName(
        safeDisplay .. " - " .. safeLabel, profiles, fallback)
end

function addon.profileRuntime.CloneProfile(sourceProfile, name, budget)
    if not addon.dbRuntime.IsCleanTable(sourceProfile)
        or not addon.dbRuntime.IsCleanTable(sourceProfile.settings) then
        return nil
    end
    local settings, copied = addon.dbRuntime.CloneSerializable(
        sourceProfile.settings, nil, budget)
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
        local cloneBudget = addon.dbRuntime.NewGraphBudget()
        local character, copied = addon.dbRuntime.CloneSerializable(
            currentCharacter, nil, cloneBudget)
        if not copied then return nil, nil end
        if context.displayName then character.displayName = context.displayName end
        if context.classID then character.classID = context.classID end
        if context.lastSeen then character.lastSeen = context.lastSeen end
        local characters = addon.profileRuntime.ShallowCopy(root.characters)
        characters[context.guid] = character
        local transaction = addon.profileOps.NewTransaction(root)
        transaction.characters = characters
        if not addon.dbRuntime.ValidateRegistry(
            addon.profileOps.BuildCandidate(transaction)) then
            return nil, nil
        end
        return transaction, existingProfileID
    end

    local cloneBudget = addon.dbRuntime.NewGraphBudget()
    local account, accountCopied = addon.dbRuntime.CloneSerializable(
        root.account, nil, cloneBudget)
    if not accountCopied or type(account) ~= "table"
        or not addon.dbRuntime.IsCleanTable(account)
        or type(account.defaultProfileID) ~= "string"
        or not addon.dbRuntime.IsCleanType(account.defaultProfileID, "string") then
        return nil, nil
    end
    local profiles = addon.profileRuntime.ShallowCopy(root.profiles)
    local character
    if currentCharacter then
        local characterCopied
        character, characterCopied = addon.dbRuntime.CloneSerializable(
            currentCharacter, nil, cloneBudget)
        if not characterCopied or type(character) ~= "table" then return nil, nil end
    else
        character = { specProfiles = {} }
    end
    if not addon.dbRuntime.IsCleanTable(character) then return nil, nil end
    if type(character.specProfiles) ~= "table" then character.specProfiles = {} end

    local sourceProfileID = context.role and root.roleTemplates[context.role] or nil
    if type(sourceProfileID) ~= "string" then sourceProfileID = account.defaultProfileID end
    local sourceProfile = profiles[sourceProfileID]
    if type(sourceProfile) ~= "table" then return nil, nil end
    local specName = addon.profileRuntime.SpecProfileName(context, profiles)
    if not specName then return nil, nil end
    if context.displayName then character.displayName = context.displayName end
    if context.classID then character.classID = context.classID end
    if context.lastSeen then character.lastSeen = context.lastSeen end
    local transaction, specProfileID = addon.profileOps.BuildAssignedProfileTransaction(
        root, account, profiles, character, character.specProfiles,
        context.guid, context.specID, function()
            return addon.profileRuntime.CloneProfile(
                sourceProfile, specName, cloneBudget), "clone-failed"
        end)
    if not transaction then return nil, nil end
    local valid = addon.dbRuntime.ValidateRegistry(
        addon.profileOps.BuildCandidate(transaction))
    if not valid then return nil, nil end
    return transaction, specProfileID
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

function addon.profileRuntime.ResetContextRetry()
    addon.profileRuntime.contextRetryCount = 0
    addon.profileRuntime.contextRetryToken = nil
end

function addon.profileRuntime.ClearContextRetryPositions()
    addon.profileRuntime.contextRetryPositionSettings = nil
    addon.profileRuntime.contextRetryPositionSnapshot = nil
end

function addon.profileRuntime.RememberContextRetryPositions(settings)
    if not addon.dbRuntime.IsCleanTable(settings) then return false end
    addon.profileRuntime.contextRetryPositionSettings = settings
    addon.profileRuntime.contextRetryPositionSnapshot =
        addon.profileOps.CapturePositionFields(settings)
    return true
end

function addon.profileRuntime.RestoreContextRetryPositionFrames()
    local runtime = addon.profileRuntime
    local settings = runtime.contextRetryPositionSettings
    local snapshot = runtime.contextRetryPositionSnapshot
    if not settings or not snapshot then return true end
    if not rawequal(settings, addon.dbRuntime.activeSettings)
        or type(runtime.restoreActivePositions) ~= "function" then
        return false
    end
    local committed = addon.profileOps.CapturePositionFields(settings)
    addon.profileOps.RestorePositionFields(settings, snapshot)
    local restored = pcall(runtime.restoreActivePositions)
    addon.profileOps.RestorePositionFields(settings, committed)
    return restored
end

function addon.profileRuntime.CommitContextRetryPositions()
    local runtime = addon.profileRuntime
    local settings = runtime.contextRetryPositionSettings
    local snapshot = runtime.contextRetryPositionSnapshot
    if not settings or not snapshot then return true end
    if not rawequal(settings, addon.dbRuntime.activeSettings) then return false end
    addon.profileOps.RestorePositionFields(settings, snapshot)
    runtime.ClearContextRetryPositions()
    return true
end

function addon.profileRuntime.ScheduleContextRetry()
    local runtime = addon.profileRuntime
    runtime.pendingResolution = true
    if runtime.contextRetryToken ~= nil then return true end
    if runtime.contextRetryCount >= 3 then
        addon.profileUI.RefreshSafe()
        return false
    end
    runtime.contextRetryCount = runtime.contextRetryCount + 1
    local retryToken = {}
    local requestGeneration = runtime.requestGeneration
    runtime.contextRetryToken = retryToken
    C_Timer.After(math.min(0.25 * runtime.contextRetryCount, 1), function()
        if runtime.contextRetryToken ~= retryToken then return end
        runtime.contextRetryToken = nil
        if runtime.requestGeneration ~= requestGeneration then return end
        runtime.ResolveCurrent(false)
    end)
    addon.profileUI.RefreshSafe()
    return true
end

function addon.profileRuntime.ClearCorruptRollbackRetry()
    local runtime = addon.profileRuntime
    runtime.corruptRollbackRetryToken = nil
    runtime.corruptRollbackRetryCount = 0
    runtime.corruptRollbackRoot = nil
end

function addon.profileRuntime.ScheduleCorruptRollbackApply(root)
    local runtime = addon.profileRuntime
    if not rawequal(root, addon.dbRuntime.rootRef)
        or addon.dbRuntime.mode ~= "corrupt" then return false end
    runtime.corruptRollbackRoot = root
    if runtime.corruptRollbackRetryToken ~= nil then return true end
    if runtime.corruptRollbackRetryCount >= 3 then return false end

    local token = {}
    runtime.corruptRollbackRetryToken = token
    C_Timer.After(math.min(0.25 * (runtime.corruptRollbackRetryCount + 1), 1), function()
        if runtime.corruptRollbackRetryToken ~= token then return end
        runtime.corruptRollbackRetryToken = nil
        local currentRoot = addon.dbRuntime.Refresh()
        if not rawequal(currentRoot, root) or addon.dbRuntime.mode ~= "corrupt" then
            runtime.corruptRollbackRetryCount = 0
            runtime.corruptRollbackRoot = nil
            addon.profileUI.RefreshSafe()
            return
        end
        if runtime.ReadCombatState() ~= false then
            addon.profileUI.RefreshSafe()
            return
        end

        runtime.corruptRollbackRetryCount = runtime.corruptRollbackRetryCount + 1
        local applied = type(runtime.applyActiveSettings) == "function"
            and pcall(runtime.applyActiveSettings)
        if applied then
            runtime.forceReapply = false
            runtime.ClearCorruptRollbackRetry()
        else
            runtime.ScheduleCorruptRollbackApply(root)
        end
        addon.profileUI.RefreshSafe()
    end)
    return true
end

function addon.profileRuntime.ResumeCorruptRollbackApply()
    local runtime = addon.profileRuntime
    if not runtime.forceReapply then return false end
    return runtime.ScheduleCorruptRollbackApply(runtime.corruptRollbackRoot)
end

function addon.profileRuntime.ActivateResolvedContext(context, transaction, profileID, initializing)
    local runtime = addon.profileRuntime
    local oldProfileID = addon.dbRuntime.activeProfileID
    local oldSettings = addon.dbRuntime.activeSettings
    local oldGUID, oldSpecID = runtime.activeGUID, runtime.activeSpecID
    local oldDisplayName, oldSpecName, oldRole =
        runtime.activeDisplayName, runtime.activeSpecName, runtime.activeRole
    local preBoundaryJournal = addon.profileOps.CaptureMutationJournal(oldSettings)

    runtime.transitioning = true
    runtime.suppressIntermediateRefresh = true
    if not initializing and addon.dbRuntime.IsCleanTable(oldSettings) then
        local saveOK = type(runtime.saveActivePositions) ~= "function"
            or pcall(runtime.saveActivePositions, oldSettings)
        if not saveOK then
            addon.profileOps.RestoreMutationJournal(preBoundaryJournal)
            runtime.suppressIntermediateRefresh = false
            runtime.transitioning = false
            runtime.ScheduleContextRetry()
            addon.profileUI.RefreshSafe()
            return false
        end
        runtime.RememberContextRetryPositions(oldSettings)
        if not runtime.CloseOwnedSettingsModals() then
            addon.profileOps.RestoreMutationJournal(preBoundaryJournal)
            runtime.forceReapply = true
            runtime.forceReapplyRetryCount = 0
            runtime.forceReapplyRetryToken = nil
            runtime.suppressIntermediateRefresh = false
            runtime.transitioning = false
            runtime.ScheduleContextRetry()
            addon.profileUI.RefreshSafe()
            return false
        end

        -- The preflight candidate was built before the outgoing UI boundary was
        -- settled. Rebuild from the now-committed source so a first-seen context
        -- cannot clone a Color Picker preview or stale pre-save panel position.
        local freshTransaction, freshProfileID = runtime.PrepareContextTransaction(context)
        if not addon.dbRuntime.IsCleanType(freshProfileID, "string") then
            runtime.forceReapply = true
            runtime.forceReapplyRetryCount = 0
            runtime.forceReapplyRetryToken = nil
            runtime.pendingResolution = true
            runtime.suppressIntermediateRefresh = false
            runtime.transitioning = false
            runtime.ScheduleContextRetry()
            addon.profileUI.RefreshSafe()
            return false
        end
        transaction, profileID = freshTransaction, freshProfileID
    end
    local oldSettingsJournal = addon.profileOps.CaptureMutationJournal(oldSettings)
    runtime.suppressIntermediateRefresh = false

    runtime.CommitTransaction(transaction)
    local activated = addon.dbRuntime.ActivateProfile(profileID)
    local targetSettings = activated and addon.dbRuntime.activeSettings or nil
    local targetJournal = addon.dbRuntime.IsCleanTable(targetSettings)
        and addon.profileOps.CaptureMutationJournal(targetSettings) or nil
    if not targetJournal then
        runtime.RollbackTransaction(transaction)
        addon.profileOps.RestoreMutationJournal(oldSettingsJournal)
        addon.dbRuntime.ActivateProfile(oldProfileID)
        runtime.activeGUID, runtime.activeSpecID = oldGUID, oldSpecID
        runtime.activeDisplayName, runtime.activeSpecName, runtime.activeRole =
            oldDisplayName, oldSpecName, oldRole
        runtime.forceReapply = true
        runtime.forceReapplyRetryCount = 0
        runtime.forceReapplyRetryToken = nil
        runtime.transitioning = false
        runtime.ScheduleContextRetry()
        addon.profileUI.RefreshSafe()
        return false
    end

    local applied = true
    if not initializing and type(runtime.applyActiveSettings) == "function" then
        applied = pcall(runtime.applyActiveSettings)
    end
    if not applied then
        addon.profileOps.RestoreMutationJournal(targetJournal)
        runtime.RollbackTransaction(transaction)
        addon.profileOps.RestoreMutationJournal(oldSettingsJournal)
        addon.dbRuntime.ActivateProfile(oldProfileID)
        runtime.activeGUID, runtime.activeSpecID = oldGUID, oldSpecID
        runtime.activeDisplayName, runtime.activeSpecName, runtime.activeRole =
            oldDisplayName, oldSpecName, oldRole
        local rollbackJournal = addon.dbRuntime.IsCleanTable(oldSettings)
            and addon.profileOps.CaptureMutationJournal(oldSettings) or nil
        local rollbackApplied = false
        if type(runtime.applyActiveSettings) == "function" then
            rollbackApplied = pcall(runtime.applyActiveSettings)
        end
        if not rollbackApplied then
            addon.profileOps.RestoreMutationJournal(rollbackJournal)
            runtime.forceReapply = true
            runtime.forceReapplyRetryCount = 0
            runtime.forceReapplyRetryToken = nil
        end
        runtime.transitioning = false
        runtime.ScheduleContextRetry()
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
    runtime.ResetContextRetry()
    runtime.ClearContextRetryPositions()
    runtime.pendingResolution = false
    runtime.activationCount = runtime.activationCount + 1
    runtime.transitioning = false
    addon.profileUI.RefreshSafe()
    return true
end

function addon.profileRuntime.ResolveCurrent(initializing, combatEnded)
    local runtime = addon.profileRuntime
    local root = addon.dbRuntime.Refresh()
    if addon.dbRuntime.readOnly or not addon.dbRuntime.registryReady then
        if runtime.bootstrapPending and type(runtime.CompleteBootstrap) == "function" then
            runtime.pendingResolution = false
            addon.profileUI.RefreshSafe()
            return runtime.CompleteBootstrap()
        end
        runtime.pendingResolution = true
        addon.profileUI.RefreshSafe()
        return false
    end
    local combat
    if combatEnded then
        combat = false
    else
        combat = runtime.ReadCombatState()
    end
    initializing = runtime.bootstrapPending or initializing == true
    if combat ~= false then
        runtime.pendingResolution = true
        addon.profileUI.RefreshSafe()
        return false
    end
    local context, contextStatus = runtime.ReadPlayerContext()
    if not context then
        local terminal = false
        if contextStatus == "unavailable" then
            runtime.pendingResolution = false
            terminal = true
        elseif contextStatus == "no-spec" and runtime.settlingNoSpec then
            runtime.pendingResolution = false
            terminal = true
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
            elseif contextStatus == "unknown" then
                runtime.ScheduleContextRetry()
            end
        end
        addon.profileUI.RefreshSafe()
        if terminal and runtime.bootstrapPending
            and type(runtime.CompleteBootstrap) == "function" then
            return runtime.CompleteBootstrap()
        end
        return false
    end
    runtime.noSpecRetryToken = nil

    if runtime.forceReapply then
        runtime.transitioning = true
        local activeSettings = addon.dbRuntime.activeSettings
        local journal = addon.dbRuntime.IsCleanTable(activeSettings)
            and addon.profileOps.CaptureMutationJournal(activeSettings) or nil
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
                local requestGeneration = runtime.requestGeneration
                runtime.forceReapplyRetryToken = retryToken
                C_Timer.After(math.min(0.25 * runtime.forceReapplyRetryCount, 1), function()
                    if runtime.forceReapplyRetryToken ~= retryToken then return end
                    runtime.forceReapplyRetryToken = nil
                    if runtime.requestGeneration ~= requestGeneration then return end
                    runtime.ResolveCurrent(false)
                end)
            end
            addon.profileUI.RefreshSafe()
            return false
        end
        runtime.forceReapply = false
        runtime.forceReapplyRetryCount = 0
        runtime.forceReapplyRetryToken = nil
    end

    if not runtime.RestoreContextRetryPositionFrames() then
        runtime.forceReapply = true
        runtime.forceReapplyRetryCount = 0
        runtime.forceReapplyRetryToken = nil
        runtime.ScheduleContextRetry()
        addon.profileUI.RefreshSafe()
        return false
    end

    local character = root.characters and root.characters[context.guid]
    local mappedProfileID = character and character.specProfiles
        and character.specProfiles[context.specID] or nil
    if runtime.activeGUID == context.guid and runtime.activeSpecID == context.specID
        and addon.dbRuntime.activeProfileID == mappedProfileID then
        -- A same-context event is still allowed to enrich late character/spec metadata.
        -- Do not reapply the profile payload or disturb open settings controls.
        local transaction, profileID = runtime.PrepareContextTransaction(context)
        if profileID ~= mappedProfileID then
            runtime.pendingResolution = true
            addon.profileUI.RefreshSafe()
            return false
        end
        if not runtime.CommitContextRetryPositions() then
            runtime.pendingResolution = true
            runtime.ScheduleContextRetry()
            addon.profileUI.RefreshSafe()
            return false
        end
        if transaction and type(runtime.CancelOwnedMutationPopups) == "function" then
            runtime.CancelOwnedMutationPopups()
        end
        runtime.CommitTransaction(transaction)
        local updatedCharacter = transaction and transaction.characters[context.guid] or character
        runtime.activeDisplayName = context.displayName
            or (updatedCharacter and updatedCharacter.displayName)
            or runtime.activeDisplayName
        runtime.activeSpecName = context.specName or runtime.activeSpecName
        runtime.activeRole = context.role or runtime.activeRole
        if context.specName then runtime.knownSpecNames[context.specID] = context.specName end
        runtime.ResetContextRetry()
        runtime.pendingResolution = false
        addon.profileUI.RefreshSafe()
        if addon.fontRuntime.pendingSavedFont
            and not addon.fontRuntime.pendingRetryScheduled
            and type(addon.fontRuntime.schedulePendingSavedFontRetry) == "function" then
            addon.fontRuntime.schedulePendingSavedFontRetry()
        end
        if runtime.bootstrapPending and type(runtime.CompleteBootstrap) == "function" then
            return runtime.CompleteBootstrap()
        end
        return true
    end

    local transaction, profileID = runtime.PrepareContextTransaction(context)
    if not addon.dbRuntime.IsCleanType(profileID, "string") then
        runtime.pendingResolution = true
        addon.profileUI.RefreshSafe()
        return false
    end
    local activated = runtime.ActivateResolvedContext(context, transaction, profileID, initializing)
    if activated and runtime.bootstrapPending
        and type(runtime.CompleteBootstrap) == "function" then
        return runtime.CompleteBootstrap()
    end
    return activated
end

function addon.profileRuntime.RequestResolution(immediate)
    local runtime = addon.profileRuntime
    runtime.ResetContextRetry()
    runtime.forceReapplyRetryToken = nil
    if type(UnitGUID) ~= "function" then
        runtime.pendingResolution = false
        addon.profileUI.RefreshSafe()
        if runtime.bootstrapPending and type(runtime.CompleteBootstrap) == "function" then
            return runtime.CompleteBootstrap()
        end
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

function addon.profileRuntime.ResolvePending(combatEnded)
    local runtime = addon.profileRuntime
    if not runtime.pendingResolution and runtime.scheduledToken == nil
        and runtime.contextRetryToken == nil then return false end
    runtime.ResetContextRetry()
    runtime.forceReapplyRetryToken = nil
    runtime.requestGeneration = runtime.requestGeneration + 1
    runtime.scheduledToken = nil
    runtime.noSpecRetryToken = nil
    return runtime.ResolveCurrent(false, combatEnded)
end

function addon.profileOps.ShouldFail(stage)
    if addon.__statsproSmoke ~= true or addon.profileOps.testFailureStage ~= stage then
        return false
    end
    addon.profileOps.testFailureStage = nil
    return true
end

function addon.profileOps.NormalizeNameShape(rawName, maxCodepoints, truncate)
    if not addon.dbRuntime.IsCleanType(rawName, "string") then return nil, "invalid-name" end
    local name = rawName:match("^ *(.-) *$")
    if name == "" then return nil, "invalid-name" end
    if not addon.dbRuntime.IsCleanType(maxCodepoints, "number")
        or maxCodepoints < 1 or maxCodepoints ~= math.floor(maxCodepoints) then
        return nil, "invalid-name"
    end

    local index, byteCount, codepoints, prefixEnd = 1, #name, 0, 0
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
        -- WHY: U+180E is a current Cf shaping control used in Mongolian text,
        -- not a Unicode Separator, so it remains valid inside localized names.
        if (codepoint >= 0x80 and codepoint <= 0x9F) or codepoint == 0xA0
            or codepoint == 0xAD or codepoint == 0x61C or codepoint == 0x1680
            or (codepoint >= 0x2000 and codepoint <= 0x200F)
            or codepoint == 0x2028 or codepoint == 0x2029
            or (codepoint >= 0x202A and codepoint <= 0x202E)
            or codepoint == 0x202F or codepoint == 0x205F
            or (codepoint >= 0x2060 and codepoint <= 0x2069)
            or codepoint == 0x3000 or codepoint == 0xFEFF then
            return nil, "invalid-name"
        end
        index = index + length
        codepoints = codepoints + 1
        if codepoints <= maxCodepoints then prefixEnd = index - 1 end
    end
    if codepoints > maxCodepoints then
        if not truncate then return nil, "name-too-long" end
        name = string.sub(name, 1, prefixEnd):match("^(.-) *$")
        if name == "" then return nil, "invalid-name" end
        codepoints = maxCodepoints
    end
    return name, codepoints
end

function addon.profileOps.BuildDefaultSettings(budget)
    local settings, copied = addon.dbRuntime.CloneSerializable(defaults, nil, budget)
    if not copied or not addon.dbRuntime.StripAccountSettings(settings) then return nil end
    return settings
end

function addon.profileOps.CountReferences(root, profileID)
    return addon.profileOps.CountAllReferences(root)[profileID]
        or {
            specs = 0,
            characterDefaults = 0,
            accountDefault = 0,
            roleTemplates = 0,
            total = 0,
        }
end

function addon.profileOps.ResolveAssignment(root, guid, specID)
    if not addon.dbRuntime.IsCleanType(guid, "string") or guid == "" then return nil end
    local character = root.characters[guid]
    if not addon.dbRuntime.IsCleanTable(character) then return nil end
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

function addon.profileOps.CheckExpected(root, expected, ignoreGeneration)
    if type(expected) ~= "table" then return true end
    if expected.rootRef and not rawequal(root, expected.rootRef) then return false end
    if not ignoreGeneration and expected.generation
        and expected.generation ~= addon.dbRuntime.generation then return false end
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

function addon.profileOps.AcquireOperationRoot(internal)
    local runtime = addon.profileRuntime
    if addon.profileOps.inProgress and not internal then return nil, "busy" end
    if runtime.transitioning then return nil, "busy" end
    local combat = runtime.ReadCombatState()
    if combat == true then return nil, "combat" end
    if combat ~= false then return nil, "unsafe-context" end
    return addon.dbRuntime.Refresh()
end

function addon.profileOps.Gate(expected, internal)
    local runtime = addon.profileRuntime
    local root, gateReason = addon.profileOps.AcquireOperationRoot(internal)
    if not root then return nil, gateReason end
    if addon.dbRuntime.readOnly or not addon.dbRuntime.registryReady then
        return nil, addon.dbRuntime.mode == "corrupt" and "corrupt" or "read-only"
    end
    if runtime.pendingResolution or runtime.scheduledToken ~= nil
        or runtime.noSpecRetryToken ~= nil or runtime.contextRetryToken ~= nil then
        return nil, "pending"
    end
    if not addon.profileOps.CheckExpected(root, expected) then return nil, "stale" end
    return root
end

function addon.profileOps.GateCorruptRecovery(expected, internal)
    local root, gateReason = addon.profileOps.AcquireOperationRoot(internal)
    if not root then return nil, gateReason end
    if addon.dbRuntime.mode ~= "corrupt" or addon.dbRuntime.readOnly ~= true then
        return nil, "stale"
    end
    if type(expected) ~= "table" or not rawequal(root, expected.rootRef)
        or expected.generation ~= addon.dbRuntime.generation then
        return nil, "stale"
    end
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

-- Both transaction coordinators must release lifecycle gates and refresh the
-- profile UI in the same order on every success and failure exit.
function addon.profileOps.FinishOperation(ok, result)
    addon.profileOps.inProgress = false
    addon.profileRuntime.transitioning = false
    addon.profileUI.RefreshSafe()
    return ok, result
end

-- Successful builders return only transaction, result. The coordinator derives the
-- active payload from the candidate mapping and settings identity so a parallel intent
-- cannot silently disagree with the state that will actually be committed.
function addon.profileOps.Execute(expected, builder)
    local root, gateReason = addon.profileOps.Gate(expected, false)
    if not root then return false, gateReason end
    addon.profileOps.inProgress = true
    local finish = addon.profileOps.FinishOperation

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

    local built, transaction, result = pcall(builder, root)
    if not built or not transaction then
        addon.profileOps.RestorePositionFields(oldSettings, positionSnapshot)
        return finish(false, built and result or "prepare-failed")
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
function addon.profileOps.ExecuteRootReplacement(expected, builder, corruptRecovery)
    local gate = corruptRecovery and addon.profileOps.GateCorruptRecovery
        or addon.profileOps.Gate
    local root, gateReason = gate(expected, false)
    if not root then return false, gateReason end
    addon.profileOps.inProgress = true
    local finish = addon.profileOps.FinishOperation

    if not addon.profileRuntime.CloseOwnedSettingsModals() then
        return finish(false, "close-failed")
    end
    root, gateReason = gate(expected, true)
    if not root then return finish(false, gateReason) end

    local oldRoot = root
    local oldProfileID = addon.dbRuntime.activeProfileID
    local oldSettings = addon.dbRuntime.activeSettings
    local positionSnapshot = not corruptRecovery
        and addon.profileOps.CapturePositionFields(oldSettings) or nil
    if not corruptRecovery and type(addon.profileRuntime.saveActivePositions) == "function"
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
        if corruptRecovery then
            if not reapply then return true end
            local rollbackApplied = type(addon.profileRuntime.applyActiveSettings) == "function"
                and pcall(addon.profileRuntime.applyActiveSettings)
            if rollbackApplied then
                addon.profileRuntime.forceReapply = false
                addon.profileRuntime.ClearCorruptRollbackRetry()
                return true
            end
            addon.profileRuntime.forceReapply = true
            addon.profileRuntime.forceReapplyRetryCount = 0
            addon.profileRuntime.pendingResolution = true
            addon.profileRuntime.transitioning = false
            addon.profileRuntime.ScheduleCorruptRollbackApply(oldRoot)
            return false
        end
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
    addon.profileRuntime.ClearCorruptRollbackRetry()
    if corruptRecovery then
        -- The rejected root must remain the corruption marker until the replacement
        -- has validated, published, activated, and applied successfully.
        addon.dbRuntime.migrationFailedRoot = nil
        addon.profileRuntime.ClearContextRetryPositions()
        addon.profileRuntime.RequestResolution(false)
    else
        addon.profileRuntime.pendingResolution = false
    end
    addon.profileOps.operationCount = addon.profileOps.operationCount + 1
    return finish(true, result)
end

function addon.profileOps.UniqueProfileName(baseName, profiles, fallbackName)
    local base, status = addon.profileOps.NormalizeNameShape(
        baseName, addon.profileOps.maxNameCodepoints, true)
    if not base then
        base, status = addon.profileOps.NormalizeNameShape(
            fallbackName or L("Character"), addon.profileOps.maxNameCodepoints, true)
    end
    if not base then
        base, status = addon.profileOps.NormalizeNameShape(
            L("Character"), addon.profileOps.maxNameCodepoints, true)
    end
    if not base then return nil, status end
    local usedNames = {}
    for _, profile in pairs(profiles or {}) do
        if addon.dbRuntime.IsCleanTable(profile)
            and addon.dbRuntime.IsCleanType(profile.name, "string") then
            usedNames[profile.name] = true
        end
    end
    for attempt = 1, addon.profileOps.maxUniqueNameCandidates do
        local suffix = attempt == 1 and "" or " " .. tostring(attempt)
        local prefix = addon.profileOps.NormalizeNameShape(
            base, addon.profileOps.maxNameCodepoints - #suffix, true)
        local candidate = prefix and prefix .. suffix or nil
        local name = candidate and addon.profileOps.NormalizeNameShape(
            candidate, addon.profileOps.maxNameCodepoints, false) or nil
        if name and not usedNames[name] then return name end
    end
    return nil, "name-exhausted"
end

function addon.profileOps.BuildCopiedSettings(source, target, scope, cloneBudget)
    if not addon.dbRuntime.IsCleanTable(source)
        or not addon.dbRuntime.IsCleanTable(target)
        or not addon.dbRuntime.IsCleanTable(source.settings)
        or not addon.dbRuntime.IsCleanTable(target.settings) then
        return nil, "clone-failed"
    end
    scope = scope or "all"
    local settings, copied
    if scope == "all" then
        settings, copied = addon.dbRuntime.CloneSerializable(
            source.settings, nil, cloneBudget)
    else
        local scopeKeys = addon.profileOps.copyScopeKeys[scope]
        if not scopeKeys then return nil, "invalid-scope" end
        settings, copied = addon.dbRuntime.CloneSerializable(
            target.settings, nil, cloneBudget)
        if copied and addon.dbRuntime.IsCleanTable(settings) then
            for key in pairs(scopeKeys) do
                local sourceValue = source.settings[key]
                if sourceValue == nil then
                    settings[key] = nil
                else
                    local copiedValue, valueCopied = addon.dbRuntime.CloneSerializable(
                        sourceValue, nil, cloneBudget)
                    if not valueCopied then return nil, "clone-failed" end
                    settings[key] = copiedValue
                end
            end
            if scope == "stats" then settings.appearancePresetID = "custom" end
        end
    end
    if not copied or not addon.dbRuntime.IsCleanTable(settings) then
        return nil, "clone-failed"
    end
    if not addon.dbRuntime.StripAccountSettings(settings) then
        return nil, "clone-failed"
    end
    return settings
end

function addon.profileOps.CloneContextAssignment(
    root, character, specID, expectedProfileID, cloneBudget)
    local account, accountCopied = addon.dbRuntime.CloneSerializable(
        root.account, nil, cloneBudget)
    local changedCharacter, characterCopied = addon.dbRuntime.CloneSerializable(
        character, nil, cloneBudget)
    if not accountCopied or type(account) ~= "table"
        or not addon.dbRuntime.IsCleanTable(account)
        or not characterCopied or type(changedCharacter) ~= "table"
        or not addon.dbRuntime.IsCleanTable(changedCharacter) then
        return nil
    end
    local changedSpecProfiles = rawget(changedCharacter, "specProfiles")
    if type(changedSpecProfiles) ~= "table"
        or not addon.dbRuntime.IsCleanTable(changedSpecProfiles)
        or changedSpecProfiles[specID] ~= expectedProfileID then
        return nil
    end
    return account, changedCharacter, changedSpecProfiles
end

function addon.profileOps.BuildAssignedProfileTransaction(
    root, account, profiles, changedCharacter, changedSpecProfiles,
    guid, specID, buildProfile)
    local profileID = addon.profileRuntime.AllocateProfileID(account, profiles)
    if not profileID then return nil, "id-exhausted" end
    local profile, profileStatus = buildProfile(profiles)
    if type(profile) ~= "table" or not addon.dbRuntime.IsCleanTable(profile) then
        return nil, profileStatus or "clone-failed"
    end
    profiles[profileID] = profile
    changedSpecProfiles[specID] = profileID
    local characters = addon.profileRuntime.ShallowCopy(root.characters)
    characters[guid] = changedCharacter
    local transaction = addon.profileOps.NewTransaction(root)
    transaction.account = account
    transaction.profiles = profiles
    transaction.characters = characters
    return transaction, profileID, profile
end

function addon.profileOps.CopySettingsToContext(
    sourceProfileID, guid, specID, scope, expected)
    return addon.profileOps.Execute(expected, function(root)
        local character = root.characters[guid]
        local targetProfileID = addon.profileOps.ResolveAssignment(root, guid, specID)
        local source = root.profiles[sourceProfileID]
        local target = targetProfileID and root.profiles[targetProfileID] or nil
        if sourceProfileID == targetProfileID then return nil, "same-profile" end
        if not targetProfileID or not character or not source or not target
            or not addon.dbRuntime.IsCleanType(specID, "number") then
            return nil, "missing-context"
        end
        local cloneBudget = addon.dbRuntime.NewGraphBudget()
        local settings, settingsStatus = addon.profileOps.BuildCopiedSettings(
            source, target, scope, cloneBudget)
        if not settings then return nil, settingsStatus end

        local references = addon.profileOps.CountReferences(root, targetProfileID)
        local profiles = addon.profileRuntime.ShallowCopy(root.profiles)
        if references.total == 1 and references.specs == 1 then
            local changedTarget = addon.profileRuntime.ShallowCopy(target)
            changedTarget.settings = settings
            profiles[targetProfileID] = changedTarget
            local transaction = addon.profileOps.NewTransaction(root)
            transaction.profiles = profiles
            return transaction, { profileID = targetProfileID, created = false }
        end

        local account, changedCharacter, changedSpecProfiles =
            addon.profileOps.CloneContextAssignment(
                root, character, specID, targetProfileID, cloneBudget)
        if not account then return nil, "clone-failed" end
        local context = {
            displayName = character.displayName,
            specID = specID,
            specName = addon.profileRuntime.knownSpecNames[specID],
        }
        local name, nameStatus = addon.profileRuntime.SpecProfileName(context, profiles)
        if not name then return nil, nameStatus or "name-exhausted" end
        local createdTransaction, profileID =
            addon.profileOps.BuildAssignedProfileTransaction(
                root, account, profiles, changedCharacter, changedSpecProfiles,
                guid, specID, function()
                    return { name = name, settings = settings }
                end)
        if not createdTransaction then return nil, profileID end
        return createdTransaction, { profileID = profileID, created = true }
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
        local specProfiles = rawget(changedCharacter, "specProfiles")
        if type(specProfiles) ~= "table" or not addon.dbRuntime.IsCleanTable(specProfiles)
            or not specProfiles[specID] then return nil, "missing-context" end
        specProfiles[specID] = profileID
        local characters = addon.profileRuntime.ShallowCopy(root.characters)
        characters[guid] = changedCharacter
        local transaction = addon.profileOps.NewTransaction(root)
        transaction.characters = characters
        return transaction, profileID
    end)
end

function addon.profileOps.MakeContextIndependent(guid, specID, expected)
    return addon.profileOps.Execute(expected, function(root)
        local character = root.characters[guid]
        local sourceProfileID = addon.profileOps.ResolveAssignment(root, guid, specID)
        local sourceProfile = sourceProfileID and root.profiles[sourceProfileID] or nil
        if not character or not sourceProfile
            or not addon.dbRuntime.IsCleanType(specID, "number") then
            return nil, "missing-context"
        end
        local references = addon.profileOps.CountReferences(root, sourceProfileID)
        if references.total == 1 and references.specs == 1 then return nil, "no-change" end

        local cloneBudget = addon.dbRuntime.NewGraphBudget()
        local account, changedCharacter, changedSpecProfiles =
            addon.profileOps.CloneContextAssignment(
                root, character, specID, sourceProfileID, cloneBudget)
        if not account then return nil, "clone-failed" end
        local profiles = addon.profileRuntime.ShallowCopy(root.profiles)
        local context = {
            displayName = character.displayName,
            specID = specID,
            specName = addon.profileRuntime.knownSpecNames[specID],
        }
        local name, nameStatus = addon.profileRuntime.SpecProfileName(context, profiles)
        if not name then return nil, nameStatus or "name-exhausted" end
        local transaction, profileID = addon.profileOps.BuildAssignedProfileTransaction(
            root, account, profiles, changedCharacter, changedSpecProfiles,
            guid, specID, function()
                return addon.profileRuntime.CloneProfile(
                    sourceProfile, name, cloneBudget), "clone-failed"
            end)
        if not transaction then return nil, profileID end
        return transaction, profileID
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
        return transaction, {
            role = role,
            profileID = profileID,
        }
    end)
end

function addon.profileOps.ResetProfile(profileID, expected)
    return addon.profileOps.Execute(expected, function(root)
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
        return transaction, profileID
    end)
end

function addon.profileOps.DeleteUnusedProfiles(expected)
    return addon.profileOps.Execute(expected, function(root)
        local profiles = addon.profileRuntime.ShallowCopy(root.profiles)
        local referenceCounts = addon.profileOps.CountAllReferences(root)
        local deleted = 0
        for profileID in pairs(root.profiles) do
            local references = referenceCounts[profileID]
            if not references or references.total == 0 then
                profiles[profileID] = nil
                deleted = deleted + 1
            end
        end
        if deleted == 0 then return nil, "no-change" end
        local transaction = addon.profileOps.NewTransaction(root)
        transaction.profiles = profiles
        return transaction, deleted
    end)
end

function addon.profileOps.ReadCleanActiveContext()
    local guid = addon.profileRuntime.activeGUID
    local specID = addon.profileRuntime.activeSpecID
    if type(guid) ~= "string" or not addon.dbRuntime.IsCleanType(guid, "string")
        or guid == "" or type(specID) ~= "number"
        or not addon.dbRuntime.IsCleanType(specID, "number")
        or not IsFiniteNumber(specID) or specID <= 0
        or specID ~= math.floor(specID) then
        return nil
    end
    return guid, specID
end

function addon.profileOps.ImportAndAssign(importedSettings, expected)
    return addon.profileOps.Execute(expected, function(root)
        local guid, specID = addon.profileOps.ReadCleanActiveContext()
        if not guid or not specID then return nil, "missing-context" end
        local character = root.characters[guid]
        local targetProfileID = addon.profileOps.ResolveAssignment(root, guid, specID)
        if not targetProfileID or type(character) ~= "table"
            or not addon.dbRuntime.IsCleanTable(character) then
            return nil, "missing-context"
        end
        local cloneBudget = addon.dbRuntime.NewGraphBudget()
        local account, changedCharacter, specProfiles =
            addon.profileOps.CloneContextAssignment(
                root, character, specID, targetProfileID, cloneBudget)
        local settings, settingsCopied = addon.dbRuntime.CloneSerializable(
            importedSettings, nil, cloneBudget)
        if not account or not changedCharacter or not specProfiles
            or not settingsCopied or type(settings) ~= "table"
            or not addon.dbRuntime.IsCleanTable(settings) then
            return nil, "clone-failed"
        end

        -- Account settings belong to StatsPro as a whole, not to the imported
        -- character/spec profile. Never leak them into profile settings.
        if not addon.dbRuntime.StripAccountSettings(settings) then
            return nil, "clone-failed"
        end
        local profiles = addon.profileRuntime.ShallowCopy(root.profiles)
        local transaction, profileID, profile =
            addon.profileOps.BuildAssignedProfileTransaction(
            root, account, profiles, changedCharacter, specProfiles,
            guid, specID, function(candidateProfiles)
                local name = addon.profileOps.UniqueProfileName(
                    "SwiftStats Import", candidateProfiles)
                if not name then return nil, "duplicate-name" end
                return { name = name, settings = settings }
            end)
        if not transaction then return nil, profileID end
        if type(profile) ~= "table" then return nil, "clone-failed" end
        return transaction, { profileID = profileID, name = profile.name }
    end)
end

function addon.profileOps.ImportTransferToContext(
    package, sections, guid, specID, expected)
    return addon.profileOps.Execute(expected, function(root)
        local character = root.characters[guid]
        local targetProfileID = addon.profileOps.ResolveAssignment(root, guid, specID)
        local target = targetProfileID and root.profiles[targetProfileID] or nil
        if not targetProfileID or not target or not character
            or not addon.dbRuntime.IsCleanType(specID, "number") then
            return nil, "missing-context"
        end
        local cloneBudget = addon.dbRuntime.NewGraphBudget()
        local settings, selected = addon.profileTransfer.BuildImportedSettings(
            target.settings, package, sections, cloneBudget)
        if not settings then return nil, selected end

        local account, changedCharacter, specProfiles =
            addon.profileOps.CloneContextAssignment(
                root, character, specID, targetProfileID, cloneBudget)
        if not account or not changedCharacter or not specProfiles then
            return nil, "clone-failed"
        end

        local profiles = addon.profileRuntime.ShallowCopy(root.profiles)
        local transaction, profileID, profile =
            addon.profileOps.BuildAssignedProfileTransaction(
            root, account, profiles, changedCharacter, specProfiles,
            guid, specID, function(candidateProfiles)
                local name, nameStatus = addon.profileOps.UniqueProfileName(
                    package.profileName, candidateProfiles, L("Imported profile"))
                if not name then return nil, nameStatus end
                return { name = name, settings = settings }
            end)
        if not transaction then return nil, profileID end
        if type(profile) ~= "table" then return nil, "clone-failed" end
        return transaction, {
            profileID = profileID,
            name = profile.name,
            sections = selected,
            previousProfileID = targetProfileID,
        }
    end)
end

function addon.profileOps.FullWipe(expected)
    return addon.profileOps.ExecuteRootReplacement(expected, function()
        local guid, specID = addon.profileOps.ReadCleanActiveContext()
        if not guid or not specID then return nil, "missing-context" end
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

function addon.profileOps.RecoverCorruptRoot(expected)
    return addon.profileOps.ExecuteRootReplacement(expected, function()
        local freshRoot = addon.dbRuntime.BuildRegistry(defaults)
        if type(freshRoot) ~= "table" or not addon.dbRuntime.IsCleanTable(freshRoot) then
            return nil, "clone-failed"
        end
        if not addon.dbRuntime.ValidateRegistry(freshRoot) then
            return nil, "validate-failed"
        end
        return freshRoot, nil, "p1"
    end, true)
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
        return transaction, guid
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
    cached.targetSnapshot = addon.archonTargets.ResolveAvailableSnapshotKey(GetDB("targetSnapshot"))
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
    userColors = addon.presetRuntime.ResolveValue("colors", userColors)
    for name, defaultColor in pairs(defaults.colors) do
        local r, g, b = NormalizeColor(userColors[name], defaultColor)
        cached.colorStrings[name] = RGBToHex(r, g, b)
    end
end

local function MigrateDB(dbOverride)
    local destination = dbOverride or EnsureStatsProDBTable()
    local freshInstall = next(destination) == nil
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

    -- Populate the detached legacy candidate before registry construction. Idempotent:
    -- only missing keys receive defaults, so existing user preferences stay intact.
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
    local registry = addon.dbRuntime.BuildRegistry(db, not freshInstall)
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
    popupKey = "STATSPRO_IMPORT_SWIFTSTATS",
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
        targetSnapshot = {
            mythicPlus = true, mythicPlusCurrent = true, mythicPlusHighKeys = true,
            raid = true, raidNormal = true, raidHeroic = true, raidMythic = true,
        },
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
        or not addon.legacyImport.IsCleanType(xOfs, "number")
        or not addon.positionRuntime.IsValidOffset(xOfs, "x")
        or not addon.legacyImport.IsCleanType(yOfs, "number")
        or not addon.positionRuntime.IsValidOffset(yOfs, "y") then
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

function addon.legacyImport.FinalizeCandidate(candidate)
    -- Synthetic provenance belongs to the imported profile. Feed it through the
    -- flat-to-registry migration, then remove only its generated downgrade shadow.
    candidate.appearancePresetID = "custom"
    if not MigrateDB(candidate) then return false end
    candidate.appearancePresetID = nil
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
    if not addon.legacyImport.FinalizeCandidate(candidate) then return nil, false end
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
    if not addon.legacyImport.FinalizeCandidate(candidate) then return nil, "invalid" end
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
    local durabilityIncomplete = false
    local repairCostPending = false
    local repairCostRetryable = false
    for slot = DURABILITY_SLOT_MIN, DURABILITY_SLOT_MAX do
        if not DURABILITY_SKIP_SLOTS[slot] then
            local cur, max = GetInventoryItemDurability(slot)
            local curSecret = issecretvalue(cur)
            local maxSecret = issecretvalue(max)
            if curSecret or maxSecret then
                durabilityIncomplete = true
                if cached.showRepairCost then repairCostPending = true end
            elseif cur ~= nil or max ~= nil then
                -- Empty and non-durable inventory slots use the same nil/nil shape.
                if SAFE_NUM.IsCleanFiniteNumber(cur) and SAFE_NUM.IsCleanFiniteNumber(max)
                        and max > 0 and cur >= 0 and cur <= max then
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
                elseif not (SAFE_NUM.IsCleanFiniteNumber(cur)
                        and SAFE_NUM.IsCleanFiniteNumber(max) and cur == 0 and max == 0) then
                    -- A clean 0/0 is a non-durable slot. Any other half/malformed pair
                    -- makes the aggregate non-authoritative and may recover on an event.
                    durabilityIncomplete = true
                    if cached.showRepairCost then
                        repairCostPending = true
                        repairCostRetryable = true
                    end
                end
            end
        end
    end
    local durabilityComplete = count > 0 and not durabilityIncomplete
    local durabilityCleanEmpty = count == 0 and not durabilityIncomplete
    local average = durabilityComplete and (sum / count) or nil
    local worst = durabilityComplete and minPct or nil
    return average, worst, durabilityComplete,
        totalCost, repairCostPending, repairCostRetryable, durabilityCleanEmpty
end

-- WARNING: both durability and repairCost can lag after login. Durability APIs may
-- briefly return no complete equipped-slot aggregate, while C_TooltipInfo may return
-- nil or a repairCost that is still nil/secret until item/vendor info catches up.
-- No durability event is guaranteed for plain data-load, so each external dirty
-- generation gets a short bounded backoff. Generation + attempt tokens make older
-- timers harmless after a newer inventory/config event or retry step.

local function RefreshDurabilityCache()
    local avg, mn, durabilityComplete, cost,
        repairCostPending, repairCostRetryable, durabilityCleanEmpty = ScanDurabilityAndCost()
    if durabilityComplete then
        cached.durabilityLastCompleteAverage = avg
        cached.durabilityLastCompleteWorst = mn
        cached.durabilityHasItems = true
    end
    cached.durabilityComplete = durabilityComplete
    cached.durabilityValue = cached.useWorstDurability
        and cached.durabilityLastCompleteWorst
        or cached.durabilityLastCompleteAverage
    cached.repairCostComplete = not repairCostPending
    cached.repairCost = cached.repairCostComplete and cost or nil
    durabilityDirty = false

    -- A cold/incomplete out-of-combat durability read must recover without requiring
    -- a vendor, gear swap, or combat transition. Restricted combat reads keep the
    -- last complete aggregate and rely on PLAYER_REGEN_ENABLED instead of polling.
    local durabilityRetryPending = cached.showDurability
        and not durabilityComplete and not InCombatLockdown()
    local repairRetryPending = repairCostPending and repairCostRetryable
    addon.durabilityRuntime.ScheduleRetry("durability", durabilityRetryPending)
    addon.durabilityRuntime.ScheduleRetry("repair", repairRetryPending)

    -- nil/nil is also Blizzard's transient pre-cache shape, so a single empty scan
    -- cannot erase a good value. Once this generation exhausts its bounded retries,
    -- however, the repeated clean-empty result is authoritative (for example, after
    -- the player removes every durable item) and must not leave stale wear on screen.
    local durabilityRetry = addon.durabilityRuntime.retryStates.durability
    if durabilityCleanEmpty and durabilityRetryPending
            and durabilityRetry.attempt >= #addon.durabilityRuntime.retryDelays
            and durabilityRetry.scheduledGeneration ~= addon.durabilityRuntime.generation then
        cached.durabilityLastCompleteAverage = nil
        cached.durabilityLastCompleteWorst = nil
        cached.durabilityValue = nil
        cached.durabilityHasItems = false
        cached.durabilityComplete = true
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
    labelText:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    labelText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)

    -- ratingText sits between label and value. Anchored to the frame's RIGHT edge with
    -- a NEGATIVE x-offset = -(valueW + gap) so its right edge ends just before the value
    -- column starts. Offset is recomputed each SetTextSafe once valueW is measured.
    -- Initial offset 0; first render repositions it.
    local ratingText = frame:CreateFontString(nil, "OVERLAY")
    ratingText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    ratingText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)

    local valueText = frame:CreateFontString(nil, "OVERLAY")
    valueText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    valueText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)

    -- WHY 4th FontString outside the 3-column system: Repair coin string with embedded
    -- gold/silver/copper icons is much wider than typical percent values. Including it
    -- in any stat column would inflate that column and break row alignment. SetTextSafe
    -- instead measures the complete repair row as a separate auto-fit candidate: the
    -- frame widens only when repair is wider than the stat rows, then shifts the stat
    -- columns left so their natural spacing remains compact.
    -- WARNING: do NOT use a multi-line padded approach (`\n` * N + coin) — inline coin
    -- icons inflate that line's height (`:14:14:2:0|t` yoffset=0 puts texture top above
    -- glyph top), causing cumulative drift vs labelText's pure-text rows.
    local repairText = frame:CreateFontString(nil, "OVERLAY")
    repairText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)  -- y repositioned per render
    repairText:Hide()

    -- Repair row label — dedicated FontString anchored TOPLEFT below labelText (Y set
    -- per-render in SetTextSafe). Architecturally separate from labelText so the repair
    -- row sits on its own visual row below stats (visual separation), and so coin can't
    -- overlap stat-row content. Width set per-render = stats labelW for column alignment.
    local repairLabelText = frame:CreateFontString(nil, "OVERLAY")
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
            panel:StartMouseDrag()
        end)
        overlay:SetScript("OnDragStop", function()
            frame:StopMovingOrSizing()
            panel:SavePosition()
            panel:ScheduleDragGuardRelease()
        end)
        overlay:SetScript("OnMouseUp", function(_, button)
            if button == "RightButton" and not frame.wasDragging and not InCombatLockdown() then
                addon:OpenConfigMenu()
            end
        end)
        overlay:SetScript("OnLeave", function(f)
            -- Another UI surface may take GameTooltip ownership before this overlay's
            -- delayed OnLeave fires. Never hide a tooltip StatsPro no longer owns.
            if type(GameTooltip.GetOwner) ~= "function" or GameTooltip:GetOwner() == f then
                GameTooltip:Hide()
            end
        end)
        overlay.statsProTargetMeta = nil
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
        panel.editDragging = panel:StartMouseDrag()
    end)
    editHandle:SetScript("OnDragStop", function()
        panel:FinishEditDrag()
    end)
    local initialRegions = { labelText, ratingText, valueText, repairText, repairLabelText }
    local fontObject = addon.fontRuntime.getOwnedFontObject("panel:" .. globalName)
    local ownedRegions, directRegions = {}, {}
    local ownedApplied, appliedFont, appliedFlags = true, font, fontFlags
    if fontObject then
        ownedApplied, appliedFont, appliedFlags = addon.fontRuntime.applyOwnedExact(
            fontObject, nil, font, fontSize, fontFlags)
        if ownedApplied then
            for _, region in ipairs(initialRegions) do
                if addon.fontRuntime.attachOwnedFontObject(region, fontObject) then
                    tinsert(ownedRegions, region)
                else
                    tinsert(directRegions, region)
                end
            end
        end
    end
    if not fontObject or not ownedApplied then
        fontObject = nil
        ownedRegions = {}
        directRegions = initialRegions
        ownedApplied = true
    elseif #ownedRegions == 0 then
        fontObject = nil
        directRegions = initialRegions
    end

    local directApplied, directFont, directFlags = true, appliedFont, appliedFlags
    if #directRegions > 0 then
        if fontObject then
            for _, region in ipairs(directRegions) do
                directApplied = addon.fontRuntime.setRegionFont(
                    region, appliedFont, fontSize, appliedFlags)
                if not directApplied then break end
            end
        else
            directApplied, directFont, directFlags = addon.fontRuntime.applyExact(
                directRegions, font, fontSize, fontFlags)
        end
        if directApplied and not fontObject then
            appliedFont, appliedFlags = directFont, directFlags
        end
    end

    -- FontObjects also carry justification and colour. Attach first, then keep the
    -- panel's per-column presentation as explicit region-local overrides.
    labelText:SetJustifyH("RIGHT")
    labelText:SetJustifyV("TOP")
    ratingText:SetJustifyH("RIGHT")
    ratingText:SetJustifyV("TOP")
    valueText:SetJustifyH("LEFT")
    valueText:SetJustifyV("TOP")
    repairText:SetJustifyH("RIGHT")
    repairLabelText:SetJustifyH("RIGHT")
    for _, region in ipairs(initialRegions) do region:SetTextColor(1, 1, 1, 1) end
    if fontObject and not addon.fontRuntime.ownedRegionsMatch(
            ownedRegions, fontObject, appliedFont, fontSize, appliedFlags) then
        for _, region in ipairs(ownedRegions) do tinsert(directRegions, region) end
        ownedRegions = {}
        fontObject = nil
        directApplied, appliedFont, appliedFlags = addon.fontRuntime.applyExact(
            directRegions, font, fontSize, fontFlags)
    end

    local fontApplied = ownedApplied and directApplied
    panel.fontObject = fontObject
    panel.fontObjectRegions = ownedRegions
    panel.directFontRegions = directRegions
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
    frame:SetScript("OnDragStart", function()
        if InCombatLockdown() or cached.isLocked then return end
        panel:StartMouseDrag()
    end)
    frame:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        panel:SavePosition()
        -- 100ms guard absorbs the OnMouseUp that fires immediately after a drag, so
        -- the right-click handler doesn't open Settings on drag-end. Pure clicks
        -- don't pass the drag-distance threshold, never set wasDragging, unaffected.
        panel:ScheduleDragGuardRelease()
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

function Panel:BeginDragGuard()
    self.dragGuardGeneration = (self.dragGuardGeneration or 0) + 1
    self.frame.wasDragging = true
end

function Panel:StartMouseDrag()
    -- WHY: Always start from the mouse so named-frame layout state cannot create
    -- a cursor offset on the first drag of a fresh install.
    self.frame:StartMoving(true)
    self:BeginDragGuard()
    return true
end

function Panel:ScheduleDragGuardRelease()
    local generation = self.dragGuardGeneration or 0
    C_Timer.After(0.1, function()
        if self.dragGuardGeneration == generation then
            self.frame.wasDragging = false
        end
    end)
end

function Panel:FinishEditDrag()
    if not self.editDragging then return end
    self.frame:StopMovingOrSizing()
    self:SavePosition()
    self.editDragging = false
    self:ScheduleDragGuardRelease()
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
    local xOfs             = NormalizePositionOffset(db[xOfsKey], defaults[xOfsKey] or 0, "x")
    local yOfs             = NormalizePositionOffset(db[yOfsKey], defaults[yOfsKey] or 0, "y")

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

function addon.archonTargets.GetRawRatingBonusForValue(ratingCR, rating)
    if type(GetCombatRatingBonusForCombatRatingValue) ~= "function" then return nil end
    if not SAFE_NUM.IsCleanFiniteNumber(ratingCR) or not SAFE_NUM.IsCleanFiniteNumber(rating) or rating < 0 then return nil end
    local okBonus, bonus = pcall(GetCombatRatingBonusForCombatRatingValue, ratingCR, rating)
    if not okBonus then return nil end
    if issecretvalue(bonus) then return nil, "restricted" end
    if not SAFE_NUM.IsCleanFiniteNumber(bonus) then return nil end
    return bonus
end

-- Convert both sides of one comparison against a single Mastery coefficient.
-- GetMasteryEffect can transition to a restricted value between API calls, so
-- independently converting current and target ratings can mix two client states.
function addon.archonTargets.GetRatingBonusesForValues(
        ratingCR, currentRating, targetRating)
    local isMastery = SAFE_NUM.IsCleanFiniteNumber(ratingCR)
        and ratingCR == CR_MASTERY
    local currentBonus, currentReason
    local targetBonus, targetReason
    if currentRating ~= nil then
        currentBonus, currentReason =
            addon.archonTargets.GetRawRatingBonusForValue(ratingCR, currentRating)
    end
    if targetRating ~= nil then
        targetBonus, targetReason =
            addon.archonTargets.GetRawRatingBonusForValue(ratingCR, targetRating)
    end
    if isMastery and (currentBonus ~= nil or targetBonus ~= nil) then
        local coefficient, coefficientReason
        if type(GetMasteryEffect) ~= "function" then
            coefficientReason = "unavailable"
        else
            local ok, _, readCoefficient = pcall(GetMasteryEffect)
            coefficient = readCoefficient
            if not ok or not SAFE_NUM.IsCleanFiniteNumber(coefficient) then
                coefficientReason = issecretvalue(coefficient)
                    and "restricted" or "unavailable"
            end
        end
        if currentBonus ~= nil then
            if coefficientReason then
                currentBonus, currentReason = nil, coefficientReason
            else
                currentBonus = currentBonus * coefficient
                if not SAFE_NUM.IsCleanFiniteNumber(currentBonus) then
                    currentBonus, currentReason = nil, "unavailable"
                end
            end
        end
        if targetBonus ~= nil then
            if coefficientReason then
                targetBonus, targetReason = nil, coefficientReason
            else
                targetBonus = targetBonus * coefficient
                if not SAFE_NUM.IsCleanFiniteNumber(targetBonus) then
                    targetBonus, targetReason = nil, "unavailable"
                end
            end
        end
    end
    return currentBonus, targetBonus, currentReason, targetReason
end

function addon.archonTargets.FormatPercentBonus(value, signed)
    if issecretvalue(value) then
        if signed then return nil end
        local text, renderable = SAFE_NUM.FormatDisplayNumber(value, "%.1f%%", "%")
        if renderable then return text end
        return nil
    end
    if not SAFE_NUM.IsCleanFiniteNumber(value) then return nil end
    if math.abs(value) < 0.05 then value = 0 end
    if signed then
        local sign = value >= 0 and "+" or "-"
        return string.format("%s%.1f%%", sign, math.abs(value))
    end
    return string.format("%.1f%%", value)
end

function addon.archonTargets.FormatRatingWithBonus(rating, bonus, signedBonus)
    local ratingText
    if issecretvalue(rating) then
        ratingText = SAFE_NUM.FormatDisplayNumber(rating, "%.0f", "")
    else
        ratingText = tostring(rating)
    end
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
    local labels = {
        mythicPlusCurrent = "M+ Current",
        mythicPlusHighKeys = "M+ High Keys",
        raidNormal = "Raid Normal All Bosses",
        raidHeroic = "Raid Heroic All Bosses",
        raidMythic = "Raid Mythic All Bosses",
    }
    local key = addon.archonTargets.ResolveAvailableSnapshotKey(snapshotKey)
    local text = L(labels[key] or labels.mythicPlusCurrent)
    local snapshotRoot = addon.archonTargets.GetRootSnapshot(key)
    local detail = type(snapshotRoot) == "table" and snapshotRoot.difficultyLabel or nil
    if type(detail) == "string" and not issecretvalue(detail) and detail ~= "" then
        return text .. " (" .. detail .. ")"
    end
    return text
end

function addon.archonTargets.GetLocalizedSnapshotTitle(snapshotKey)
    local titles = {
        mythicPlusCurrent = "M+ Target",
        mythicPlusHighKeys = "M+ Target",
        raidNormal = "Raid Target",
        raidHeroic = "Raid Target",
        raidMythic = "Raid Target",
    }
    local key = addon.archonTargets.ResolveAvailableSnapshotKey(snapshotKey)
    return L(titles[key] or titles.mythicPlusCurrent)
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
    if type(meta) ~= "table" or not SAFE_NUM.IsCleanFiniteNumber(meta.target) or meta.target < 0 then
        return false
    end
    local comparisonState = meta.comparisonState
    local hasCleanComparison = SAFE_NUM.IsCleanFiniteNumber(meta.current) and meta.current >= 0
        and SAFE_NUM.IsCleanFiniteNumber(meta.delta)
    -- Compatibility for smoke/manual metadata built before comparisonState existed.
    if comparisonState == nil and hasCleanComparison then comparisonState = "exact" end
    local hasComparison = (comparisonState == "exact" or comparisonState == "lastKnown")
        and hasCleanComparison
    local _, liveRatingIsSecret = addon.ClassifyRenderableNumber(meta.currentRatingDisplay)
    local hasLiveCurrent = comparisonState == "liveOnly"
        and liveRatingIsSecret
    local hasCleanCurrentPct = SAFE_NUM.IsCleanFiniteNumber(meta.currentPct)
    local hasCurrentPctDisplay, displayIsSecret =
        addon.ClassifyRenderableNumber(meta.currentPctDisplay)
    local hasTargetPct = SAFE_NUM.IsCleanFiniteNumber(meta.targetPct)
    local currentBonus, targetBonus, deltaBonus
    if hasTargetPct and hasCleanCurrentPct then
        deltaBonus = meta.targetPct - meta.currentPct
    end
    -- Versatility and Mastery include non-rating components that conversion cannot
    -- recover. Without a clean complete currentPct, raw-rating percentages would
    -- be partial values presented as totals.
    if (meta.statKey ~= "versatility" and meta.statKey ~= "mastery")
        or hasCleanCurrentPct then
        currentBonus, targetBonus = addon.archonTargets.GetRatingBonusesForValues(
            meta.ratingCR,
            hasComparison and deltaBonus == nil and meta.current or nil,
            not hasTargetPct and meta.target or nil)
    end
    -- WHY: subtract converted total ratings, not converted `abs(delta)`, so DR brackets
    -- and hard caps are evaluated at the player's current/target stat positions.
    if SAFE_NUM.IsCleanFiniteNumber(currentBonus) and SAFE_NUM.IsCleanFiniteNumber(targetBonus) then
        deltaBonus = targetBonus - currentBonus
    end
    local currentDisplayBonus
    if (comparisonState == "exact" or comparisonState == "liveOnly")
        and hasCurrentPctDisplay then
        currentDisplayBonus = meta.currentPctDisplay
    elseif hasCleanCurrentPct then
        currentDisplayBonus = meta.currentPct
    else
        currentDisplayBonus = currentBonus
    end
    local targetDisplayBonus = hasTargetPct and meta.targetPct or targetBonus
    if meta.statKey == "versatility" then targetDisplayBonus = nil end
    if not hasTargetPct and hasCleanCurrentPct
        and SAFE_NUM.IsCleanFiniteNumber(deltaBonus) then
        targetDisplayBonus = meta.currentPct + deltaBonus
    end
    -- A restricted live percentage is displayable but cannot participate in Lua
    -- arithmetic. Keep Target/Delta as honest rating comparisons instead of pairing
    -- the live Current percent with percentages derived from a different clean state.
    if comparisonState == "exact" and displayIsSecret then
        if not hasTargetPct then targetDisplayBonus = nil end
        deltaBonus = nil
    end
    local valueColor = addon.archonTargets.GetTooltipValueColor(meta)
    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
    -- SetOwner resets lines on current clients, but an owner-preserving refresh must
    -- not depend on that undocumented side effect or accumulate stale state rows.
    if type(GameTooltip.ClearLines) == "function" then GameTooltip:ClearLines() end
    GameTooltip:AddLine("StatsPro " .. addon.archonTargets.GetLocalizedSnapshotTitle(meta.snapshotKey), 1, 0.82, 0)
    if comparisonState == "lastKnown" then
        GameTooltip:AddLine(L("Last known comparison"), 0.7, 0.7, 0.7)
    elseif comparisonState == "liveOnly" then
        GameTooltip:AddLine(L("Live values; comparison unavailable"), 0.7, 0.7, 0.7)
    end
    GameTooltip:AddDoubleLine(L("Target:"), addon.archonTargets.FormatRatingWithBonus(meta.target, targetDisplayBonus, false), 0.7, 0.7, 0.7, 1, 1, 1)
    if hasComparison or hasLiveCurrent then
        local currentRating = hasLiveCurrent and meta.currentRatingDisplay or meta.current
        GameTooltip:AddDoubleLine(L("Current:"), addon.archonTargets.ColorTooltipValue(addon.archonTargets.FormatRatingWithBonus(currentRating, currentDisplayBonus, false), valueColor), 0.7, 0.7, 0.7, 1, 1, 1)
    end
    if hasComparison then
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
    return true
end

function Panel:ApplyTooltipRows(targetRows, lineCount)
    self.lastTargetRows = targetRows
    local rowHeight = self.lastLineH or GetNumberDB("fontSize")
    if not SAFE_NUM.IsCleanFiniteNumber(rowHeight) or rowHeight <= 0 then rowHeight = 1 end
    -- Refresh only the tooltip that is both visible and still owned by one of this
    -- panel's overlays. Hide() may retain GetOwner(), so ownership alone would reopen
    -- a tooltip after the cursor left. Semantic stat identity prevents a row-index
    -- shift (headers, toggles, Split routing) from silently switching Crit to Haste.
    local openOwner
    if GameTooltip:IsShown() and type(GameTooltip.GetOwner) == "function" then
        openOwner = GameTooltip:GetOwner()
    end
    for i = 1, math.max(#(targetRows or {}), #(self.tooltipOverlays or {})) do
        local overlay = self.tooltipOverlays[i]
        if not overlay then
            overlay = self.makeTooltipOverlay()
            self.tooltipOverlays[i] = overlay
        end
        local meta = targetRows and targetRows[i] or nil
        local previousMeta = overlay.statsProTargetMeta
        local ownedOpen = openOwner == overlay
        if type(meta) == "table" and i <= (lineCount or 0) then
            overlay:ClearAllPoints()
            overlay:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -((i - 1) * rowHeight))
            overlay:SetPoint("RIGHT", self.frame, "RIGHT", 0, 0)
            overlay:SetHeight(rowHeight)
            overlay:SetScript("OnEnter", function(f)
                addon.archonTargets.ShowTooltip(f, meta)
            end)
            overlay.statsProTargetMeta = meta
            overlay:Show()
            if ownedOpen then
                local sameStat = type(previousMeta) == "table"
                    and previousMeta.statKey == meta.statKey
                if not sameStat or not addon.archonTargets.ShowTooltip(overlay, meta) then
                    GameTooltip:Hide()
                end
            end
        else
            if ownedOpen then GameTooltip:Hide() end
            overlay:Hide()
            overlay:SetScript("OnEnter", nil)
            overlay.statsProTargetMeta = nil
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

function Panel:RestoreFontState(font, size, flags)
    if not font then return false end
    local restored = true
    if self.fontObject and #self.fontObjectRegions > 0 then
        restored = addon.fontRuntime.restoreOwned(
            self.fontObject, self.fontObjectRegions, font, size, flags) and restored
    end
    if #self.directFontRegions > 0 then
        restored = addon.fontRuntime.restore(
            self.directFontRegions, font, size, flags) and restored
    end
    return restored
end

function Panel:ApplyStyle(font, size, force, requestedOutlineStyle)
    -- WHY idempotency: ApplyStyle is hot — fires from PEW (after MAS may have already
    -- applied), Reset, font/locale preview-cancel, lang commit's conditional restore,
    -- and the Font Size slider's OnValueChanged. Same-args calls still cause shared
    -- object mutation, text restoration, cache invalidation, and a re-measure pass.
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
    local effectiveFont, effectiveFlags, status =
        addon.fontRuntime.resolveFlags(font, size, fontFlags)
    local applied = effectiveFont ~= nil
    if applied and self.fontObject and #self.fontObjectRegions > 0 then
        applied, status = addon.fontRuntime.setOwnedFont(
            self.fontObject, self.fontObjectRegions, effectiveFont, size, effectiveFlags)
    end
    if applied and #self.directFontRegions > 0 then
        for _, region in ipairs(self.directFontRegions) do
            local directApplied, directStatus = addon.fontRuntime.setRegionFont(
                region, effectiveFont, size, effectiveFlags)
            if not directApplied then
                applied = false
                status = directStatus
                break
            end
        end
    end
    if not applied then
        local restored = self:RestoreFontState(oldFont, oldSize, oldFlags)
        if not restored then
            self.appliedFont = nil
            self.appliedSize = nil
            self.appliedTextOutlineStyle = nil
            self.appliedFontFlags = nil
            status = "rollback-failed"
        end
        self:RestoreCachedText()
        return false, nil, nil, nil, status
    end
    self.appliedFont = effectiveFont
    self.appliedSize = size
    self.appliedTextOutlineStyle = outlineStyle
    self.appliedFontFlags = effectiveFlags
    -- Font mutation may clear text on some clients. Re-apply cached payloads without
    -- inspecting them; rating/value strings can remain secret-tagged in combat.
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
-- WHY no defensive re-call from Panel:ApplyStyle: font mutation affects text, not
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

addon.profileRuntime.restoreActivePositions = function()
    mainPanel:LoadPosition()
    defensivePanel:LoadPosition()
end

local function ApplyTextStyleToAllPanels(font, size, force)
    local oldMainFont, oldMainSize, oldMainOutline =
        mainPanel.appliedFont, mainPanel.appliedSize, mainPanel.appliedTextOutlineStyle
    local applied, effectiveFont, effectiveOutline, effectiveFlags, status =
        mainPanel:ApplyStyle(font, size, force)
    if not applied then return false, nil, nil, nil, status end
    local sideApplied, _, _, _, sideStatus =
        defensivePanel:ApplyStyle(effectiveFont, size, force, effectiveOutline)
    if not sideApplied then
        local mainRestored = mainPanel:ApplyStyle(
            oldMainFont, oldMainSize, true, oldMainOutline)
        if not mainRestored then sideStatus = "rollback-failed" end
        return false, nil, nil, nil, sideStatus
    end
    return true, effectiveFont, effectiveOutline, effectiveFlags, "applied"
end

function addon.fontRuntime.applyCommittedTextStyle(font, size, force, allowFontFallback)
    local applied, effectiveFont, effectiveOutline, effectiveFlags, requestedStatus =
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
    if not applied then return false, nil, nil, nil, requestedStatus end

    addon.fontRuntime.committedFont = effectiveFont
    local db = addon.dbRuntime.GetWritableSettings(false)
    -- A cold loose asset can remain inconclusive even after the best-effort
    -- FontObject activation. The runtime fallback is safe, but replacing the saved
    -- preference is not; the bounded retry below commits only after the requested
    -- face is actually observable through GetFont.
    local preservePending = db and requestedStatus == "pending"
        and not SameFontPath(effectiveFont, font)
    if preservePending then
        if not SameFontPath(addon.fontRuntime.pendingSavedFont, font) then
            addon.fontRuntime.pendingSavedFont = addon.fontRuntime.catalogEntry(font) or font
            addon.fontRuntime.pendingRetryAttempt = 0
            addon.fontRuntime.pendingRetryGeneration = addon.fontRuntime.pendingRetryGeneration + 1
            addon.fontRuntime.pendingRetryScheduled = false
        end
        if isLoaded and type(addon.fontRuntime.schedulePendingSavedFontRetry) == "function" then
            addon.fontRuntime.schedulePendingSavedFontRetry()
        end
    elseif db then
        db.font = effectiveFont
        if addon.fontRuntime.pendingSavedFont then
            addon.fontRuntime.pendingSavedFont = nil
            addon.fontRuntime.pendingRetryAttempt = 0
            addon.fontRuntime.pendingRetryGeneration = addon.fontRuntime.pendingRetryGeneration + 1
            addon.fontRuntime.pendingRetryScheduled = false
        end
    end
    local picker = addon.settingsUI.fontPicker
    if type(picker.RefreshCaption) == "function" then picker.RefreshCaption(addon) end
    return true, effectiveFont, effectiveOutline, effectiveFlags, requestedStatus
end

function addon.fontRuntime.currentPath()
    return addon.fontRuntime.committedFont or GetFontDB()
end

function addon.fontRuntime.preferredPath()
    return GetFontDB()
end

function addon.fontRuntime.repairSavedPaths()
    local db = addon.dbRuntime.GetWritableSettings(false)
    if not db then return end

    addon.fontRuntime.pendingSavedFont = nil
    addon.fontRuntime.pendingRetryAttempt = 0
    addon.fontRuntime.pendingRetryGeneration = addon.fontRuntime.pendingRetryGeneration + 1
    addon.fontRuntime.pendingRetryScheduled = false

    local current, currentStatus = addon.fontRuntime.usablePath(db.font)
    if currentStatus == "pending" then
        addon.fontRuntime.pendingSavedFont = addon.fontRuntime.catalogEntry(db.font)
    elseif not current then
        local active = ResolveActiveLocale()
        local req = LOCALE_GLYPH_REQ[active] or GLYPH_LATIN
        current = FindCompatibleFont(addon.fontRuntime.safeDefaultPath(), req)
    end
    if currentStatus ~= "pending" and current then db.font = current end

    if type(db.fontBeforeAutoSwitch) ~= "nil" then
        local saved, savedStatus = addon.fontRuntime.usablePath(db.fontBeforeAutoSwitch)
        if savedStatus ~= "pending" then db.fontBeforeAutoSwitch = saved end
    end
end

function addon.fontRuntime.schedulePendingSavedFontRetry()
    local pending = addon.fontRuntime.pendingSavedFont
    if not pending or addon.fontRuntime.pendingRetryScheduled then return end
    local nextAttempt = addon.fontRuntime.pendingRetryAttempt + 1
    local delay = addon.fontRuntime.pendingRetryDelays[nextAttempt]
    if not delay then return end

    addon.fontRuntime.pendingRetryAttempt = nextAttempt
    addon.fontRuntime.pendingRetryScheduled = true
    local generation = addon.fontRuntime.pendingRetryGeneration
    C_Timer.After(delay, function()
        if generation ~= addon.fontRuntime.pendingRetryGeneration then return end
        addon.fontRuntime.pendingRetryScheduled = false
        local activeDB = addon.dbRuntime.GetActiveSettings()
        local writableDB = addon.dbRuntime.GetWritableSettings(false)
        if not activeDB or not SameFontPath(activeDB.font, pending) then
            addon.fontRuntime.pendingSavedFont = nil
            addon.fontRuntime.pendingRetryGeneration = addon.fontRuntime.pendingRetryGeneration + 1
            return
        end
        if not writableDB then
            if not addon.dbRuntime.readOnly and addon.profileRuntime.BlocksUserWrites() then
                addon.fontRuntime.pendingRetryAttempt = math.max(
                    0, addon.fontRuntime.pendingRetryAttempt - 1)
                return
            end
            addon.fontRuntime.pendingSavedFont = nil
            addon.fontRuntime.pendingRetryGeneration = addon.fontRuntime.pendingRetryGeneration + 1
            return
        end

        local applied = addon.fontRuntime.applyCommittedTextStyle(
            pending, GetNumberDB("fontSize"), true, false)
        if applied then
            addon.fontRuntime.pendingSavedFont = nil
            addon.fontRuntime.pendingRetryAttempt = 0
            addon.fontRuntime.pendingRetryGeneration = addon.fontRuntime.pendingRetryGeneration + 1
            addon:RunUpdateStatsSafe()
            if type(addon.profileRuntime.RefreshConfigControls) == "function" then
                addon.profileRuntime.RefreshConfigControls()
            end
            return
        end
        addon.fontRuntime.schedulePendingSavedFontRetry()
    end)
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
        addon.fontRuntime.preferredPath(), GetNumberDB("fontSize"), false, true)
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
-- but are called from MaybeAutoSwitchFont below and the Settings language preview
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
--   2. Settings localization hover preview — visual-only preview, no DB writes.
-- Returns currentFont if already compatible (caller can use this to detect "no swap needed").
-- Returns nil if no compatible font found anywhere in the 3-tier fallback chain
-- (caller should leave font alone — the Settings locale warning surfaces the issue).
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

-- Format clean values in Lua. Restricted combat values bypass every Lua numeric or
-- string formatter and use Blizzard's secret-safe FontString C formatter before
-- flowing only through concatenation and FontString:SetText. If that formatter is not
-- available, the C_StringUtil fallback intentionally rounds to the nearest integer.
-- Other unavailable/invalid values stay nil so callers can preserve intentional
-- unsupported-API and pre-login row suppression.
function SAFE_NUM.FormatColorNumber(colorHex, value, format, secretSuffix)
    local text, renderable = SAFE_NUM.FormatDisplayNumber(
        value, format, secretSuffix)
    if not renderable then return nil end
    return "|cff" .. colorHex .. text .. "|r"
end

-- Compose colored "X.X%" string. 5-callsite hot path; centralizes precision.
local function FmtColorPct(colorHex, pct)
    return SAFE_NUM.FormatColorNumber(colorHex, pct, "%.1f%%", "%")
end

-- Format a stat value (rating + percentage variants honoring user toggles).
-- Returns TWO strings (ratingStr, valueStr) — see IsDualColMode for routing rules.
local function FmtRatingPct(rating, pct, statColor, forceUnknownPercent,
        formattedValue, hasFormattedValue)
    local cs = cached.colorStrings
    local rc = (cached.matchValueColorToStat and statColor) or cs.rating
    local pc = (cached.matchValueColorToStat and statColor) or cs.percentage
    local ratingStr = SAFE_NUM.FormatColorNumber(rc, rating, "%d") or ("|cff" .. rc .. "?|r")
    local pctStr
    if hasFormattedValue then
        -- formattedValue may be secret; concatenate only, never inspect it.
        pctStr = "|cff" .. pc .. formattedValue .. "|r"
    elseif forceUnknownPercent then
        pctStr = "|cff" .. pc .. "?%|r"
    else
        pctStr = FmtColorPct(pc, pct)
    end
    if IsDualColMode() then
        return ratingStr .. " |cff808080|||r", pctStr or ""
    elseif cached.showRating then
        return ratingStr, ""
    else
        -- percent-only: route into rating col (single-column layout)
        return pctStr or ("|cff" .. pc .. "?|r"), ""
    end
end

-- Format a percentage-only stat (no rating dimension, e.g. defensive Dodge/Parry).
-- Returns (ratingCol, valueCol) — same routing rule as FmtRatingPct.
local function FmtPctOnly(pct, statColor)
    local cs = cached.colorStrings
    local pc = (cached.matchValueColorToStat and statColor) or cs.percentage
    local pctStr = FmtColorPct(pc, pct) or ("|cff" .. pc .. "?|r")
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
    local val = SAFE_NUM.ResolveDisplayNumber(GetEffectiveStat(statId), false)
    if not SAFE_NUM.IsRenderableNumberValue(val) then return end
    local value = SAFE_NUM.FormatColorNumber(valueColor, val, "%d") or ("|cff" .. valueColor .. "?|r")
    local rCol, vCol = RouteValueOnly(value)
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
    -- WHY: Blizzard's character panel floors both values; rounding can also
    -- promote an equipped-vs-overall delta across the warning thresholds.
    local overall = math.floor(cached.itemLevelOverall)
    local equipped = math.floor(cached.itemLevelEquipped)
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
            local val, currentPercent, percentState
            if def.composite then
                val, currentPercent, percentState = SAFE_NUM.SafeCompositePercent(def.api)
            else
                val, currentPercent = SAFE_NUM.SafeDisplayPercent(def.api)
            end
            local ratingDisplay, targetRating
            local ratingRead = false
            local forceUnknownPercent = percentState == "restricted"
            local visible = shouldShowUnknown(
                    def.showKey, forceUnknownPercent, cached.hideZeroOffensive)
                or shouldShow(def.showKey, val, cached.hideZeroOffensive)
            if cached.showRating then
                ratingDisplay, targetRating = SAFE_NUM.ReadRatingValue(
                    GetCombatRating, def.ratingCR)
                ratingRead = true
                local ratingVisible = shouldShow(def.showKey .. "Rating", ratingDisplay, cached.hideZeroOffensive)
                visible = visible or ratingVisible
            end
            if visible then
                if (cached.showRating or needTargetRating) and not ratingRead then
                    ratingDisplay, targetRating = SAFE_NUM.ReadRatingValue(
                        GetCombatRating, def.ratingCR)
                end
                local rating
                if cached.showRating then rating = ratingDisplay end
                local statColor = cs[def.colorKey]
                local rStr, vStr = FmtRatingPct(
                    rating, val, statColor, forceUnknownPercent)
                if targetRows then
                    targetRows[#targetRows + 1] = addon.archonTargets.BuildMeta(
                        def.statKey, targetRating, def.ratingCR, currentPercent,
                        def.colorKey, val, ratingDisplay) or false
                end
                PushRow(labels, ratings, values,
                    FormatLabel(statColor, def.label),
                    rStr, vStr)
            end
        end
    end

    -- Versatility: dual-source (rating bonus + flat). Cache clean exact totals.
    -- A restricted component can render directly only when its clean counterpart is
    -- zero; partial or fully restricted composites retain the last complete total or
    -- render explicit unknown without entering arithmetic.
    if cached.showVersatility then
        local versFromRating = safeCall(GetCombatRatingBonus, CR_VERSATILITY_DAMAGE_DONE)
        local versFlat       = safeCall(GetVersatilityBonus,  CR_VERSATILITY_DAMAGE_DONE)
        local versDisplay = cached.versTotal
        local versClean
        local versDisplayUnknown = false
        local versRatingDisplay
        local targetVersRating
        local versTooltipDisplay
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
            versTooltipDisplay = cached.versTotal
        -- A secret component is still the complete total when its clean counterpart
        -- is exactly zero, so it may use the same whitelisted display-only path as
        -- direct stat APIs. Otherwise retain only the last complete clean total; never
        -- present one non-zero component as full Versatility.
        elseif ratingIsSecret and flatIsClean and versFlat == 0 then
            versDisplay = versFromRating
            versTooltipDisplay = versFromRating
        elseif flatIsSecret and ratingIsClean and versFromRating == 0 then
            versDisplay = versFlat
            versTooltipDisplay = versFlat
        elseif versDisplay == nil and (ratingIsSecret or flatIsSecret) then
            versDisplayUnknown = true
        end
        if cached.showRating or needTargetRating then
            versRatingDisplay, targetVersRating = SAFE_NUM.ReadRatingValue(
                GetCombatRating, CR_VERSATILITY_DAMAGE_DONE)
            if targetVersRating then
                cached.versTotalRating = targetVersRating
            end
        end
        local versVisible = shouldShowUnknown(
                "showVersatility", versDisplayUnknown, cached.hideZeroOffensive)
            or shouldShow("showVersatility", versDisplay, cached.hideZeroOffensive)
        if cached.showRating then
            local versRatingVisible = shouldShow("showVersatilityRating", versRatingDisplay, cached.hideZeroOffensive)
            versVisible = versVisible or versRatingVisible
        end
        if versVisible then
            local versStr = cs.versatility
            local rating
            if cached.showRating then
                if SAFE_NUM.IsCleanFiniteNumber(versRatingDisplay) then
                    rating = versRatingDisplay
                elseif SAFE_NUM.IsCleanFiniteNumber(cached.versTotalRating) then
                    rating = cached.versTotalRating
                else
                    rating = versRatingDisplay
                end
            end
            local vRatStr, vValStr = FmtRatingPct(
                rating, versDisplay, versStr, versDisplayUnknown)
            if targetRows then
                targetRows[#targetRows + 1] = addon.archonTargets.BuildMeta(
                    "versatility", targetVersRating, CR_VERSATILITY_DAMAGE_DONE,
                    versClean, "versatility", versTooltipDisplay,
                    versRatingDisplay) or false
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
            local val
            local forceUnknownPercent = false
            local formattedValue
            local hasFormattedValue = false
            if def.valueKind == "movement" then
                local ok, _, runSpeed = pcall(def.api, "player")
                if ok and cached.showPercentage then
                    local restricted
                    val, formattedValue, hasFormattedValue, restricted =
                        addon.movementRuntime.ResolvePercent(runSpeed)
                    forceUnknownPercent = restricted and not hasFormattedValue
                end
            else
                val = SAFE_NUM.SafeDisplayPercent(def.api)
            end
            local ratingDisplay
            local visible = hasFormattedValue or shouldShowUnknown(
                    def.showKey, forceUnknownPercent, cached.hideZeroTertiary)
                or shouldShow(def.showKey, val, cached.hideZeroTertiary)
            if needRating then
                ratingDisplay = SAFE_NUM.ReadRatingValue(GetCombatRating, def.ratingCR)
                local ratingVisible = shouldShow(def.showKey .. "Rating", ratingDisplay, cached.hideZeroTertiary)
                visible = visible or ratingVisible
            end
            if visible then
                local rating
                if needRating then rating = ratingDisplay end
                local statColor = cs[def.colorKey]
                local rStr, vStr = FmtRatingPct(
                    rating, val, statColor, forceUnknownPercent,
                    formattedValue, hasFormattedValue)
                PushRow(labels, ratings, values,
                    FormatLabel(statColor, def.label),
                    rStr, vStr)
            end
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
            local val = SAFE_NUM.SafeDisplayPercent(def.api)
            if shouldShow(def.showKey, val, cached.hideZeroDefensive) then
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
    if cached.durabilityComplete and not cached.durabilityHasItems then
        return labels, ratings, values
    end
    local cs = cached.colorStrings
    local pct = cached.durabilityValue
    local durStr = cs.durability
    if not SAFE_NUM.IsCleanFiniteNumber(pct) then
        local rCol, vCol = RouteValueOnly("?")
        PushRow(labels, ratings, values,
            FormatLabel(durStr, "Durability"), rCol, vCol)
        return labels, ratings, values
    end
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
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
    if not isLoaded then return end
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

addon.profileRuntime.CompleteBootstrap = function()
    local runtime = addon.profileRuntime
    if isLoaded then
        runtime.bootstrapPending = false
        return true
    end
    addon.fontRuntime.repairSavedPaths()
    CacheSettings()
    if RefreshPersistentLocalization then RefreshPersistentLocalization() end
    -- WHY here: forceLocale is migrated + cached.activeLabels resolved; if active
    -- locale needs glyphs db.font lacks, auto-switch before the first panel style pass.
    local runtimeFont = MaybeAutoSwitchFont()
    LoadAllPositions()
    SetAllPanelsScale(GetNumberDB("scale"))
    addon.fontRuntime.applyCommittedTextStyle(
        runtimeFont or GetFontDB(), GetNumberDB("fontSize"), false, true)
    ApplyTextAlphaToAllPanels(cached.textAlpha)
    addon.readabilityConfig.applyPanelBackgroundAlphaToAllPanels(cached.panelBackgroundAlpha)
    isLoaded = true
    runtime.bootstrapPending = false
    addon.fontRuntime.schedulePendingSavedFontRetry()
    if type(runtime.RefreshConfigControls) == "function" then
        runtime.RefreshConfigControls()
    end
    if type(addon.panelEditRuntime.Refresh) == "function" then
        addon.panelEditRuntime.Refresh(false)
    end
    addon.durabilityRuntime.MarkDirty()
    addon.itemLevelRuntime.MarkDirty()
    addon:RunUpdateStatsSafe()
    addon.profileUI.RefreshSafe()
    local account = addon.dbRuntime.GetAccount()
    if account and rawget(account, "quickSetupSeen") == false
        and (addon.__statsproSmoke ~= true or addon.__testWelcomeEnabled == true) then
        C_Timer.After(0.5, function()
            if isLoaded then addon.hudPresets.MaybeShowWelcome() end
        end)
    end
    return true
end

local function OnPlayerEnteringWorld()
    if not isLoaded then
        mainPanel:Hide()
        defensivePanel:Hide()
        -- First-run carry-forward happens at PEW so the source SavedVariables globals
        -- are populated regardless of addon load order. The field-driven importer only
        -- runs against an empty StatsPro DB; established settings are never overwritten
        -- without the explicit `/statspro import` confirmation path.
        if not addon.profileRuntime.bootstrapStarted then
            addon.legacyImport.ImportFreshIfAvailable()
            MigrateDB()
            addon.dbRuntime.Refresh()
            addon.profileRuntime.bootstrapStarted = true
        end
        -- Resolve the character/spec profile before the first cache/style/position
        -- pass. Combat/unknown identity keeps both frames hidden until a mapped
        -- profile is authoritative; terminal no-spec/unavailable/read-only modes
        -- retain the account-default compatibility fallback.
        addon.profileRuntime.bootstrapPending = true
        addon.profileRuntime.RequestResolution(true)
        return
    end
    addon.profileRuntime.RequestResolution(false)
    -- WHY: UpdateStats handles Show/Hide based on cached.isVisible + line content.
    addon.durabilityRuntime.MarkDirty()
    addon.itemLevelRuntime.MarkDirty()
    addon:RunUpdateStatsSafe()
end

-- WHY: Armor/DR refresh runs inline in UpdateStats out-of-combat (cheap), so we
-- don't need specialization/trait handlers. Level changes are handled below
-- because Archon Mastery percentages reuse a clean, level-dependent conversion.
-- PLAYER_REGEN_ENABLED remains useful for retrying repair costs that were secret.
-- WHY MERCHANT_SHOW marks dirty: repairCost can surface after the old cached scan
-- settled as unknown, and opening a vendor does not necessarily fire a durability event.
-- The handler only flips the dirty flag; the OnUpdate path still coalesces the scan.
-- WHY: PLAYER_LOGOUT fires before SavedVariables are written to disk. Re-saving
-- positions here is a belt-and-suspenders backup: OnMouseUp already saves on drop,
-- but if the user reloads/quits via a path that bypasses our drag handler (rare),
-- this guarantees the latest GetPoint() is what hits disk.
local function OnPlayerLogout()
    -- Restore any unaccepted StatsPro-owned color preview before SavedVariables
    -- flush. The ownership check inside Close leaves a foreign picker untouched.
    if addon.settingsUI.CloseColorPicker then addon.settingsUI.CloseColorPicker(true) end
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
    -- Rating conversion is player-level dependent. PLAYER_LEVEL_CHANGED covers
    -- both real and effective-level transitions in current Retail FrameXML.
    PLAYER_LEVEL_CHANGED         = function()
        addon.archonTargets.InvalidateComparisonCache()
    end,
    -- UnitFullName may be unavailable during the initial cache warmup; retry the
    -- existing same-context metadata path when Blizzard reports the player name ready.
    UNIT_NAME_UPDATE             = function(unit)
        if not addon.dbRuntime.IsCleanType(unit, "string") or unit ~= "player" then return end
        addon.profileRuntime.RequestResolution(false)
    end,
    UPDATE_INVENTORY_DURABILITY = function() addon.durabilityRuntime.MarkDirty() end,
    PLAYER_EQUIPMENT_CHANGED    = function()
        addon.durabilityRuntime.MarkDirty()
        addon.itemLevelRuntime.MarkDirty()
    end,
    BAG_UPDATE_DELAYED          = function() addon.itemLevelRuntime.MarkDirty() end,
    DISPLAY_SIZE_CHANGED        = function()
        if type(addon.settingsDesign.RequestResponsiveFrameResize) == "function" then
            addon.settingsDesign.RequestResponsiveFrameResize()
        end
    end,
    UI_SCALE_CHANGED            = function()
        if type(addon.settingsDesign.RequestResponsiveFrameResize) == "function" then
            addon.settingsDesign.RequestResponsiveFrameResize()
        end
    end,
    -- WHY: bag/equipment events can precede Blizzard's asynchronous average-iLvl
    -- recompute. This authoritative follow-up reopens the cache for the coalesced ticker.
    PLAYER_AVG_ITEM_LEVEL_UPDATE = function() addon.itemLevelRuntime.MarkDirty() end,
    MERCHANT_SHOW               = function() addon.durabilityRuntime.MarkDirty() end,
    -- WHY: lock state is stored in cached.isLocked and read by OnDragStart. Mouse stays
    -- enabled permanently so right-click Settings works even while locked.
    PLAYER_REGEN_ENABLED        = function()
        addon.hudPresets.combatState = false
        addon.profileRuntime.ResumeCorruptRollbackApply()
        local wasLoaded = isLoaded
        addon.profileRuntime.ResolvePending(true)
        if (addon.profileRuntime.bootstrapStarted and not isLoaded)
            or (not wasLoaded and isLoaded) then
            addon.profileUI.RefreshSafe()
            return
        end
        -- The event is authoritative even if InCombatLockdown() lags by one frame.
        addon.panelEditRuntime.Refresh(false)
        if (cached.showDurability and cached.durabilityComplete == false)
            or (cached.showRepairCost and cached.repairCostComplete == false) then
            addon.durabilityRuntime.MarkDirty()
        end
        if cached.showItemLevel and cached.itemLevelComplete == false then
            addon.itemLevelRuntime.MarkDirty()
        end
        addon.profileUI.RefreshSafe()
        addon.hudPresets.MaybeShowWelcome()
    end,
    PLAYER_REGEN_DISABLED       = function()
        addon.hudPresets.combatState = true
        addon.profileRuntime.CancelOwnedMutationPopups()
        addon.presetRuntime.ForceCancelAllPreviews()
        addon.hudPresets.SuspendWelcomeForCombat()
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
-- re-syncs that widget's visuals from DB. Reset walks this list
-- (Section 15) instead of rebuilding the named frame (which would leak
-- _G.StatsProConfigFrame per click — CreateFrame's named globals are immortal
-- in WoW Lua, no Hide()/SetParent(nil) releases them).
local configRefreshers = {}
local function PushRefresher(fn) tinsert(configRefreshers, fn) end

-- WHY centralized layout constants: a tweak (tighter swatch gap, wider columns) used
-- to require hunting ~10 callsites with hardcoded 6/220/12/font literals — easy to
-- miss one and ship inconsistent UI. Dense settings copy prefers a neutral readable
-- SharedMedia face when available, then falls back to Blizzard's locale-aware UI font.
addon.fontRuntime.configFontMediaPreferences = {
    { name = "Noto Sans Medium",  glyphs = { GLYPH_LATIN, GLYPH_CYR } },
    { name = "Noto Sans Regular", glyphs = { GLYPH_LATIN, GLYPH_CYR } },
}
local function LocaleAwareConfigFont()
    local glyphRequirement = LOCALE_GLYPH_REQ[GetLocale()] or GLYPH_LATIN
    for _, media in ipairs(addon.fontRuntime.configFontMediaPreferences) do
        local path = addon.fontRuntime.rawLSMPath(media.name)
        if path then
            AddFontGlyphSupport(path, media.glyphs)
            if FontSupports(path, glyphRequirement) then return path end
        end
    end
    return LocaleAwareDefaultFont()
end

local CONFIG_FONT = LocaleAwareConfigFont()

-- Locale-aware settings UI font: same idea as MaybeAutoSwitchFont for stat panels,
-- but for the config window's CreateFontString-based labels (title, tabs, section
-- headers, checkboxes, sliders, dropdown captions, font picker rows, langWarn).
-- Blizzard FontObjects (GameFontNormal etc. used by buttons) carry built-in OS
-- fallback so they render Cyrillic/CJK acceptably. StatsPro's owned FontObjects still
-- need an explicit locale-compatible face; without this swap, ruRU/zhCN previews on
-- enUS clients render as boxes. ApplyConfigFont refreshes semantic font groups in place.
local currentConfigFont    = CONFIG_FONT
local localizedConfigFonts = {}

local function ConfigFontGroupKey(roleKey, size, flags)
    local semanticRole = type(roleKey) == "string" and roleKey ~= ""
        and roleKey or "custom"
    return semanticRole .. "\031" .. size .. "\031" .. (flags or "")
end

local function ConfigFontGroupRegions(group)
    local regions = {}
    for _, entry in ipairs(group.entries) do tinsert(regions, entry.fs) end
    return regions
end

local function RemoveConfigFontEntry(group, entry)
    if not group then return end
    for index = #group.entries, 1, -1 do
        if rawequal(group.entries[index], entry) then
            tremove(group.entries, index)
            break
        end
    end
    if #group.entries == 0 then
        local groups = localizedConfigFonts.groups or {}
        local groupOrder = localizedConfigFonts.groupOrder or {}
        groups[group.key] = nil
        for index = #groupOrder, 1, -1 do
            if rawequal(groupOrder[index], group) then
                tremove(groupOrder, index)
                break
            end
        end
    end
end

local function GetConfigFontGroup(groupKey, size, flags)
    local groups = localizedConfigFonts.groups
    local groupOrder = localizedConfigFonts.groupOrder
    if not groups then
        groups = {}
        groupOrder = {}
        localizedConfigFonts.groups = groups
        localizedConfigFonts.groupOrder = groupOrder
    end
    local group = groups[groupKey]
    if group then return group end

    local fontObject = addon.fontRuntime.getOwnedFontObject("settings:" .. groupKey)
    if not fontObject then return nil end
    group = {
        key = groupKey,
        size = size,
        flags = flags,
        object = fontObject,
        entries = {},
    }
    groups[groupKey] = group
    tinsert(groupOrder, group)
    return group
end

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

-- Settings FontStrings inherit from stable addon-owned FontObjects before their
-- first localized SetText. Direct SetFont remains only a compatibility fallback:
-- on a cold client it can leave a newly created region without any font at all.
local function RegisterConfigFont(fs, size, flags, roleKey)
    local entry = localizedConfigFonts[fs]
    if not entry then
        entry = { fs = fs }
        localizedConfigFonts[fs] = entry
        tinsert(localizedConfigFonts, entry)
    end
    local groupKey = ConfigFontGroupKey(roleKey, size, flags)
    if entry.group and entry.group.key ~= groupKey then
        RemoveConfigFontEntry(entry.group, entry)
        entry.group = nil
    end
    entry.roleKey = roleKey
    entry.size = size
    entry.flags = flags
    local previousText = fs:GetText()
    local registryRollbackFailed = false

    local function TryInherit(group, font, effectiveFlags)
        if not group or not font then return false end
        local oldFont, oldSize, oldFlags =
            group.appliedFont, group.appliedSize, group.appliedFlags
        local objectReady = addon.fontRuntime.matchesAppliedFont(
            group.object, font, size, effectiveFlags)
        if not objectReady then
            objectReady = addon.fontRuntime.setOwnedFont(
                group.object, ConfigFontGroupRegions(group), font, size, effectiveFlags)
            if not objectReady and oldFont then
                local restored = addon.fontRuntime.restoreOwned(
                    group.object, ConfigFontGroupRegions(group), oldFont, oldSize, oldFlags)
                if not restored then
                    registryRollbackFailed = true
                    group.appliedFont = nil
                    group.appliedSize = nil
                    group.appliedFlags = nil
                    for _, groupEntry in ipairs(group.entries) do
                        groupEntry.appliedFont = nil
                        groupEntry.appliedSize = nil
                        groupEntry.appliedFlags = nil
                    end
                    currentConfigFont = nil
                    addon.fontRuntime.configFontValidated = false
                end
            end
        end
        if not objectReady then return false end
        local inherited = entry.group == group
            or addon.fontRuntime.attachOwnedFontObject(fs, group.object)
        return inherited and addon.fontRuntime.ownedRegionsMatch(
            { fs }, group.object, font, size, effectiveFlags)
    end

    local function CommitGroup(group, font, effectiveFlags)
        if entry.group ~= group then
            entry.group = group
            tinsert(group.entries, entry)
        end
        if previousText ~= nil then fs:SetText(previousText) end
        currentConfigFont = font
        addon.fontRuntime.configFontValidated = true
        group.appliedFont = font
        group.appliedSize = size
        group.appliedFlags = effectiveFlags
        entry.appliedFont = font
        entry.appliedSize = size
        entry.appliedFlags = effectiveFlags
        return true, font
    end

    local resolvedFont, effectiveFlags
    if addon.fontRuntime.configFontValidated then
        resolvedFont, effectiveFlags = addon.fontRuntime.resolveUsableFlags(
            currentConfigFont, size, flags)
    else
        resolvedFont, effectiveFlags = addon.fontRuntime.resolveFlags(
            currentConfigFont, size, flags)
    end
    local group = resolvedFont and GetConfigFontGroup(groupKey, size, flags) or nil
    if TryInherit(group, resolvedFont, effectiveFlags) then
        return CommitGroup(group, resolvedFont, effectiveFlags)
    end

    -- Compatibility path for clients where CreateFont/SetFontObject is unavailable.
    if entry.group then RemoveConfigFontEntry(entry.group, entry) end
    entry.group = nil
    if resolvedFont and addon.fontRuntime.setRegionFont(fs, resolvedFont, size, effectiveFlags) then
        if previousText ~= nil then fs:SetText(previousText) end
        currentConfigFont = resolvedFont
        addon.fontRuntime.configFontValidated = true
        entry.appliedFont = resolvedFont
        entry.appliedSize = size
        entry.appliedFlags = effectiveFlags
        if registryRollbackFailed then
            return ApplyConfigFont(resolvedFont, true)
        end
        return true, resolvedFont
    end

    -- A failed direct SetFont may clear the region. Attach a separate owned
    -- Blizzard fallback before any caller is allowed to set text.
    local active = ResolveActiveLocale()
    local req = LOCALE_GLYPH_REQ[active] or GLYPH_LATIN
    local fallback = FindCompatibleFont(addon.fontRuntime.safeDefaultPath(), req)
        or addon.fontRuntime.safeDefaultPath()
    local fallbackFont, fallbackFlags = addon.fontRuntime.resolveFlags(
        fallback, size, flags)
    local fallbackGroup = fallbackFont and GetConfigFontGroup(
        "fallback\031" .. groupKey, size, flags) or nil
    if TryInherit(fallbackGroup, fallbackFont, fallbackFlags) then
        local applied, effective = CommitGroup(
            fallbackGroup, fallbackFont, fallbackFlags)
        if registryRollbackFailed then ApplyConfigFont(fallbackFont, true) end
        return applied, effective
    end
    return false, nil, "font-unavailable"
end

-- Called from MaybeAutoSwitchFont and the Settings language preview. Idempotent
-- fast-path skips work when currentConfigFont already matches (covers PEW + back-to-
-- default-locale scenarios). WHY no `local`: assigns the forward-decl'd upvalue.
ApplyConfigFont = function(font, force)
    if not force and addon.fontRuntime.configFontValidated
        and SameFontPath(font, currentConfigFont) then
        return true, currentConfigFont
    end
    local usable = addon.fontRuntime.usablePath(font)
    if not usable then return false end
    if #localizedConfigFonts == 0 then
        currentConfigFont = usable
        addon.fontRuntime.configFontValidated = true
        return true, usable
    end

    local groupPlans, directPlans, previousText = {}, {}, {}
    local groupOrder = localizedConfigFonts.groupOrder or {}
    for _, group in ipairs(groupOrder) do
        if #group.entries > 0 then
            local resolvedFont, effectiveFlags = addon.fontRuntime.resolveUsableFlags(
                usable, group.size, group.flags)
            if not resolvedFont then return false end
            tinsert(groupPlans, {
                group = group,
                font = resolvedFont,
                flags = effectiveFlags,
                oldFont = group.appliedFont,
                oldSize = group.appliedSize,
                oldFlags = group.appliedFlags,
            })
        end
    end
    for i, entry in ipairs(localizedConfigFonts) do
        previousText[i] = entry.fs:GetText()
        if not entry.group then
            local resolvedFont, effectiveFlags = addon.fontRuntime.resolveUsableFlags(
                usable, entry.size, entry.flags)
            if not resolvedFont then return false end
            tinsert(directPlans, {
                entry = entry,
                font = resolvedFont,
                flags = effectiveFlags,
                oldFont = entry.appliedFont,
                oldSize = entry.appliedSize,
                oldFlags = entry.appliedFlags,
            })
        end
    end

    local changedGroups, changedDirect = {}, {}
    local function RestoreConfigFonts()
        local restored = true
        for index = #changedDirect, 1, -1 do
            local plan = changedDirect[index]
            if not plan.oldFont or not addon.fontRuntime.restore(
                    { plan.entry.fs }, plan.oldFont, plan.oldSize, plan.oldFlags) then
                restored = false
            end
        end
        for index = #changedGroups, 1, -1 do
            local plan = changedGroups[index]
            if not plan.oldFont or not addon.fontRuntime.restoreOwned(
                    plan.group.object, ConfigFontGroupRegions(plan.group),
                    plan.oldFont, plan.oldSize, plan.oldFlags) then
                restored = false
            end
        end
        -- Never restore text onto a region whose font rollback failed. Retail
        -- raises FontString:SetText(): Font not set and masks the real failure.
        for index, entry in ipairs(localizedConfigFonts) do
            if previousText[index] ~= nil then
                local fontReady = entry.appliedFont
                    and addon.fontRuntime.matchesAppliedFont(
                        entry.fs, entry.appliedFont,
                        entry.appliedSize, entry.appliedFlags)
                if fontReady then
                    entry.fs:SetText(previousText[index])
                else
                    restored = false
                end
            end
        end
        return restored
    end
    local function ClearConfigFontMetadata()
        currentConfigFont = nil
        addon.fontRuntime.configFontValidated = false
        for _, group in ipairs(groupOrder) do
            group.appliedFont = nil
            group.appliedSize = nil
            group.appliedFlags = nil
        end
        for _, entry in ipairs(localizedConfigFonts) do
            entry.appliedFont = nil
            entry.appliedSize = nil
            entry.appliedFlags = nil
        end
    end

    for _, plan in ipairs(groupPlans) do
        tinsert(changedGroups, plan)
        local groupApplied, groupStatus = addon.fontRuntime.setOwnedFont(
            plan.group.object, ConfigFontGroupRegions(plan.group),
            plan.font, plan.group.size, plan.flags)
        if not groupApplied then
            if not RestoreConfigFonts() then
                ClearConfigFontMetadata()
                groupStatus = "rollback-failed"
            end
            return false, groupStatus
        end
    end
    for _, plan in ipairs(directPlans) do
        tinsert(changedDirect, plan)
        local directApplied, directStatus = addon.fontRuntime.setRegionFont(
            plan.entry.fs, plan.font, plan.entry.size, plan.flags)
        if not directApplied then
            if not RestoreConfigFonts() then
                ClearConfigFontMetadata()
                directStatus = "rollback-failed"
            end
            return false, directStatus
        end
    end
    for index, entry in ipairs(localizedConfigFonts) do
        if previousText[index] ~= nil then entry.fs:SetText(previousText[index]) end
    end

    currentConfigFont = groupPlans[1] and groupPlans[1].font
        or directPlans[1] and directPlans[1].font
        or usable
    addon.fontRuntime.configFontValidated = true
    for _, plan in ipairs(groupPlans) do
        local group = plan.group
        group.appliedFont = plan.font
        group.appliedSize = group.size
        group.appliedFlags = plan.flags
        for _, entry in ipairs(group.entries) do
            entry.appliedFont = plan.font
            entry.appliedSize = entry.size
            entry.appliedFlags = plan.flags
        end
    end
    for _, plan in ipairs(directPlans) do
        local entry = plan.entry
        entry.appliedFont = plan.font
        entry.appliedSize = entry.size
        entry.appliedFlags = plan.flags
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
-- Dropdown body width is shared across Display Mode / Language / Font. Long-content
-- labels (Language's "Auto (current: %s)" and Latin-with-parenthetical locale labels) get
-- a CompactLabel transform that keeps short disambiguators where needed. Menu items
-- keep the full label form for disambiguation when picking. Font names from SharedMedia
-- can occasionally overflow — accepted: rare, names truncate to "Long Name..." and
-- the user can hover the dropdown for full text via Blizzard's tooltip.

-- Single source of truth for "DB color or fallback to default". This read path is
-- deliberately pure: opening Settings under a newer schema must not lazily create a
-- colors table and thereby mutate data owned by the newer addon version.
local function GetColor(statName)
    local db = addon.dbRuntime.GetActiveSettings()
    local colors = type(db.colors) == "table" and db.colors or {}
    colors = addon.presetRuntime.ResolveValue("colors", colors)
    local r, g, b = NormalizeColor(colors[statName], defaults.colors[statName])
    return { r = r, g = g, b = b }
end

-- WHY forward-decl: CreateCheckbox / CursorSection / CreateConfigSlider /
-- addon.settingsDesign.CreateTab
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
    local text = _G[name .. "Text"]
    PushLocalizedLabel(function() text:SetText(L(label)) end)
    -- textWidth: 200 default for plain checkboxes; pass 140 for "checkbox + inline color"
    -- rows (CreateCheckboxColor overrides the bound width to actual text width post-call).
    text:SetWidth(textWidth or addon.settingsDesign.tokens.geometry.checkboxLabelWidth)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    text:SetMaxLines(1)
    cb:SetChecked(GetBoolDB(dbKey))
    addon.settingsDesign.StyleCheckbox(cb, text)
    cb:SetScript("OnClick", function(self)
        -- BeforeManualEdit may synchronously cancel an Appearance preset preview,
        -- whose refreshers restore every checkbox from the committed baseline.
        -- Preserve the state the user actually clicked before that restore runs.
        local requestedChecked = self:GetChecked() == true
        if not addon.appearancePresets.BeforeManualEdit(dbKey) then
            self:SetChecked(GetBoolDB(dbKey))
            addon.settingsDesign.RefreshControl(self)
            return
        end
        if not addon.hudPresets.BeforeManualEdit(dbKey) then
            self:SetChecked(GetBoolDB(dbKey))
            addon.settingsDesign.RefreshControl(self)
            return
        end
        local db = addon.dbRuntime.GetWritableSettings(true, dbKey)
        if not db then
            self:SetChecked(GetBoolDB(dbKey))
            addon.settingsDesign.RefreshControl(self)
            return
        end
        local previous = db[dbKey]
        db[dbKey] = requestedChecked
        self:SetChecked(requestedChecked)
        if previous ~= db[dbKey] and addon.appearancePresets.allowlist[dbKey] then
            addon.appearancePresets.MarkCustom(db)
        end
        CacheSettings()
        if onChange then onChange(requestedChecked) end
        addon:RunUpdateStatsSafe()
        if addon.hudPresets.allowlist[dbKey] then
            addon.hudPresets.RefreshUI()
        end
        -- Keep the custom row state in sync in the click handler itself.  The
        -- native check texture updates immediately; the surrounding hover/row
        -- styling must not wait for OnLeave or rely on hook ordering.
        addon.settingsDesign.RefreshControl(self)
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
local COLOR_PICKER_STATE = { active = nil }

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

function COLOR_PICKER_STATE.Close(forLogout)
    local session = COLOR_PICKER_STATE.active
    if not session then return end
    local pickerShown = ColorPickerFrame and ColorPickerFrame:IsShown()
    if not pickerShown then
        -- Without a proven OnHide hook, a hidden frame may be a valid accepted
        -- fallback. Preserve the selected RGB and only retire the stale session.
        COLOR_PICKER_STATE.Clear(session)
        return
    end
    local ownsFrame = COLOR_PICKER_STATE.OwnsFrame(session)
    if forLogout and session.restoreForLogout then
        session.restoreForLogout()
    else
        COLOR_PICKER_STATE.RestoreSnapshot(session)
    end
    if ownsFrame then
        ColorPickerFrame:Hide()
    end
end
addon.settingsUI.CloseColorPicker = COLOR_PICKER_STATE.Close

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

    local session = {
        btn = btn,
        statName = statName,
        hadExplicitColor = hadExplicitColor,
        snapshot = snapshot,
        root = addon.dbRuntime.rootRef,
        settings = db,
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
    local function RestoreSnapshotToSettings(settings)
        if type(settings.colors) ~= "table" then settings.colors = {} end
        addon.settingsDesign.SetSwatchColor(btn, snapshot.r, snapshot.g, snapshot.b)
        settings.colors[statName] = hadExplicitColor
            and { r = snapshot.r, g = snapshot.g, b = snapshot.b } or nil
    end
    local function FinishCancel()
        if not addon.profileRuntime.suppressIntermediateRefresh then
            CacheSettings()
            addon:RunUpdateStatsSafe()
        end
        COLOR_PICKER_STATE.Clear(session)
    end
    local function OnCancel()
        if not COLOR_PICKER_STATE.IsActive(session) then return end
        local writableDB = addon.dbRuntime.GetWritableSettings(true)
        if writableDB and session.generation == addon.dbRuntime.generation then
            RestoreSnapshotToSettings(writableDB)
        else
            local persisted = GetColor(statName)
            addon.settingsDesign.SetSwatchColor(btn, persisted.r, persisted.g, persisted.b)
        end
        FinishCancel()
    end
    session.swatchFunc = OnColorSelect
    session.cancelFunc = OnCancel
    session.restoreForLogout = function()
        if not COLOR_PICKER_STATE.IsActive(session) then return end
        local rootVersion = session.root and NormalizeDBVersion(rawget(session.root, "dbVersion"))
            or CURRENT_DB_VERSION + 1
        if session.generation == addon.dbRuntime.generation
            and rootVersion == CURRENT_DB_VERSION
            and rawequal(addon.dbRuntime.rootRef, session.root)
            and rawequal(addon.dbRuntime.activeSettings, session.settings)
            and addon.dbRuntime.IsCleanTable(session.settings) then
            -- Pending profile resolution blocks ordinary writes, but rollback is safe
            -- for the exact settings table that received this session's preview.
            RestoreSnapshotToSettings(session.settings)
            FinishCancel()
        else
            OnCancel()
        end
    end
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
    surface:SetPoint("TOPLEFT", btn, "TOPLEFT", 2, -2)
    surface:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
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
        text.statsProMaxWidth = addon.settingsDesign.tokens.geometry.checkboxColorLabelMaxWidth
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
local function RefreshConfigLocalization(skipSetters)
    RefreshPersistentLocalization()
    for _, setter in ipairs(localizedConfigLabels) do
        if not skipSetters or not skipSetters[setter] then setter() end
    end
    for _, g in ipairs(alignmentGroups) do
        ReAlignGroupImpl(g.rows, g.gap)
    end
end

addon.profileRuntime.RefreshConfigControls = function()
    if #configRefreshers == 0 then return true end
    local refreshed = {}
    for _, refresh in ipairs(configRefreshers) do
        local ok = pcall(refresh)
        if not ok then PrintMsg("Settings control refresh failed.") end
        refreshed[refresh] = true
    end
    local localized = pcall(RefreshConfigLocalization, refreshed)
    if not localized then PrintMsg("Settings localization refresh failed.") end
    addon.profileRuntime.configRefreshCount = addon.profileRuntime.configRefreshCount + 1
    return true
end

--[[ ============================================================
    15. CONFIG MENU (tabs: Stats / Layout / Appearance)
============================================================ ]]
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
    -- The second runtime panel participates only in Split mode. Showing its sibling
    -- edit outline in Flat/Sectioned exposed an empty draggable box with no content.
    defensivePanel:SetEditAffordanceVisible(show and cached.displayMode == "split")
end

-- The Settings shell uses one explicit visual vocabulary.  Keep this runtime-only:
-- profile data and preview/commit semantics stay owned by their existing modules.
-- WHY table methods instead of more locals: this file is close to Lua 5.1's local and
-- closure limits, and shared controls can reuse the same roles without duplicating literals.
addon.settingsDesign = {
    tokens = {
        colors = {
            window = { 0.055, 0.065, 0.085, 0.995 },
            raised = { 0.090, 0.120, 0.165, 0.99 },
            profile = { 0.085, 0.155, 0.225, 0.985 },
            viewport = { 0.040, 0.050, 0.070, 0.985 },
            borderStrong = { 0.300, 0.500, 0.680, 0.84 },
            borderSoft = { 0.160, 0.270, 0.390, 0.68 },
            separator = { 0.250, 0.420, 0.580, 0.48 },
            accent = { 0.420, 0.650, 0.820, 1 },
            accentMuted = { 0.420, 0.650, 0.820, 0.28 },
            positive = { 0.420, 0.650, 0.820, 1 },
            textPrimary = { 0.930, 0.940, 0.965, 1 },
            textSecondary = { 0.700, 0.750, 0.820, 1 },
            textAccent = { 0.720, 0.820, 0.930, 1 },
            textMuted = { 0.460, 0.530, 0.620, 1 },
            textDisabled = { 0.320, 0.370, 0.440, 1 },
            warning = { 0.860, 0.700, 0.390, 1 },
            danger = { 0.840, 0.450, 0.420, 1 },
            hover = { 0.105, 0.160, 0.230, 0.98 },
            pressed = { 0.420, 0.650, 0.820, 0.18 },
            rowHover = { 0.420, 0.650, 0.820, 0.08 },
            rowPressed = { 0.420, 0.650, 0.820, 0.14 },
            selected = { 0.420, 0.650, 0.820, 0.22 },
            track = { 0.155, 0.240, 0.340, 0.85 },
            transparent = { 0, 0, 0, 0 },
        },
        typography = {
            title = { size = 16, flags = "OUTLINE", color = "textPrimary" },
            metadata = { size = 11, color = "textSecondary" },
            profile = { size = 12, color = "textPrimary" },
            tab = { size = 13, flags = "OUTLINE", color = "textSecondary" },
            section = { size = 12, flags = "OUTLINE", color = "textAccent" },
            button = { size = 12, color = "textPrimary" },
            body = { size = 12, color = "textPrimary" },
            value = { size = 12, flags = "OUTLINE", color = "textPrimary" },
            controlMetadata = { size = 10, color = "textSecondary" },
            warning = { size = 11, color = "warning" },
        },
        spacing = { xxs = 2, xs = 4, sm = 8, md = 12 },
        geometry = {
            windowWidth = 500, minHeight = 260, maxHeight = 600,
            parentHeightRatio = 0.90, outerInset = 12,
            managerMinWidth = 430, managerMaxWidth = 620, managerWidthRatio = 0.90,
            managerMinHeight = 300, managerMaxHeight = 440, managerHeightRatio = 0.85,
            managerDetailInset = 286,
            managerActionsTopShared = 146, managerActionsTopSolo = 112,
            titleSurfaceInset = 5, titleSurfaceHeight = 35, titleHeight = 40,
            titleTextInset = 16, titleTextTop = 11,
            profileInset = 14, profileTop = 44, profileHeight = 34,
            profileFieldInset = 8, profileFieldWidth = 316, manageWidth = 132,
            tabInset = 18, tabTop = 86, tabHeight = 28, tabGap = 4, tabWidth = 152,
            viewportInset = 12, viewportTop = 122, viewportBottom = 12,
            scrollLeft = 16, scrollRight = 32, scrollTop = 126, scrollBottom = 16,
            contentWidth = 450,
            minHitTarget = 24,
            sectionHeaderHeight = 22,
            scrollbarTrackWidth = 4, scrollbarArrowInset = 18,
            controlRowHeight = 28, controlHitTarget = 24,
            checkboxLabelGap = 6,
            checkboxLabelWidth = 176, checkboxColorLabelWidth = 140,
            checkboxColorLabelMaxWidth = 146,
            swatchSize = 24, swatchWellWidth = 16, swatchWellHeight = 12,
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
        },
        buttons = {
            field = {
                normal = { bg = "raised", border = "borderSoft", text = "textPrimary" },
                hover = { bg = "hover", border = "borderStrong", text = "textPrimary" },
                pressed = { bg = "pressed", border = "accentMuted", text = "textPrimary" },
                disabled = { bg = "raised", border = "borderSoft", text = "textDisabled" },
            },
            display = {
                normal = { bg = "transparent", border = "transparent", text = "textPrimary" },
                hover = { bg = "transparent", border = "transparent", text = "textPrimary" },
                pressed = { bg = "transparent", border = "transparent", text = "textPrimary" },
                disabled = { bg = "transparent", border = "transparent", text = "textDisabled" },
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
    RegisterConfigFont(region, role.size, role.flags, "role:" .. roleName)
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

function addon.settingsDesign.RefreshOwnedControlTooltip(control)
    if not GameTooltip:IsShown() or type(GameTooltip.GetOwner) ~= "function"
        or GameTooltip:GetOwner() ~= control then return false end
    GameTooltip:Hide()
    addon.settingsDesign.ShowControlTooltip(control)
    return true
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
    local blocker = blockers and (blockers.schema or blockers.context
        or blockers.combat or blockers.dependency)
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
            or ((pressed or hovered) and "textPrimary" or "accent")
        local thumbColor = addon.settingsDesign.Color(thumbRole)
        if control.statsProThumb then
            control.statsProThumb:SetVertexColor(
                thumbColor[1], thumbColor[2], thumbColor[3],
                enabled and (pressed and 1 or 0.86) or 0.35)
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
        if control.statsProHeading then
            addon.settingsDesign.SetTextureSurfaceColor(
                control.statsProStateTexture, "raised", 0)
            addon.settingsDesign.SetRegionColor(control.statsProText, "textPrimary")
        else
            local bgRole = pressed and "rowPressed" or (hovered and "rowHover"
                or (control.statsProSelected and "selected" or "raised"))
            local alpha = not enabled and 0 or (not hovered and not pressed
                and not control.statsProSelected and 0 or addon.settingsDesign.Color(bgRole)[4])
            addon.settingsDesign.SetTextureSurfaceColor(control.statsProStateTexture, bgRole, alpha)
            addon.settingsDesign.SetRegionColor(control.statsProText,
                not enabled and "textDisabled"
                    or ((hovered or pressed or control.statsProSelected) and "textPrimary"
                        or "textSecondary"))
        end
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

function addon.settingsDesign.OnControlHide(control)
    control.statsProHovered = false
    control.statsProPressed = false
    addon.settingsDesign.HideControlTooltip(control)
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
    control:HookScript("OnHide", addon.settingsDesign.OnControlHide)
    control:HookScript("OnEnable", addon.settingsDesign.RefreshControl)
    control:HookScript("OnDisable", addon.settingsDesign.OnControlDisabled)
end

function addon.settingsDesign.RefreshEnabledState(control)
    local blockers = control.statsProControlBlockers
    local blocked = type(blockers) == "table" and next(blockers) ~= nil
    local enabled = addon.settingsDesign.IsControlEnabled(control)
    if blocked and enabled then
        control:Disable()
    elseif not blocked and not enabled then
        control:Enable()
    end
    addon.settingsDesign.RefreshOwnedControlTooltip(control)
end

function addon.settingsDesign.SetControlBlocked(control, source, blocked, mode, key)
    if not control then return end
    control.statsProControlBlockers = control.statsProControlBlockers or {}
    local existing = control.statsProControlBlockers[source]
    if blocked then
        if type(existing) == "table" and existing.mode == mode and existing.key == key then
            return
        end
    elseif existing == nil then
        return
    end
    control.statsProControlBlockers[source] = blocked and { mode = mode, key = key } or nil
    addon.settingsDesign.RefreshEnabledState(control)
    if control.statsProSwatch then
        addon.settingsDesign.SetControlBlocked(
            control.statsProSwatch, source, blocked, mode, key)
    end
end

function addon.settingsDesign.RegisterMutationControl(control)
    if not control or control.statsProMutationRegistered == true then return false end
    control.statsProMutatesSettings = true
    control.statsProMutationRegistered = true
    addon.settingsDesign.mutationControls = addon.settingsDesign.mutationControls or {}
    tinsert(addon.settingsDesign.mutationControls, control)
    if control.statsProMutationTooltipAttached ~= true then
        addon.settingsDesign.AttachTooltip(control, addon.settingsDesign.ControlTextTooltip)
        control.statsProMutationTooltipAttached = true
    end
    return true
end

function addon.settingsDesign.UnregisterMutationControl(control)
    if not control or control.statsProMutationRegistered ~= true then return false end
    local controls = addon.settingsDesign.mutationControls or {}
    for index = #controls, 1, -1 do
        if rawequal(controls[index], control) then
            tremove(controls, index)
            control.statsProMutationRegistered = false
            return true
        end
    end
    control.statsProMutationRegistered = false
    return false
end

function addon.settingsDesign.RefreshMutationControls()
    addon.dbRuntime.Refresh()
    local schemaBlocked = addon.dbRuntime.readOnly == true
    local schemaReason = addon.dbRuntime.mode == "corrupt"
        and "Corrupted data - profiles are read-only. Use /ss wipe to reset."
        or "Compatibility mode - profiles are read-only."
    local contextBlocked = addon.profileRuntime.BlocksUserWrites() == true
    local combatBlocked = addon.hudPresets.CombatIsBlocked()
    for _, control in ipairs(addon.settingsDesign.mutationControls or {}) do
        addon.settingsDesign.SetControlBlocked(control, "schema", schemaBlocked,
            "message", schemaReason)
        addon.settingsDesign.SetControlBlocked(control, "context", contextBlocked,
            "message", "Waiting for a safe profile context.")
        addon.settingsDesign.SetControlBlocked(control, "combat",
            control.statsProBlocksInCombat == true and combatBlocked,
            "message", "Profile changes are unavailable during combat.")
    end
end

function addon.settingsDesign.SetControlEnabled(control, enabled, reasonKey)
    if not control then return end
    control.statsProDisabledReasonKey = enabled and nil or reasonKey
    addon.settingsDesign.SetControlBlocked(
        control, "dependency", not enabled, "requires", reasonKey)
end

function addon.settingsDesign.StyleCheckbox(control, text, nonMutating)
    local geometry = addon.settingsDesign.tokens.geometry
    control:SetSize(geometry.controlHitTarget, geometry.controlHitTarget)
    text:ClearAllPoints()
    text:SetPoint("LEFT", control, "RIGHT", geometry.checkboxLabelGap, 0)
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
    if nonMutating == true then
        addon.settingsDesign.AttachTooltip(control, addon.settingsDesign.ControlTextTooltip)
    else
        addon.settingsDesign.RegisterMutationControl(control)
    end
    addon.settingsDesign.HookControl(control)
    addon.settingsDesign.RefreshControl(control)
end

function addon.settingsDesign.SetSwatchColor(control, r, g, b)
    if control and control.statsProColorWell then
        control.statsProColorWell:SetColorTexture(r, g, b, 1)
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
    ---@type StatsProSliderThumb?
    local thumb = type(slider.GetThumbTexture) == "function"
        and slider:GetThumbTexture() or nil
    slider.statsProThumb = thumb
    if thumb then
        thumb:SetTexture("Interface\\Buttons\\WHITE8X8")
        thumb:SetSize(8, 14)
    end
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
    text:SetWidth(geometry.dropdownWidth - 16)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    text:SetMaxLines(1)
    -- The visible field is the control: remove the tiny arrow-only hit target and
    -- let users open the dropdown by clicking anywhere inside the bordered box.
    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", dropdown, "TOPLEFT", 16, -4)
    button:SetPoint("BOTTOMRIGHT", dropdown, "BOTTOMRIGHT", -8, 4)
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
        if texture then texture:SetAlpha(0) end
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

function addon.settingsDesign.StyleListRow(row, text, textRole)
    local state = row.statsProStateTexture or row.background
    if not state then
        state = row:CreateTexture(nil, "BACKGROUND")
        state:SetAllPoints(row)
    end
    -- Some boxed rows also own a permanent BACKGROUND surface. Without an
    -- explicit sublevel, WoW may draw this interactive fill underneath that
    -- surface, leaving only the text hover visible. Keep every list-row fill
    -- deterministically above base backgrounds and below BORDER/ARTWORK chrome.
    state:SetDrawLayer("BACKGROUND", 1)
    row.statsProStateTexture = state
    row.statsProText = text
    addon.settingsDesign.ApplyTextRole(text, textRole or "controlMetadata")
    addon.settingsDesign.RegisterControl(row, "listRow")
    addon.settingsDesign.HookControl(row)
    addon.settingsDesign.AttachTooltip(row, addon.settingsDesign.ControlTextTooltip)
    addon.settingsDesign.RefreshControl(row)
end

function addon.settingsDesign.SetListRowSelected(row, selected)
    row.statsProSelected = selected == true
    if row.statsProSelectionRail then
        if row.statsProSelected then row.statsProSelectionRail:Show()
        else row.statsProSelectionRail:Hide() end
    end
    addon.settingsDesign.RefreshControl(row)
end

function addon.settingsDesign.StyleWarning(parent, text)
    addon.settingsDesign.ApplyTextRole(text, "warning")
    local surface = addon.settingsDesign.CreateTextureSurface(parent, "raised")
    surface:SetPoint("TOPLEFT", text, "TOPLEFT", -8, 6)
    surface:SetPoint("BOTTOMRIGHT", text, "BOTTOMRIGHT", 8, -6)
    local rail = parent:CreateTexture(nil, "ARTWORK")
    rail:SetPoint("TOPLEFT", surface, "TOPLEFT", 0, 0)
    rail:SetPoint("BOTTOMLEFT", surface, "BOTTOMLEFT", 0, 0)
    rail:SetWidth(2)
    local color = addon.settingsDesign.Color("warning")
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

function addon.settingsDesign.ApplySeparator(texture)
    local color = addon.settingsDesign.Color("separator")
    texture:SetColorTexture(color[1], color[2], color[3], color[4])
    texture.statsProColorRole = "separator"
end

function addon.settingsDesign.StyleCloseButton(button)
    for _, texture in pairs({
        type(button.GetNormalTexture) == "function" and button:GetNormalTexture(),
        type(button.GetHighlightTexture) == "function" and button:GetHighlightTexture(),
        type(button.GetPushedTexture) == "function" and button:GetPushedTexture(),
        type(button.GetDisabledTexture) == "function" and button:GetDisabledTexture(),
    }) do
        if texture then texture:SetAlpha(0) end
    end
    button:SetSize(addon.settingsDesign.tokens.geometry.minHitTarget,
        addon.settingsDesign.tokens.geometry.minHitTarget)
    local hover = button:CreateTexture(nil, "BACKGROUND")
    hover:SetAllPoints(button)
    local danger = addon.settingsDesign.Color("danger")
    hover:SetColorTexture(danger[1], danger[2], danger[3], 0.14)
    hover:Hide()
    local text = button:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(text, 18, nil, "close")
    text:SetPoint("CENTER", 0, 1)
    text:SetText("×")
    addon.settingsDesign.SetRegionColor(text, "textSecondary")
    local function RefreshClose(control)
        if control.statsProCloseHovered then control.statsProCloseHover:Show()
        else control.statsProCloseHover:Hide() end
        addon.settingsDesign.SetRegionColor(control.statsProCloseText,
            control.statsProClosePressed and "textPrimary"
                or (control.statsProCloseHovered and "danger" or "textSecondary"))
    end
    button.statsProCloseHover = hover
    button.statsProCloseText = text
    button:SetScript("OnEnter", function(control)
        control.statsProCloseHovered = true
        RefreshClose(control)
    end)
    button:SetScript("OnLeave", function(control)
        control.statsProCloseHovered = false
        control.statsProClosePressed = false
        RefreshClose(control)
    end)
    button:SetScript("OnMouseDown", function(control)
        control.statsProClosePressed = true
        RefreshClose(control)
    end)
    button:SetScript("OnMouseUp", function(control)
        control.statsProClosePressed = false
        RefreshClose(control)
    end)
    button:HookScript("OnHide", function(control)
        control.statsProCloseHovered = false
        control.statsProClosePressed = false
        RefreshClose(control)
    end)
    button.statsProModernClose = true
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

function addon.settingsDesign.OnButtonHide(button)
    button.statsProHovered = false
    button.statsProPressed = false
    addon.settingsDesign.HideControlTooltip(button)
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
    button:HookScript("OnHide", addon.settingsDesign.OnButtonHide)
    button:HookScript("OnEnable", addon.settingsDesign.RefreshShellButton)
    button:HookScript("OnDisable", addon.settingsDesign.OnButtonDisabled)
    addon.settingsDesign.RegisterControl(button, "button")
    addon.settingsDesign.AttachTooltip(button, addon.settingsDesign.ControlTextTooltip)
    addon.settingsDesign.RefreshShellButton(button)
    return button
end

function addon.settingsDesign.DeveloperLinkTooltip(control)
    local link = addon.developerLinks[control.statsProLinkKey]
    if not link then return nil end
    return link.labelKey and L(link.labelKey) or link.label, L("Click to copy the link.")
end

function addon.settingsDesign.CreateDeveloperLinkButton(parent, name, linkKey,
        iconAsset, tint)
    local geometry = addon.settingsDesign.tokens.geometry
    local button = CreateFrame("Button", name, parent)
    button:SetSize(geometry.minHitTarget, geometry.minHitTarget)
    button.statsProLinkKey = linkKey

    local hover = button:CreateTexture(nil, "BACKGROUND")
    hover:SetAllPoints(button)
    local hoverColor = addon.settingsDesign.Color("hover")
    hover:SetColorTexture(hoverColor[1], hoverColor[2], hoverColor[3], hoverColor[4])
    hover:Hide()

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("CENTER", iconAsset.offsetX or 0, iconAsset.offsetY or 0)
    icon:SetSize(16, 16)
    if iconAsset.atlas then
        icon:SetAtlas(iconAsset.atlas)
    else
        icon:SetTexture(iconAsset.texture)
        if iconAsset.texCoords then icon:SetTexCoord(unpack(iconAsset.texCoords)) end
    end
    if tint then icon:SetVertexColor(tint[1], tint[2], tint[3], tint[4] or 1) end
    icon:SetAlpha(0.76)

    button.statsProHover = hover
    button.statsProIcon = icon
    button:SetScript("OnEnter", function(control)
        control.statsProHover:Show()
        control.statsProIcon:SetAlpha(1)
    end)
    button:SetScript("OnLeave", function(control)
        control.statsProHover:Hide()
        control.statsProIcon:SetAlpha(0.76)
    end)
    button:HookScript("OnHide", function(control)
        control.statsProHover:Hide()
        control.statsProIcon:SetAlpha(0.76)
    end)
    button:SetScript("OnClick", function(control)
        addon.developerLinks.Show(control.statsProLinkKey)
    end)
    addon.settingsDesign.RegisterControl(button, "developerLink")
    addon.settingsDesign.AttachTooltip(button, addon.settingsDesign.DeveloperLinkTooltip)
    return button
end

function addon.settingsDesign.RefreshTab(button)
    local selected = button.statsProSelected == true
    local pressed = button.statsProPressed == true
    local hovered = button.statsProHovered == true
    local fill = addon.settingsDesign.Color(pressed and "pressed"
        or (hovered and "hover" or (selected and "profile" or "transparent")))
    button.statsProFill:SetColorTexture(fill[1], fill[2], fill[3], fill[4])
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
    button:HookScript("OnHide", function(control)
        control.statsProHovered = nil
        control.statsProPressed = nil
        addon.settingsDesign.RefreshTab(control)
    end)
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
    if scrollFrame.statsProScrollbarStyled then return end
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
-- CursorSection: localized casing is preserved. A short accent rail plus a quiet
-- hairline carries hierarchy without another full-width card inside the viewport.
local function CursorSection(c, label)
    local band = CreateFrame("Frame", nil, c.parent)
    band:SetPoint("TOPLEFT", c.parent, "TOPLEFT", c.padX, c.y + 4)
    band:SetPoint("TOPRIGHT", c.parent, "TOPRIGHT", -c.padX, c.y + 4)
    band:SetHeight(addon.settingsDesign.tokens.geometry.sectionHeaderHeight)
    band:EnableMouse(false)
    band.statsProSurfaceRole = "section"
    local rail = band:CreateTexture(nil, "ARTWORK")
    rail:SetPoint("LEFT", 0, 0)
    rail:SetSize(2, 12)
    local accent = addon.settingsDesign.Color("accent")
    rail:SetColorTexture(accent[1], accent[2], accent[3], 0.92)
    local hdr = band:CreateFontString(nil, "OVERLAY")
    addon.settingsDesign.ApplyTextRole(hdr, "section")
    hdr:SetPoint("LEFT", rail, "RIGHT", 8, 0)
    hdr:SetJustifyH("LEFT")
    hdr:SetWordWrap(false)
    hdr:SetMaxLines(1)
    PushLocalizedLabel(function() hdr:SetText(L(label)) end)
    local line = band:CreateTexture(nil, "ARTWORK")
    line:SetPoint("LEFT", hdr, "RIGHT", 10, 0)
    line:SetPoint("RIGHT", band, "RIGHT", -2, 0)
    line:SetHeight(1)
    addon.settingsDesign.ApplySeparator(line)
    c.parent.statsProSections = c.parent.statsProSections or {}
    tinsert(c.parent.statsProSections, {
        key = label, surface = band, text = hdr, rail = rail, line = line, y = c.y,
    })
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

function addon.settingsDesign.RequestResponsiveFrameResize()
    if not addon.settingsUI.frame
        and type(addon.profileUI.ApplyManagerSize) ~= "function" then return end
    RunCoalesced("responsiveFrameSize", 0, function()
        if addon.settingsUI.frame then addon.settingsUI.ApplyFrameSize(addon) end
        local applyManager = addon.profileUI.ApplyManagerSize
        if type(applyManager) == "function" then applyManager() end
    end)
end

function addon.settingsDesign.ReadUIParentDimension(getterName)
    local getter = UIParent and UIParent[getterName]
    if type(getter) ~= "function" then return nil end
    local readOK, dimension = pcall(getter, UIParent)
    if not readOK then return nil end
    local secretOK, secret = pcall(issecretvalue, dimension)
    if not secretOK or secret or not IsFiniteNumber(dimension) or dimension <= 0 then
        return nil
    end
    return dimension
end

function addon.settingsDesign.ReadUIParentHeight()
    return addon.settingsDesign.ReadUIParentDimension("GetHeight")
end

function addon.settingsDesign.ReadUIParentWidth()
    return addon.settingsDesign.ReadUIParentDimension("GetWidth")
end

-- CreateConfigSlider: standard label-on-top + horizontal slider pattern used across
-- the Appearance tab. valueFmt is a string.format specifier (e.g. "%.1f", "%d") applied
-- to both initial display and live OnValueChanged updates. SetObeyStepOnDrag(true) +
-- step=1 guarantees integer values for "%d" sliders. cd cursor advances by 50.
local function CreateConfigSlider(parent, name, labelText, dbKey, cd, minVal, maxVal, step, lowText, highText, valueFmt, onChange)
    local sliderY = cd.y
    local lbl = parent:CreateFontString(nil, "OVERLAY")
    -- WoW rejects SetText on a bare FontString. Register before the localized
    -- setter runs; StyleSlider later reuses the same identity-keyed font entry.
    RegisterConfigFont(lbl, 12, nil, "role:body")
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

function addon.presetRuntime.ValuesEqual(left, right, seen)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    seen = seen or {}
    if seen[left] == right then return true end
    seen[left] = right
    for key, value in pairs(left) do
        if not addon.presetRuntime.ValuesEqual(value, right[key], seen) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

function addon.presetRuntime.Clone(value)
    local copied, ok = addon.dbRuntime.CloneSerializable(value)
    if not ok then return nil end
    return copied
end

function addon.presetRuntime.CapturePayload(service, settings)
    local payload = {}
    for key in pairs(service.allowlist) do
        local value
        if settings then value = rawget(settings, key) end
        if value == nil then value = defaults[key] end
        payload[key] = value
    end
    return addon.presetRuntime.Clone(payload)
end

function addon.presetRuntime.ResolveValue(key, persisted)
    for _, service in ipairs(addon.presetRuntime.services) do
        local session = service.session
        if session and service.allowlist[key]
            and session.candidate and session.candidate[key] ~= nil then
            return session.candidate[key]
        end
    end
    return persisted
end

addon.appearancePresets.markerKey = "appearancePresetID"
function addon.appearancePresets.BuildCandidate(definition)
    local candidate = addon.presetRuntime.Clone(definition)
    if candidate then candidate.label = nil end
    return candidate
end

function addon.appearancePresets.CurrentID(settings)
    settings = settings or addon.dbRuntime.GetActiveSettings()
    local marker = settings and rawget(settings, "appearancePresetID") or nil
    local definition = addon.appearancePresets.definitions[marker]
    if not definition then return "custom" end
    local payload = addon.presetRuntime.CapturePayload(addon.appearancePresets, settings)
    local expected = addon.appearancePresets.BuildCandidate(definition)
    if payload and expected and addon.presetRuntime.ValuesEqual(payload, expected) then
        return marker
    end
    return "custom"
end

function addon.appearancePresets.MarkCustom(settings)
    settings = settings or addon.dbRuntime.GetWritableSettings(false)
    if not settings or rawget(settings, "appearancePresetID") == "custom" then
        return false
    end
    settings.appearancePresetID = "custom"
    addon.appearancePresets.RefreshUI()
    return true
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

function addon.presetRuntime.RestoreCommittedRuntime(service)
    local session = service.session
    service.session = nil
    if service.ApplyRuntime() then return true end
    service.session = session
    service.ApplyRuntime()
    return false
end

function addon.presetRuntime.SessionIsCurrent(service, session, ignoreGeneration)
    if not session or type(session.expected) ~= "table" then return false end
    local root = addon.dbRuntime.Refresh()
    if not addon.profileOps.CheckExpected(root, session.expected, ignoreGeneration) then
        return false
    end
    local profile = root.profiles and root.profiles[session.profileID]
    if not profile or not addon.dbRuntime.IsCleanTable(profile.settings) then return false end
    local payload = addon.presetRuntime.CapturePayload(service, profile.settings)
    if not payload or not addon.presetRuntime.ValuesEqual(payload, session.baseline) then
        return false
    end
    return not service.markerKey
        or rawget(profile.settings, service.markerKey) == session.baselineMarker
end

function addon.presetRuntime.CancelPreview(service, silent)
    if not service.session then return false end
    if not addon.presetRuntime.RestoreCommittedRuntime(service) then
        service.RefreshUI()
        return false, "restore-failed"
    end
    if silent then service.RefreshUI() else addon.profileUI.RefreshSafe() end
    return true
end

function addon.presetRuntime.CancelOther(service)
    for _, other in ipairs(addon.presetRuntime.services) do
        if not rawequal(other, service) and other.session then
            local restored, reason = other.CancelPreview(true)
            if not restored then return false, reason end
        end
    end
    return true
end

function addon.presetRuntime.CancelAllPreviews(silent)
    for _, service in ipairs(addon.presetRuntime.services) do
        if service.session then
            local restored, reason = service.CancelPreview(silent)
            if not restored then return false, reason end
        end
    end
    return true
end

function addon.presetRuntime.StartPreview(service, presetID)
    local definition = service.definitions[presetID]
    if not definition then return false, "invalid-preset" end
    local restored, restoreReason = addon.presetRuntime.CancelOther(service)
    if not restored then return false, restoreReason end
    if service.session and service.session.presetID == presetID then
        return false, "no-change"
    end
    local currentID = service.CurrentID()
    if service.session and currentID == presetID then
        local cancelled, reason = service.CancelPreview()
        return cancelled, cancelled and "cancelled" or reason
    end
    if not service.session and currentID == presetID then return false, "no-change" end
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
    local candidate = service.BuildCandidate(definition)
    local baseline = addon.presetRuntime.CapturePayload(service, profile.settings)
    if not candidate or not baseline then return false, "clone-failed" end
    service.session = {
        presetID = presetID,
        candidate = candidate,
        baseline = baseline,
        expected = addon.profileUI.CaptureExpected(nil, nil, profileID),
        profileID = profileID,
        baselineMarker = service.markerKey
            and rawget(profile.settings, service.markerKey) or nil,
    }
    service.session.expected.settingsRef = profile.settings
    if not service.ApplyRuntime() then
        local runtimeRestored = addon.presetRuntime.RestoreCommittedRuntime(service)
        service.RefreshUI()
        return false, runtimeRestored and "preview-failed" or "restore-failed"
    end
    addon.profileUI.RefreshSafe()
    return true
end

function addon.presetRuntime.ApplyPreview(service)
    local session = service.session
    if not session then return false, "no-preview" end
    if not addon.presetRuntime.SessionIsCurrent(service, session) then
        local cancelled, reason = service.CancelPreview(true)
        return false, cancelled and "stale" or reason
    end
    local presetID, profileID = session.presetID, session.profileID
    local candidate = addon.presetRuntime.Clone(session.candidate)
    local expected = session.expected
    if not candidate then return false, "clone-failed" end
    if not addon.presetRuntime.RestoreCommittedRuntime(service) then
        service.RefreshUI()
        return false, "restore-failed"
    end
    local ok, result = addon.profileOps.Execute(expected, function(root)
        local profile = root.profiles[profileID]
        if not profile or not addon.dbRuntime.IsCleanTable(profile.settings) then
            return nil, "missing-profile"
        end
        local settings = addon.presetRuntime.Clone(profile.settings)
        if not settings then return nil, "clone-failed" end
        for key in pairs(service.allowlist) do
            settings[key] = candidate[key]
        end
        if service.markerKey then settings[service.markerKey] = presetID end
        local changedProfile = addon.profileRuntime.ShallowCopy(profile)
        changedProfile.settings = settings
        local profiles = addon.profileRuntime.ShallowCopy(root.profiles)
        profiles[profileID] = changedProfile
        local transaction = addon.profileOps.NewTransaction(root)
        transaction.profiles = profiles
        return transaction, profileID
    end)
    local retryable = result == "validate-failed" or result == "commit-failed"
        or result == "apply-failed"
    if not ok and retryable
        and addon.presetRuntime.SessionIsCurrent(service, session, true) then
        -- Rollback restored every identity checked above; only the DB generation
        -- changed. Do not re-read and silently adopt a different transaction graph.
        session.expected.generation = addon.dbRuntime.generation
        service.session = session
        if service.session and not service.ApplyRuntime() then
            service.ForceCancelPreview()
            result = "preview-resume-failed"
        end
    end
    service.RefreshUI()
    return ok, result
end

function addon.presetRuntime.BeforeManualEdit(service, key)
    if service.allowlist[key] and service.session then
        return service.CancelPreview(true) == true
    end
    return true
end

function addon.presetRuntime.ForceCancelPreview(service)
    if not service.session then return true end
    service.session = nil
    if service.ApplyRuntime() then
        service.RefreshUI()
        return true
    end
    -- A close/combat transition cannot leave a hidden retry UI with candidate
    -- overrides active. Retry committed runtime once, then hand recovery to the
    -- existing profile reapply coordinator if the client boundary is still unsafe.
    if service.ApplyRuntime() then
        service.RefreshUI()
        return true
    end
    addon.profileRuntime.forceReapply = true
    addon.profileRuntime.forceReapplyRetryCount = 0
    addon.profileRuntime.pendingResolution = true
    addon.profileRuntime.RequestResolution(false)
    service.RefreshUI()
    return false
end

function addon.presetRuntime.ForceCancelAllPreviews()
    local restored = true
    for _, service in ipairs(addon.presetRuntime.services) do
        if not addon.presetRuntime.ForceCancelPreview(service) then restored = false end
    end
    return restored
end

function addon.presetRuntime.ReportStartResult(ok, reason)
    if not ok and reason ~= "no-change" and reason ~= "cancelled" then
        PrintMsg(addon.profileUI.OperationErrorText(reason))
    end
    return ok, reason
end

function addon.appearancePresets.RefreshUI()
    local ui = addon.appearancePresets.ui
    if not ui then return end
    local session = addon.appearancePresets.session
    local displayID = session and session.presetID
        or addon.appearancePresets.CurrentID()
    local definition = addon.appearancePresets.definitions[displayID]
    local displayLabel = definition and L(definition.label) or L("Custom")
    if session then
        ui.status:SetText(string.format(L("Previewing: %s"), displayLabel))
    else
        ui.status:SetText(L("Preset:") .. " " .. displayLabel)
    end
    for presetID, button in pairs(ui.buttons) do
        addon.settingsDesign.SetListRowSelected(button, presetID == displayID)
    end
    local warningVisible = false
    if session then
        ui.apply:Show()
        ui.cancel:Show()
        local root = addon.dbRuntime.Refresh()
        local counts = addon.profileOps.CountReferences(root,
            addon.dbRuntime.activeProfileID)
        if counts.total > 1 then
            warningVisible = true
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
    if ui.refreshLayout then
        ui.refreshLayout(session ~= nil, warningVisible)
    end
end

function addon.appearancePresets.CancelPreview(silent)
    return addon.presetRuntime.CancelPreview(addon.appearancePresets, silent)
end

function addon.appearancePresets.StartPreview(presetID)
    return addon.presetRuntime.StartPreview(addon.appearancePresets, presetID)
end

function addon.appearancePresets.ApplyPreview()
    return addon.presetRuntime.ApplyPreview(addon.appearancePresets)
end

function addon.appearancePresets.BeforeManualEdit(key)
    return addon.presetRuntime.BeforeManualEdit(addon.appearancePresets, key)
end

function addon.appearancePresets.ForceCancelPreview()
    return addon.presetRuntime.ForceCancelPreview(addon.appearancePresets)
end

function addon.hudPresets.BuildCandidate(definition)
    return addon.presetRuntime.Clone(definition.values)
end

function addon.hudPresets.CombatIsBlocked()
    if type(addon.hudPresets.combatState) == "boolean" then
        return addon.hudPresets.combatState
    end
    return addon.profileRuntime.ReadCombatState() ~= false
end

function addon.hudPresets.CurrentID(settings)
    settings = settings or addon.dbRuntime.GetActiveSettings()
    local payload = addon.presetRuntime.CapturePayload(addon.hudPresets, settings)
    if not payload then return "custom" end
    for _, presetID in ipairs(addon.hudPresets.order) do
        local definition = addon.hudPresets.definitions[presetID]
        if definition and addon.presetRuntime.ValuesEqual(
            payload, definition.values) then
            return presetID
        end
    end
    return "custom"
end

function addon.hudPresets.ApplyRuntime()
    if (addon.hudPresets.testRuntimeFailureCount or 0) > 0 then
        addon.hudPresets.testRuntimeFailureCount =
            addon.hudPresets.testRuntimeFailureCount - 1
        return false
    end
    CacheSettings()
    ReflowAllPanels()
    addon.durabilityRuntime.MarkDirty()
    addon.itemLevelRuntime.MarkDirty()
    if addon.panelEditRuntime.Refresh then addon.panelEditRuntime.Refresh() end
    if type(addon.profileRuntime.RefreshConfigControls) == "function" then
        addon.profileRuntime.RefreshConfigControls()
    end
    return addon:RunUpdateStatsSafe()
end

function addon.hudPresets.RefreshUI()
    if #addon.hudPresets.views == 0 then return end
    local session = addon.hudPresets.session
    local displayID = session and session.presetID or addon.hudPresets.CurrentID()
    local definition = addon.hudPresets.definitions[displayID]
    local displayLabel = definition and L(definition.label) or L("Custom")
    local warningVisible = false
    local sharedCounts
    if session then
        local root = addon.dbRuntime.Refresh()
        sharedCounts = addon.profileOps.CountReferences(root,
            addon.dbRuntime.activeProfileID)
        if sharedCounts.total > 1 then
            warningVisible = true
        end
    end
    for _, ui in ipairs(addon.hudPresets.views) do
        if session then
            ui.status:SetText(string.format(L("Previewing: %s"), displayLabel))
        else
            ui.status:SetText(string.format(L("Current setup: %s"), displayLabel))
        end
        for presetID, button in pairs(ui.buttons) do
            addon.settingsDesign.SetListRowSelected(button, presetID == displayID)
        end
        if session and warningVisible then
            ui.warning:SetText(string.format(L(
                "This profile is shared by %d specs and %d other references. Applying changes all of them."),
                sharedCounts.specs, sharedCounts.total - sharedCounts.specs))
            addon.settingsDesign.SetWarningVisible(ui.warning, true)
        else
            ui.warning:SetText("")
            addon.settingsDesign.SetWarningVisible(ui.warning, false)
        end
        if ui.alwaysShowActions or session then
            ui.apply:Show()
            ui.cancel:Show()
        else
            ui.apply:Hide()
            ui.cancel:Hide()
        end
        if ui.refreshLayout then
            ui.refreshLayout(session ~= nil, warningVisible)
        end
    end
end

function addon.hudPresets.RegisterView(ui)
    if type(ui) ~= "table" or ui.statsProRegistered == true then return false end
    ui.statsProRegistered = true
    addon.hudPresets.views[#addon.hudPresets.views + 1] = ui
    addon.hudPresets.RefreshUI()
    return true
end

function addon.hudPresets.UnregisterView(ui)
    if type(ui) ~= "table" or ui.statsProRegistered ~= true then return false end
    for index = #addon.hudPresets.views, 1, -1 do
        if rawequal(addon.hudPresets.views[index], ui) then
            tremove(addon.hudPresets.views, index)
            ui.statsProRegistered = false
            return true
        end
    end
    ui.statsProRegistered = false
    return false
end

function addon.hudPresets.CancelPreview(silent)
    return addon.presetRuntime.CancelPreview(addon.hudPresets, silent)
end

function addon.hudPresets.StartPreview(presetID)
    return addon.presetRuntime.StartPreview(addon.hudPresets, presetID)
end

function addon.hudPresets.ApplyPreview()
    return addon.presetRuntime.ApplyPreview(addon.hudPresets)
end

function addon.hudPresets.BeforeManualEdit(key)
    return addon.presetRuntime.BeforeManualEdit(addon.hudPresets, key)
end

function addon.hudPresets.ForceCancelPreview()
    return addon.presetRuntime.ForceCancelPreview(addon.hudPresets)
end

function addon.hudPresets.BuildCardList(parent, x, y, width)
    local ui = { buttons = {}, mutationControls = {} }
    local status = parent:CreateFontString(nil, "OVERLAY")
    addon.settingsDesign.ApplyTextRole(status, "body")
    status:SetPoint("TOPLEFT", x, y)
    status:SetSize(width, 20)
    status:SetJustifyH("LEFT")
    ui.status = status
    y = y - 24

    local intro = parent:CreateFontString(nil, "OVERLAY")
    addon.settingsDesign.ApplyTextRole(intro, "metadata")
    intro:SetPoint("TOPLEFT", x, y)
    intro:SetSize(width, 28)
    intro:SetJustifyH("LEFT")
    intro:SetJustifyV("TOP")
    intro:SetWordWrap(true)
    PushLocalizedLabel(function()
        intro:SetText(L("Choose a finished HUD layout. Click a card to preview it."))
    end)
    ui.intro = intro
    y = y - 34

    for _, presetID in ipairs(addon.hudPresets.order) do
        local definition = addon.hudPresets.definitions[presetID]
        local button = CreateFrame("Button", "StatsProHUDPreset"
            .. presetID:gsub("[^%w]", "") .. (parent:GetName() or "View"),
            parent)
        button:SetPoint("TOPLEFT", x, y)
        button:SetSize(width, 50)
        local baseSurface = addon.settingsDesign.CreateTextureSurface(button, "raised")
        baseSurface:SetAllPoints(button)
        button.statsProSurface = baseSurface
        local selectionRail = button:CreateTexture(nil, "ARTWORK")
        selectionRail:SetPoint("TOPLEFT", 0, -4)
        selectionRail:SetPoint("BOTTOMLEFT", 0, 4)
        selectionRail:SetWidth(2)
        local selectionColor = addon.settingsDesign.Color("accent")
        selectionRail:SetColorTexture(
            selectionColor[1], selectionColor[2], selectionColor[3], selectionColor[4])
        selectionRail:Hide()
        button.statsProSelectionRail = selectionRail

        local label = button:CreateFontString(nil, "OVERLAY")
        addon.settingsDesign.StyleListRow(button, label, "button")
        label:SetPoint("TOPLEFT", 12, -8)
        label:SetSize(width - 24, 16)
        label:SetJustifyH("LEFT")
        label:SetWordWrap(false)
        label:SetMaxLines(1)
        PushLocalizedLabel(function() label:SetText(L(definition.label)) end)

        local summary = button:CreateFontString(nil, "OVERLAY")
        addon.settingsDesign.ApplyTextRole(summary, "metadata")
        summary:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -3)
        summary:SetSize(width - 24, 14)
        summary:SetJustifyH("LEFT")
        summary:SetWordWrap(false)
        summary:SetMaxLines(1)
        PushLocalizedLabel(function() summary:SetText(L(definition.summary)) end)

        button.statsProPresetSummary = summary
        button.statsProBlocksInCombat = true
        addon.settingsDesign.RegisterMutationControl(button)
        ui.mutationControls[#ui.mutationControls + 1] = button
        button:SetScript("OnClick", function()
            local ok, reason = addon.hudPresets.StartPreview(presetID)
            addon.presetRuntime.ReportStartResult(ok, reason)
        end)
        ui.buttons[presetID] = button
        y = y - 56
    end

    local note = parent:CreateFontString(nil, "OVERLAY")
    addon.settingsDesign.ApplyTextRole(note, "metadata")
    note:SetPoint("TOPLEFT", x, y)
    note:SetSize(width, 40)
    note:SetJustifyH("LEFT")
    note:SetJustifyV("TOP")
    note:SetWordWrap(true)
    PushLocalizedLabel(function()
        note:SetText(L("Stat rows, value display, durability summary, and panel layout can change. Appearance, scale, positions, language, and profile assignments stay unchanged."))
    end)
    ui.note = note
    y = y - 46

    local warning = parent:CreateFontString(nil, "OVERLAY")
    warning:SetPoint("TOPLEFT", x, y)
    warning:SetSize(width, 36)
    warning:SetJustifyH("LEFT")
    warning:SetJustifyV("TOP")
    warning:SetWordWrap(true)
    addon.settingsDesign.StyleWarning(parent, warning)
    addon.settingsDesign.SetWarningVisible(warning, false)
    ui.warning = warning
    ui.warningY = y
    ui.compactBodyTop = y
    return ui
end

function addon.hudPresets.MarkWelcomeSeen()
    local root = addon.dbRuntime.GetWritableRoot(false)
    local account = root and rawget(root, "account") or nil
    if not addon.dbRuntime.IsCleanTable(account) then
        -- A spec/context transition blocks every normal write briefly. Remember a
        -- deliberate dismissal, but never bypass future-schema/corrupt read-only mode.
        if not addon.dbRuntime.readOnly
            and addon.profileRuntime.BlocksUserWrites() then
            addon.hudPresets.welcomeSeenPending = true
        end
        return false
    end
    account.quickSetupSeen = true
    addon.hudPresets.welcomeSeenPending = nil
    return true
end

function addon.hudPresets.FlushPendingWelcomeSeen()
    if addon.hudPresets.welcomeSeenPending ~= true
        or addon.profileRuntime.BlocksUserWrites() then return false end
    return addon.hudPresets.MarkWelcomeSeen()
end

function addon.hudPresets.SuspendWelcomeForCombat()
    local frame = addon.hudPresets.welcome
    if not frame or not frame:IsShown() then return false end
    -- Combat temporarily owns the screen, but it is not a user dismissal. Preserve
    -- the first-install marker so MaybeShowWelcome can restore the choice afterward.
    frame.statsProCombatSuspend = true
    frame:Hide()
    frame.statsProCombatSuspend = nil
    return true
end

function addon.hudPresets.BuildWelcome()
    if addon.hudPresets.welcome then return addon.hudPresets.welcome end
    local frame = CreateFrame("Frame", "StatsProQuickSetupWelcome", UIParent,
        "BackdropTemplate")
    frame:SetSize(470, 438)
    frame:SetPoint("CENTER")
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("DIALOG")
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    addon.settingsDesign.ApplySurface(frame, "window")
    frame:Hide()

    local titleSurface = addon.settingsDesign.CreateTextureSurface(frame, "raised")
    titleSurface:SetPoint("TOPLEFT", 6, -6)
    titleSurface:SetPoint("TOPRIGHT", -6, -6)
    titleSurface:SetHeight(42)

    local title = frame:CreateFontString(nil, "OVERLAY")
    addon.settingsDesign.ApplyTextRole(title, "title")
    title:SetPoint("LEFT", titleSurface, "LEFT", 14, 0)
    title:SetText("StatsPro")
    addon.settingsDesign.SetRegionColor(title, "accent")

    local metadata = frame:CreateFontString(nil, "OVERLAY")
    addon.settingsDesign.ApplyTextRole(metadata, "metadata")
    metadata:SetPoint("LEFT", title, "RIGHT", 8, 0)
    PushLocalizedLabel(function() metadata:SetText(L("Quick Setup")) end)

    local closeX = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeX:SetPoint("TOPRIGHT", -5, -5)
    addon.settingsDesign.StyleCloseButton(closeX)

    local ui = addon.hudPresets.BuildCardList(frame, 22, -62, 426)
    ui.alwaysShowActions = true
    PushLocalizedLabel(function()
        ui.note:SetText(L("This sets up the current profile. Appearance, scale, positions, language, and profile assignments stay unchanged."))
    end)
    local cancel = addon.settingsDesign.CreateShellButton(frame, nil, "field")
    cancel:SetSize(188, 28)
    PushLocalizedLabel(function() cancel:SetText(L("Open Settings")) end)
    cancel:SetScript("OnClick", function() addon:OpenConfigMenu() end)
    ui.cancel = cancel

    local apply = addon.settingsDesign.CreateShellButton(frame, nil, "primary")
    apply:SetSize(188, 28)
    PushLocalizedLabel(function() apply:SetText(L("Use this setup")) end)
    apply.statsProBlocksInCombat = true
    addon.settingsDesign.RegisterMutationControl(apply)
    ui.mutationControls[#ui.mutationControls + 1] = apply
    apply:SetScript("OnClick", function()
        if addon.hudPresets.session then
            local ok, reason = addon.hudPresets.ApplyPreview()
            if not ok then
                PrintMsg(addon.profileUI.OperationErrorText(reason))
                return
            end
        end
        if addon.hudPresets.MarkWelcomeSeen() then frame:Hide() end
    end)
    ui.apply = apply
    ui.refreshLayout = function(_, warningVisible)
        local actionY = ui.warningY - (warningVisible and 42 or 0)
        cancel:ClearAllPoints()
        cancel:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -220, actionY)
        apply:ClearAllPoints()
        apply:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -22, actionY)
    end

    frame:HookScript("OnShow", function()
        addon.profileUI.PushSpecialFrame("StatsProQuickSetupWelcome")
        for _, control in ipairs(ui.mutationControls) do
            addon.settingsDesign.RegisterMutationControl(control)
        end
        addon.hudPresets.RegisterView(ui)
        addon.settingsDesign.RefreshMutationControls()
    end)
    frame:HookScript("OnHide", function()
        addon.profileUI.RemoveSpecialFrame("StatsProQuickSetupWelcome")
        addon.hudPresets.UnregisterView(ui)
        for _, control in ipairs(ui.mutationControls) do
            addon.settingsDesign.UnregisterMutationControl(control)
        end
        if frame.statsProSettingsHandoff or frame.statsProCombatSuspend then return end
        addon.hudPresets.MarkWelcomeSeen()
        addon.hudPresets.ForceCancelPreview()
    end)
    if addon.__statsproSmoke == true then frame.statsProView = ui end
    addon.hudPresets.welcome = frame
    return frame
end

function addon.hudPresets.MaybeShowWelcome()
    if addon.__statsproSmoke == true and addon.__testWelcomeEnabled ~= true then
        return false
    end
    if addon.hudPresets.CombatIsBlocked() then return false end
    local root = addon.dbRuntime.Refresh()
    local account = root and rawget(root, "account") or nil
    if not addon.dbRuntime.IsCleanTable(account)
        or rawget(account, "quickSetupSeen") ~= false then return false end
    if addon.hudPresets.settingsDiscovered == true then
        addon.hudPresets.MarkWelcomeSeen()
        return false
    end
    local settingsFrame = addon.settingsUI.frame
    if settingsFrame and settingsFrame:IsShown() then
        addon.hudPresets.MarkWelcomeSeen()
        return false
    end
    local frame = addon.hudPresets.BuildWelcome()
    frame:Show()
    return true
end

-- /ss reset uses the same confirmed, transactional active-profile operation as the
-- advanced profile manager. The implementation lives on addon.resetRuntime to avoid another broad
-- closure in this near-limit Lua 5.1 chunk.
local function ResetToDefaults()
    return addon.resetRuntime.Request()
end

function addon.profileRuntime.CancelOwnedMutationPopups()
    for _, runtime in ipairs({
        addon.legacyImport, addon.resetRuntime, addon.wipeRuntime,
    }) do
        local pending = runtime.pending
        if pending then
            -- WHY: invalidate ownership before StaticPopup_Hide synchronously invokes
            -- OnCancel. Old accept/cancel callbacks can never consume a newer record.
            runtime.pending = nil
            runtime.hideRetry = true
        end
        if runtime.hideRetry and type(_G.StaticPopup_Hide) == "function" then
            local hidden = pcall(_G.StaticPopup_Hide, runtime.popupKey)
            if hidden then runtime.hideRetry = false end
        end
    end
end

function addon.profileRuntime.CloseOwnedDropdownMenus()
    local openMenu = _G.UIDROPDOWNMENU_OPEN_MENU
    local menuName
    if openMenu and type(openMenu.GetName) == "function" then
        local ok, value = pcall(openMenu.GetName, openMenu)
        if ok and addon.dbRuntime.IsCleanType(value, "string") then menuName = value end
    end
    if not menuName or not menuName:match("^StatsPro") then return false end
    CloseDropDownMenus()
    return true
end

addon.profileRuntime.closeOwnedSettingsModals = function()
    -- Destructive prompts are invalidated first. A later preview/modal restore
    -- failure must not leave an old confirmation capable of committing.
    addon.profileRuntime.CancelOwnedMutationPopups()
    if not addon.presetRuntime.CancelAllPreviews(true) then
        error("preset preview restore failed")
    end
    if type(addon.profileUI.CloseOperationDialog) == "function" then
        addon.profileUI.CloseOperationDialog()
    end
    local localization = addon.settingsUI.localization
    if type(localization.CancelPreview) == "function" then
        localization.CancelPreview(addon)
    end
    addon.profileRuntime.CloseOwnedDropdownMenus()
    local picker = addon.settingsUI.fontPicker
    if picker.frame and picker.frame:IsShown() then
        -- OnHide owns the forced restore. Calling cancel first would apply and
        -- reflow the committed font twice for every modal close.
        picker.Hide(addon)
    elseif type(picker.CancelPreview) == "function" then
        picker.CancelPreview(addon)
    end
    COLOR_PICKER_STATE.Close()
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
    if addon.panelEditRuntime.Refresh then addon.panelEditRuntime.Refresh() end
    SetAllPanelsScale(GetNumberDB("scale"))
    addon.durabilityRuntime.MarkDirty()
    addon.itemLevelRuntime.MarkDirty()
    -- Keep clean Archon comparisons across same-context profile/style applies.
    -- ActivateComparisonContext, GetCachedComparison, and PLAYER_LEVEL_CHANGED already
    -- invalidate every semantic boundary (class, spec, snapshot, target, rating type,
    -- capture date, or effective level). Clearing here discarded Mastery's safe cached
    -- Target percentage after an otherwise unrelated profile/style reapply.

    addon.profileRuntime.RefreshConfigControls()
    timeSinceLastUpdate = 0
    if not addon:RunUpdateStatsSafe() then error("profile render failed") end
    addon.profileRuntime.applyCount = addon.profileRuntime.applyCount + 1
end

function addon.legacyImport.AcceptPending(_, popupData)
    local pending = addon.legacyImport.pending
    if not pending or not rawequal(pending, popupData) then return end
    addon.legacyImport.pending = nil
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

function addon.legacyImport.CancelPending(_, popupData)
    if not rawequal(addon.legacyImport.pending, popupData) then return false end
    addon.legacyImport.pending = nil
    return true
end

_G.StaticPopupDialogs[addon.developerLinks.popupKey] = {
    text = "%s",
    button1 = "",
    hasEditBox = true,
    editBoxWidth = 340,
    OnShow = function(self, data)
        if type(data) ~= "table" or addon.developerLinks[data.key] ~= data then
            self:Hide()
            return
        end
        local editBox = self:GetEditBox()
        editBox:SetText(data.url)
        editBox:HighlightText()
        editBox:SetFocus()
    end,
    EditBoxOnEnterPressed = function(editBox)
        editBox:GetParent():Hide()
    end,
    EditBoxOnEscapePressed = function(editBox)
        editBox:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    exclusive = true,
    preferredIndex = 3,
}

function addon.developerLinks.Show(linkKey)
    local link = addon.developerLinks[linkKey]
    if type(link) ~= "table" or type(link.url) ~= "string" then return false end
    local label = link.labelKey and L(link.labelKey) or link.label
    if type(label) ~= "string" then return false end
    local definition = _G.StaticPopupDialogs[addon.developerLinks.popupKey]
    definition.button1 = L("Close")
    pcall(_G.StaticPopup_Hide, addon.developerLinks.popupKey)
    local message = "StatsPro — " .. label .. "\n"
        .. L("Copy the link below (Ctrl+C).")
    local ok, popup = pcall(_G.StaticPopup_Show,
        addon.developerLinks.popupKey, message, nil, link)
    return ok and popup ~= nil
end

_G.StaticPopupDialogs[addon.legacyImport.popupKey] = {
    text = "",
    button1 = "",
    button2 = "",
    OnAccept = addon.legacyImport.AcceptPending,
    OnCancel = addon.legacyImport.CancelPending,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    exclusive = true,
    preferredIndex = 3,
}

function addon.legacyImport.Request()
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
    local definition = _G.StaticPopupDialogs[addon.legacyImport.popupKey]
    definition.text = L("Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged.")
    definition.button1 = L("Import")
    definition.button2 = L("Cancel")
    local ok, popup = pcall(_G.StaticPopup_Show,
        addon.legacyImport.popupKey, nil, nil, addon.legacyImport.pending)
    if not ok or not popup then
        addon.legacyImport.pending = nil
        PrintMsg(L("SwiftStats import failed; profiles and assignments were preserved."))
    end
end

function addon.resetRuntime.AcceptPending(_, popupData)
    local pending = addon.resetRuntime.pending
    if not pending or not rawequal(pending, popupData) then return end
    addon.resetRuntime.pending = nil
    local ok, result = addon.profileOps.ResetProfile(
        pending.profileID, pending.expected)
    if ok then
        PrintMsg(L("Settings reset to defaults"))
    else
        PrintMsg(addon.profileUI.OperationErrorText(result))
    end
end

function addon.resetRuntime.CancelPending(_, popupData)
    if not rawequal(addon.resetRuntime.pending, popupData) then return false end
    addon.resetRuntime.pending = nil
    return true
end

_G.StaticPopupDialogs[addon.resetRuntime.popupKey] = {
    text = "",
    button1 = "",
    button2 = "",
    OnAccept = addon.resetRuntime.AcceptPending,
    OnCancel = addon.resetRuntime.CancelPending,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    exclusive = true,
    preferredIndex = 3,
}

function addon.resetRuntime.Request()
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
    local definition = _G.StaticPopupDialogs[addon.resetRuntime.popupKey]
    definition.text = string.format(
        L("Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."),
        profile.name, references.specs, otherReferences)
    definition.button1 = L("Confirm")
    definition.button2 = L("Cancel")
    local ok, popup = pcall(_G.StaticPopup_Show,
        addon.resetRuntime.popupKey, nil, nil, addon.resetRuntime.pending)
    if not ok or not popup then
        addon.resetRuntime.pending = nil
        PrintMsg(addon.profileUI.OperationErrorText("open-failed"))
        return false
    end
    return true
end

function addon.wipeRuntime.AcceptPending(_, popupData)
    local pending = addon.wipeRuntime.pending
    if not pending or not rawequal(pending, popupData) then return end
    addon.wipeRuntime.pending = nil
    local ok, result
    if pending.corruptRecovery then
        ok, result = addon.profileOps.RecoverCorruptRoot(pending.expected)
    else
        ok, result = addon.profileOps.FullWipe(pending.expected)
    end
    if ok then
        PrintMsg(L("All StatsPro data reset to defaults."))
    else
        PrintMsg(addon.profileUI.OperationErrorText(result))
    end
end

function addon.wipeRuntime.CancelPending(_, popupData)
    if not rawequal(addon.wipeRuntime.pending, popupData) then return false end
    addon.wipeRuntime.pending = nil
    return true
end

_G.StaticPopupDialogs[addon.wipeRuntime.popupKey] = {
    text = "",
    button1 = "",
    button2 = "",
    OnAccept = addon.wipeRuntime.AcceptPending,
    OnCancel = addon.wipeRuntime.CancelPending,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    exclusive = true,
    preferredIndex = 3,
}

function addon.wipeRuntime.Request()
    if not addon.profileRuntime.CloseOwnedSettingsModals() then return false end
    local root = addon.dbRuntime.Refresh()
    local prompt
    if addon.dbRuntime.mode == "corrupt" then
        local combat = addon.profileRuntime.ReadCombatState()
        if combat ~= false then
            PrintMsg(addon.profileUI.OperationErrorText(
                combat == true and "combat" or "unsafe-context"))
            return false
        end
        addon.wipeRuntime.pending = {
            corruptRecovery = true,
            expected = {
                rootRef = root,
                generation = addon.dbRuntime.generation,
            },
        }
        prompt = L("Reset corrupted StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position.")
    else
        local gateReason
        root, gateReason = addon.profileOps.Gate(nil, false)
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
        prompt = L("Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged.")
    end
    local definition = _G.StaticPopupDialogs[addon.wipeRuntime.popupKey]
    definition.text = prompt
    definition.button1 = L("Confirm")
    definition.button2 = L("Cancel")
    local ok, popup = pcall(_G.StaticPopup_Show,
        addon.wipeRuntime.popupKey, nil, nil, addon.wipeRuntime.pending)
    if not ok or not popup then
        addon.wipeRuntime.pending = nil
        PrintMsg(addon.profileUI.OperationErrorText("open-failed"))
        return false
    end
    return true
end

function addon.archonTargets.GetTargetSnapshotDropdownValue()
    return addon.archonTargets.ResolveAvailableSnapshotKey(GetDB("targetSnapshot"))
end

function addon.archonTargets.SelectTargetSnapshotDropdownValue(value, opt, dropdown)
    local db = addon.dbRuntime.GetWritableSettings(true)
    if not db then
        CloseDropDownMenus()
        return false
    end
    db.targetSnapshot = addon.archonTargets.ResolveAvailableSnapshotKey(value)
    CacheSettings()
    UIDropDownMenu_SetText(dropdown,
        addon.settingsUI.FormatSimpleDropdownOptionText(opt))
    CloseDropDownMenus()
    addon:RunUpdateStatsSafe()
end

function addon.profileUI.FormatSpecName(specID, explicitName)
    if addon.dbRuntime.IsCleanType(explicitName, "string") and explicitName ~= "" then
        return explicitName
    end
    local fn = _G.GetSpecializationInfoByID
    if type(fn) == "function"
        and addon.dbRuntime.IsCleanType(specID, "number") then
        local ok, resolvedID, resolvedName = pcall(fn, specID)
        if ok and addon.dbRuntime.IsCleanType(resolvedID, "number")
            and resolvedID == specID
            and addon.dbRuntime.IsCleanType(resolvedName, "string")
            and resolvedName ~= "" then
            return resolvedName
        end
    end
    return string.format(L("Unknown specialization (%d)"), specID)
end

function addon.profileUI.FindProfile(model, profileID)
    return model and model.profiles and model.profiles[profileID] or nil
end

function addon.profileUI.ContextLabel(character, spec)
    if not character or not spec then return "" end
    return character.displayName .. " / "
        .. addon.profileUI.FormatSpecName(spec.specID, spec.specName)
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
            label = addon.profileUI.RoleLabel(role),
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
    if reason == "duplicate-name" then return L("A profile with this name already exists.") end
    if reason == "stale" then return L("Profiles changed; review and try again.") end
    if reason == "combat" then return L("Profile changes are unavailable during combat.") end
    if reason == "corrupt" then
        return L("Corrupted data - profiles are read-only. Use /ss wipe to reset.")
    end
    if reason == "read-only" then return L("Compatibility mode - profiles are read-only.") end
    if reason == "pending" or reason == "busy" or reason == "unsafe-context" then
        return L("Waiting for a safe profile context.")
    end
    if reason == "current-character" then return L("The current character cannot be forgotten.") end
    if reason == "same-profile" or reason == "no-change" then
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
    local geometry = addon.settingsDesign.tokens.geometry
    local actionScroll = CreateFrame(
        "ScrollFrame", "StatsProProfileActionsScroll", manager, "UIPanelScrollFrameTemplate")
    ui.sharingSummaryVisible = nil
    function ui.SetSharingSummaryVisible(visible)
        visible = visible == true
        if ui.sharingSummaryVisible == visible then return end
        ui.sharingSummaryVisible = visible
        actionScroll:ClearAllPoints()
        actionScroll:SetPoint("TOPLEFT", 258,
            -(visible and geometry.managerActionsTopShared
                or geometry.managerActionsTopSolo))
        actionScroll:SetPoint("BOTTOMRIGHT", -34, 16)
    end
    ui.SetSharingSummaryVisible(false)
    addon.settingsDesign.StyleScrollFrame(actionScroll)
    local actionChild = CreateFrame("Frame", nil, actionScroll)
    actionChild:SetSize(318, 172)
    actionScroll:SetScrollChild(actionChild)

    local operationStatus = actionChild:CreateFontString(nil, "OVERLAY")
    operationStatus:SetPoint("TOPLEFT", 8, -2)
    operationStatus:SetPoint("TOPRIGHT", -12, -2)
    operationStatus:SetJustifyH("LEFT")
    operationStatus:SetWordWrap(true)
    operationStatus:SetMaxLines(2)
    addon.settingsDesign.ApplyTextRole(operationStatus, "controlMetadata")

    local function createAction(name, labelKey, y, roleName)
        local button = addon.settingsDesign.CreateShellButton(
            actionChild, name, roleName or "field")
        button:SetPoint("TOPLEFT", 6, y)
        button:SetSize(addon.settingsDesign.tokens.geometry.actionWidth,
            addon.settingsDesign.tokens.geometry.actionHeight)
        PushLocalizedLabel(function() button:SetText(L(labelKey)) end)
        return button
    end

    local copyButton = createAction(
        "StatsProProfileCopyFromButton", "Copy settings from...", -30)
    local useSameButton = createAction(
        "StatsProProfileUseSameButton", "Use the same settings as...", -58, "primary")
    local useForButton = createAction(
        "StatsProProfileUseForButton", "Use these settings for...", -86)
    local stopSharingButton = createAction(
        "StatsProProfileStopSharingButton", "Stop sharing...", -114)
    local transferButton = createAction(
        "StatsProProfileTransferButton", "Export / import profile...", -142, "primary")
    local advancedButton = createAction(
        "StatsProProfileAdvancedButton", "Advanced...", -178)
    local resetButton = createAction(
        "StatsProProfileResetButton", "Reset these settings...", -214, "destructive")
    local forgetButton = createAction(
        "StatsProProfileForgetButton", "Forget this character...", -242, "destructive")
    local roleTemplateButton = createAction(
        "StatsProProfileRoleTemplateButton", "Defaults for future specializations...", -270)
    local cleanupButton = createAction(
        "StatsProProfileCleanupButton", "Delete unused settings...", -298, "destructive")

    ui.advancedShown = false
    function ui.SetAdvancedShown(shown)
        ui.advancedShown = shown == true
        advancedButton:SetText(L(ui.advancedShown and "Hide advanced" or "Advanced..."))
        for _, button in ipairs({ resetButton, forgetButton, roleTemplateButton, cleanupButton }) do
            if ui.advancedShown then button:Show() else button:Hide() end
        end
        actionChild:SetHeight(ui.advancedShown and 334 or 200)
    end
    PushLocalizedLabel(function() ui.SetAdvancedShown(ui.advancedShown) end)
    ui.SetAdvancedShown(false)

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
    addon.settingsDesign.StyleCloseButton(dialogClose)

    local dialogMessage = dialog:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(dialogMessage, 12, nil, "dialogBody")
    addon.settingsDesign.SetRegionColor(dialogMessage, "textPrimary")
    dialogMessage:SetPoint("TOPLEFT", 20, -54)
    dialogMessage:SetPoint("TOPRIGHT", -20, -54)
    dialogMessage:SetJustifyH("LEFT")
    dialogMessage:SetJustifyV("TOP")
    dialogMessage:SetWordWrap(true)
    dialogMessage:SetMaxLines(12)

    local choiceScroll = CreateFrame(
        "ScrollFrame", "StatsProProfileChoiceScroll", dialog, "UIPanelScrollFrameTemplate")
    choiceScroll:SetPoint("TOPLEFT", 18, -52)
    choiceScroll:SetPoint("BOTTOMRIGHT", -38, 52)
    addon.settingsDesign.StyleScrollFrame(choiceScroll)
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
    PushLocalizedLabel(function() cancelButton:SetText(L("Cancel")) end)

    local transferSummary = dialog:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(transferSummary, 12, nil, "transferSummary")
    addon.settingsDesign.SetRegionColor(transferSummary, "textPrimary")
    transferSummary:SetPoint("TOPLEFT", 20, -56)
    transferSummary:SetPoint("TOPRIGHT", -20, -56)
    transferSummary:SetHeight(64)
    transferSummary:SetJustifyH("LEFT")
    transferSummary:SetJustifyV("TOP")
    transferSummary:SetWordWrap(true)

    local transferChecks = {}
    local transferCheckY = { stats = -126, layout = -154, appearance = -182 }
    for _, section in ipairs(addon.profileTransfer.sectionOrder) do
        local check = CreateFrame(
            "CheckButton", "StatsProProfileTransfer" .. section .. "Check", dialog,
            "UICheckButtonTemplate")
        check:SetPoint("TOPLEFT", 22, transferCheckY[section])
        check:SetSize(24, 24)
        local label = check:CreateFontString(nil, "OVERLAY")
        addon.settingsDesign.StyleCheckbox(check, label, true)
        label:SetPoint("RIGHT", dialog, "RIGHT", -20, 0)
        label:SetJustifyH("LEFT")
        label:SetWordWrap(false)
        label:SetMaxLines(1)
        local transferLabelKey = addon.profileTransfer.sectionLabelKeys[section]
        PushLocalizedLabel(function() label:SetText(L(transferLabelKey)) end)
        check.statsProTransferLabel = label
        check.statsProTransferSection = section
        check:SetScript("OnClick", function(button)
            if type(ui.OnTransferSectionChanged) == "function" then
                ui.OnTransferSectionChanged(
                    button.statsProTransferSection, button:GetChecked() == true)
            end
        end)
        transferChecks[section] = check
    end

    local transferInputSurface = CreateFrame(
        "Frame", "StatsProProfileTransferInputSurface", dialog, "BackdropTemplate")
    transferInputSurface:SetSize(400, 34)
    addon.settingsDesign.ApplySurface(transferInputSurface, "raised")
    local transferEditBox = CreateFrame(
        "EditBox", "StatsProProfileTransferEditBox", transferInputSurface, "InputBoxTemplate")
    transferEditBox:SetPoint("TOPLEFT", 8, -6)
    transferEditBox:SetPoint("BOTTOMRIGHT", -8, 6)
    if type(transferEditBox.SetAutoFocus) == "function" then transferEditBox:SetAutoFocus(false) end
    if type(transferEditBox.SetMaxLetters) == "function" then
        transferEditBox:SetMaxLetters(addon.profileTransfer.maxEncodedBytes)
    end
    RegisterConfigFont(transferEditBox, 11, nil, "transferInput")

    local transferHint = dialog:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(transferHint, 10, nil, "role:controlMetadata")
    transferHint:SetPoint("TOPLEFT", 20, -266)
    transferHint:SetPoint("TOPRIGHT", -20, -266)
    transferHint:SetHeight(34)
    transferHint:SetJustifyH("LEFT")
    transferHint:SetJustifyV("TOP")
    transferHint:SetWordWrap(true)

    ui.transferSummary = transferSummary
    ui.transferChecks = transferChecks
    ui.transferEditBox = transferEditBox
    ui.transferHint = transferHint

    ui.operationStatus = operationStatus
    ui.actionButtons = {
        copy = copyButton,
        useSame = useSameButton,
        useFor = useForButton,
        stopSharing = stopSharingButton,
        transfer = transferButton,
        advanced = advancedButton,
        reset = resetButton,
        forget = forgetButton,
        roleTemplate = roleTemplateButton,
        cleanup = cleanupButton,
    }
    function ui.ApplyOperationPaneWidth(managerWidth)
        local availableWidth = math.max(1, managerWidth - 258 - 34)
        local controlWidth = math.max(
            addon.settingsDesign.tokens.geometry.minHitTarget,
            math.min(addon.settingsDesign.tokens.geometry.actionWidth, availableWidth - 12))
        actionChild:SetWidth(availableWidth)
        for _, button in pairs(ui.actionButtons) do button:SetWidth(controlWidth) end
    end
    ui.ApplyOperationPaneWidth(ui.managerWidth)
    ui.operationDialog = dialog
    ui.operationBlocker = blocker
    ui.operationDialogMessage = dialogMessage
    ui.choiceRows = {}

    function ui.RefreshOperationStatus(model)
        local failed = ui.operationStatusKind == "error"
        local message = ""
        local colorRole = "accent"
        if model and model.readOnly then
            failed = model.mode == "corrupt"
            message = L(failed
                and "Corrupted data - profiles are read-only. Use /ss wipe to reset."
                or "Compatibility mode - profiles are read-only.")
            colorRole = failed and "danger" or "warning"
        elseif model and model.combat == true then
            message = L("Profile changes are unavailable during combat.")
            colorRole = "warning"
        elseif model and (model.pending or model.combat == nil) then
            message = L("Waiting for a safe profile context.")
            colorRole = "warning"
        elseif ui.operationStatusKind == "success" then
            message = L("Profile changes saved.")
        elseif failed then
            message = ui.OperationErrorText(ui.operationStatusReason)
            colorRole = "danger"
        end
        operationStatus:SetText(message)
        addon.settingsDesign.SetRegionColor(operationStatus, colorRole)
    end

    function ui.SetOperationStatus(kind, reason)
        ui.operationStatusKind = kind
        ui.operationStatusReason = reason
        ui.RefreshOperationStatus()
    end

    function ui.TransferSectionSummary(sections)
        local labels = {}
        for _, section in ipairs(addon.profileTransfer.sectionOrder) do
            if sections and sections[section] then
                labels[#labels + 1] = L(addon.profileTransfer.sectionLabelKeys[section])
            end
        end
        return table.concat(labels, " + ")
    end

    function ui.HideTransferControls()
        transferSummary:Hide()
        transferInputSurface:Hide()
        transferHint:Hide()
        for _, check in pairs(transferChecks) do
            check:Hide()
            check.statsProTransferLabel:Hide()
        end
    end

    function ui.ReadTransferSections()
        local selected = {}
        for _, section in ipairs(addon.profileTransfer.sectionOrder) do
            local check = transferChecks[section]
            if check:IsShown() and check:IsEnabled() and check:GetChecked() == true then
                selected[section] = true
            end
        end
        return addon.profileTransfer.NormalizeSections(selected)
    end

    function ui.SetTransferSections(available, selected, shown)
        for _, section in ipairs(addon.profileTransfer.sectionOrder) do
            local check = transferChecks[section]
            local label = check.statsProTransferLabel
            label:SetText(L(addon.profileTransfer.sectionLabelKeys[section]))
            check:SetChecked(selected and selected[section] == true)
            if available and available[section] then check:Enable() else check:Disable() end
            if shown then check:Show(); label:Show() else check:Hide(); label:Hide() end
        end
    end

    function ui.SetTransferText(value, selectAll)
        ui.transferUpdatingText = true
        transferEditBox:SetText(value or "")
        ui.transferUpdatingText = false
        if selectAll then
            transferEditBox:HighlightText()
            transferEditBox:SetFocus()
        end
    end

    function ui.TransferErrorText(reason)
        if reason == "future-format" then
            return L("This profile string uses a newer unsupported format.")
        end
        if reason == "invalid-sections" then return L("Choose at least one section.") end
        return L("The profile string is invalid or damaged.")
    end

    function ui.RefreshTransferDialog()
        local state = ui.transferState
        if not state then return end
        ui.HideTransferControls()
        transferSummary:Show()
        transferInputSurface:Show()
        transferHint:Show()
        dialogMessage:Hide()
        choiceScroll:Hide()
        primaryButton:Show()
        cancelButton:SetText(L(state.kind == "export" and "Close" or "Cancel"))
        addon.settingsDesign.SetRegionColor(transferHint,
            state.error and "danger" or "textSecondary")

        if state.kind == "export" then
            dialogTitle:SetText(L("Export profile"))
            ui.SetTransferSections(state.available, state.selected, true)
            local sections = ui.ReadTransferSections()
            if sections then
                local transferString, reason = addon.profileTransfer.Serialize(
                    state.profileName, state.settings, sections)
                if transferString then
                    state.transferString = transferString
                    state.error = nil
                    ui.SetTransferText(transferString, state.selectText == true)
                    state.selectText = false
                else
                    state.transferString = nil
                    state.error = reason
                    ui.SetTransferText("")
                end
            else
                state.transferString = nil
                state.error = "invalid-sections"
                ui.SetTransferText("")
            end
            transferSummary:SetText(
                string.format(L("StatsPro profile: %s"), state.profileName) .. "\n"
                .. string.format(L("Format version: %d"), addon.profileTransfer.formatVersion)
                .. "\n" .. string.format(L("Included: %s"),
                    sections and ui.TransferSectionSummary(sections) or "—"))
            transferInputSurface:ClearAllPoints()
            transferInputSurface:SetPoint("TOP", dialog, "TOP", 0, -220)
            transferHint:SetText(state.error and ui.TransferErrorText(state.error)
                or L("Export string ready. Select it, then press Ctrl+C to copy."))
            primaryButton:SetText(L("Select all"))
            if state.transferString then primaryButton:Enable() else primaryButton:Disable() end
            return
        end

        dialogTitle:SetText(L("Import profile"))
        if state.kind == "import-entry" then
            ui.SetTransferSections(nil, nil, false)
            transferSummary:SetText(
                L("Paste a StatsPro profile string, then preview it before importing."))
            transferInputSurface:ClearAllPoints()
            transferInputSurface:SetPoint("TOP", dialog, "TOP", 0, -134)
            transferHint:SetText(state.error and ui.TransferErrorText(state.error) or "")
            primaryButton:SetText(L("Preview"))
            if transferEditBox:GetText() ~= "" then primaryButton:Enable()
            else primaryButton:Disable() end
            return
        end

        local package = state.package
        ui.SetTransferSections(package.sections, state.selected, true)
        local selected = ui.ReadTransferSections()
        transferSummary:SetText(
            string.format(L("StatsPro profile: %s"), package.profileName) .. "\n"
            .. string.format(L("Format version: %d"), package.formatVersion) .. "\n"
            .. string.format(L("Included: %s"), ui.TransferSectionSummary(package.sections)))
        transferInputSurface:ClearAllPoints()
        transferInputSurface:SetPoint("TOP", dialog, "TOP", 0, -220)
        transferHint:SetText(state.error and ui.TransferErrorText(state.error)
            or (selected and "" or L("Choose at least one section.")))
        primaryButton:SetText(L("Import"))
        if selected then primaryButton:Enable() else primaryButton:Disable() end
    end

    function ui.OnTransferSectionChanged(section, selected)
        local state = ui.transferState
        if not state or not state.available or not state.available[section] then return end
        state.selected[section] = selected == true
        state.error = nil
        ui.RefreshTransferDialog()
    end

    function ui.CloseOperationDialog()
        if dialog:IsShown() then dialog:Hide() end
        blocker:Hide()
    end

    function ui.ShowDialogBase(title)
        dialogTitle:SetText(title)
        dialogMessage:SetText("")
        dialogMessage:Show()
        choiceScroll:Hide()
        ui.HideTransferControls()
        transferEditBox:ClearFocus()
        ui.transferState = nil
        primaryButton:Show()
        primaryButton:Enable()
        primaryButton:SetText(L("Confirm"))
        cancelButton:SetText(L("Cancel"))
        primaryButton.statsProButtonRole = "primary"
        addon.settingsDesign.RefreshShellButton(primaryButton)
        ui.CancelSpecialFrameRestore("StatsProProfileManager")
        ui.RemoveSpecialFrame("StatsProProfileManager")
        ui.PushSpecialFrame("StatsProProfileOperationDialog")
        blocker:Show()
        dialog:Show()
    end

    function ui.ShowConfirmation(kind, title, message, payload, expected)
        ui.pendingAction = {
            mode = "confirm", kind = kind, payload = payload, expected = expected,
        }
        ui.ShowDialogBase(title)
        primaryButton.statsProButtonRole = (kind == "reset" or kind == "cleanup"
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
        text:SetPoint("LEFT", 8, 0)
        text:SetPoint("RIGHT", -8, 0)
        text:SetWordWrap(false)
        row.text = text
        addon.settingsDesign.StyleListRow(row, text, "metadata")
        text:SetJustifyH("LEFT")
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
            addon.settingsDesign.RefreshOwnedControlTooltip(row)
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

    function ui.ShowTransferExport(payload, expected)
        local root = addon.dbRuntime.Refresh()
        local profile = payload and root.profiles and root.profiles[payload.profileID] or nil
        if not profile or not addon.profileOps.CheckExpected(root, expected)
            or not addon.dbRuntime.IsCleanType(profile.name, "string")
            or not addon.dbRuntime.IsCleanTable(profile.settings) then
            ui.HandleOperationResult(false, "stale")
            return
        end
        ui.ShowDialogBase(L("Export profile"))
        ui.pendingAction = {
            mode = "transfer", kind = "transfer-export",
            payload = payload, expected = expected,
        }
        ui.transferState = {
            kind = "export",
            profileName = profile.name,
            settings = profile.settings,
            available = { stats = true, layout = true, appearance = true },
            selected = { stats = true, layout = true, appearance = true },
            selectText = true,
        }
        ui.RefreshTransferDialog()
    end

    function ui.ShowTransferImportEntry(payload, expected)
        ui.ShowDialogBase(L("Import profile"))
        ui.pendingAction = {
            mode = "transfer", kind = "transfer-import-entry",
            payload = payload, expected = expected,
        }
        ui.transferState = { kind = "import-entry" }
        ui.SetTransferText("")
        ui.RefreshTransferDialog()
        transferEditBox:SetFocus()
    end

    function ui.PreviewTransferImport()
        local state = ui.transferState
        if not state or state.kind ~= "import-entry" then return false end
        local package, reason = addon.profileTransfer.Parse(transferEditBox:GetText())
        if not package then
            state.error = reason
            ui.RefreshTransferDialog()
            return false
        end
        state.kind = "import-preview"
        state.package = package
        state.available = package.sections
        state.selected = {}
        for section in pairs(package.sections) do state.selected[section] = true end
        state.error = nil
        ui.pendingAction.kind = "transfer-import-preview"
        ui.RefreshTransferDialog()
        return true
    end

    function ui.PrepareTransferImportConfirmation()
        local state = ui.transferState
        local pending = ui.pendingAction
        if not state or state.kind ~= "import-preview" or not pending then return false end
        local package, reason = addon.profileTransfer.Parse(transferEditBox:GetText())
        local sections = ui.ReadTransferSections()
        if not package then
            state.error = reason
            state.kind = "import-entry"
            state.package = nil
            ui.pendingAction.kind = "transfer-import-entry"
            ui.RefreshTransferDialog()
            return false
        end
        if not sections then
            state.error = "invalid-sections"
            ui.RefreshTransferDialog()
            return false
        end
        local payload = pending.payload or {}
        ui.ShowConfirmation("transfer-import-confirm", L("Import profile"),
            string.format(
                L("Import selected sections as a new independent profile for \"%s\"? Existing profiles and unselected settings will stay unchanged."),
                payload.targetLabel or L("Character")), {
                transferString = package.originalString,
                sections = sections,
                guid = payload.guid,
                specID = payload.specID,
            }, pending.expected)
        return true
    end

    function ui.RunTransferAction()
        local state = ui.transferState
        if not state then return end
        if state.kind == "export" then
            transferEditBox:HighlightText()
            transferEditBox:SetFocus()
        elseif state.kind == "import-entry" then
            ui.PreviewTransferImport()
        elseif state.kind == "import-preview" then
            ui.PrepareTransferImportConfirmation()
        end
    end

    transferEditBox:SetScript("OnTextChanged", function()
        if ui.transferUpdatingText then return end
        local state = ui.transferState
        if not state then return end
        if state.kind == "export" then
            if transferEditBox:GetText() ~= (state.transferString or "") then
                ui.SetTransferText(state.transferString or "", true)
            end
            return
        end
        if state.kind == "import-preview" then
            state.kind = "import-entry"
            state.package = nil
            state.available = nil
            state.selected = nil
            if ui.pendingAction then ui.pendingAction.kind = "transfer-import-entry" end
        end
        state.error = nil
        ui.RefreshTransferDialog()
    end)
    transferEditBox:SetScript("OnEnterPressed", function() ui.RunTransferAction() end)
    transferEditBox:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
    PushLocalizedLabel(function()
        if dialog:IsShown() and ui.transferState then ui.RefreshTransferDialog() end
    end)

    function ui.SpecChoices(
        model, excludedGUID, excludedSpecID, excludedProfileID, uniqueProfiles)
        local choices = {}
        local seenProfiles = {}
        for _, character in ipairs(model.characters or {}) do
            for _, spec in ipairs(character.specs) do
                if (character.guid ~= excludedGUID or spec.specID ~= excludedSpecID)
                    and spec.profileID ~= excludedProfileID
                    and (not uniqueProfiles or not seenProfiles[spec.profileID]) then
                    choices[#choices + 1] = {
                        kind = "context", guid = character.guid, specID = spec.specID,
                        profileID = spec.profileID,
                        label = ui.ContextLabel(character, spec),
                    }
                    seenProfiles[spec.profileID] = true
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

    function ui.HandleOperationResult(ok, result)
        if ok then
            ui.SetOperationStatus("success")
            ui.CloseOperationDialog()
            ui.RefreshSafe()
            return true
        end
        ui.SetOperationStatus("error", result)
        ui.CloseOperationDialog()
        ui.RefreshSafe()
        return false
    end

    function ui.HandleChoice(choice)
        local pending = ui.pendingAction
        if not pending or pending.mode ~= "choice" then return end
        local model = ui.currentModel or ui.BuildViewModel()
        if pending.kind == "transfer-direction" then
            local payload = pending.payload or {}
            if choice.direction == "export" then
                ui.ShowTransferExport(payload, pending.expected)
            elseif choice.direction == "import" and payload.canImport == true then
                ui.ShowTransferImportEntry(payload, pending.expected)
            else
                ui.HandleOperationResult(false, "stale")
            end
            return
        end
        if pending.kind == "copy-source" then
            local payload = pending.payload
            local source = ui.FindProfile(model, choice.profileID)
            local target = ui.FindProfile(model, payload.targetProfileID)
            if not source or not target then
                ui.HandleOperationResult(false, "stale")
                return
            end
            ui.ShowChoices("copy-scope", L("Choose settings to copy"),
                ui.CopyScopeChoices(), {
                    sourceProfileID = source.profileID,
                    sourceLabel = choice.label,
                    targetProfileID = target.profileID,
                    targetLabel = payload.targetLabel,
                    guid = payload.guid,
                    specID = payload.specID,
                }, ui.CaptureExpected(payload.guid, payload.specID, target.profileID))
            return
        end
        if pending.kind == "copy-scope" then
            local payload = pending.payload
            if not addon.profileOps.copyScopeKeys[choice.scope] and choice.scope ~= "all" then
                ui.HandleOperationResult(false, "stale")
                return
            end
            ui.ShowConfirmation("copy-context", L("Copy settings from..."),
                string.format(
                    L("Copy %s from \"%s\" to \"%s\"? The destination will keep its own settings afterward."),
                    choice.label, payload.sourceLabel, payload.targetLabel), {
                    sourceProfileID = payload.sourceProfileID,
                    guid = payload.guid,
                    specID = payload.specID,
                    scope = choice.scope,
                }, pending.expected)
            return
        end
        if pending.kind == "share-source" or pending.kind == "share-target" then
            local payload = pending.payload
            local sourceProfileID, guid, specID, sourceLabel, targetLabel
            if pending.kind == "share-source" then
                sourceProfileID = choice.profileID
                guid, specID = payload.guid, payload.specID
                sourceLabel, targetLabel = choice.label, payload.targetLabel
            else
                sourceProfileID = payload.sourceProfileID
                guid, specID = choice.guid, choice.specID
                sourceLabel, targetLabel = payload.sourceLabel, choice.label
            end
            local source = ui.FindProfile(model, sourceProfileID)
            if not source then ui.HandleOperationResult(false, "stale"); return end
            local sharedCount = source.references and source.references.specs or 0
            local message = sharedCount > 1
                and string.format(
                    L("Use the shared settings from \"%s\" for \"%s\"? They are already shared by %d specializations; future changes will affect all %d."),
                    sourceLabel, targetLabel, sharedCount, sharedCount + 1)
                or string.format(
                    L("Use the same settings for \"%s\" and \"%s\"? Future changes will affect both."),
                    sourceLabel, targetLabel)
            ui.ShowConfirmation("share-context", L("Use the same settings as..."),
                message, {
                    guid = guid,
                    specID = specID,
                    profileID = sourceProfileID,
                }, ui.CaptureExpected(guid, specID, sourceProfileID))
            return
        end
        if pending.kind == "role-template" then
            local payload = pending.payload
            local profile = ui.FindProfile(model, payload.profileID)
            local template = model.roleTemplates and model.roleTemplates[choice.role] or nil
            if not profile or not template or not addon.profileOps.roleKeys[choice.role] then
                ui.HandleOperationResult(false, "stale")
                return
            end
            if template.profileID == profile.profileID then
                ui.HandleOperationResult(false, "no-change")
                return
            end
            local messageKey = choice.role == "TANK"
                and "Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."
                or choice.role == "HEALER"
                    and "Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."
                    or "Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."
            ui.ShowConfirmation("set-role-template",
                L("Defaults for future specializations..."),
                string.format(L(messageKey), payload.sourceLabel), {
                    role = choice.role,
                    profileID = profile.profileID,
                }, pending.expected)
        end
    end

    function ui.RunPendingAction()
        local pending = ui.pendingAction
        if not pending then return end
        if pending.mode == "transfer" then
            ui.RunTransferAction()
            return
        end
        if pending.mode ~= "confirm" then return end
        local payload = pending.payload or {}
        local ok, result
        if pending.kind == "copy-context" then
            ok, result = addon.profileOps.CopySettingsToContext(
                payload.sourceProfileID, payload.guid, payload.specID,
                payload.scope, pending.expected)
        elseif pending.kind == "share-context" then
            ok, result = addon.profileOps.Assign(
                payload.guid, payload.specID, payload.profileID, pending.expected)
        elseif pending.kind == "stop-sharing" then
            ok, result = addon.profileOps.MakeContextIndependent(
                payload.guid, payload.specID, pending.expected)
        elseif pending.kind == "reset" then
            ok, result = addon.profileOps.ResetProfile(payload.profileID, pending.expected)
        elseif pending.kind == "forget" then
            ok, result = addon.profileOps.ForgetCharacter(payload.guid, pending.expected)
            if ok then ui.selectedGUID, ui.selectedSpecID = nil, nil end
        elseif pending.kind == "cleanup" then
            ok, result = addon.profileOps.DeleteUnusedProfiles(pending.expected)
        elseif pending.kind == "set-role-template" then
            ok, result = addon.profileOps.SetRoleTemplate(
                payload.role, payload.profileID, pending.expected)
        elseif pending.kind == "transfer-import-confirm" then
            local package, parseReason = addon.profileTransfer.Parse(payload.transferString)
            if not package then
                ok, result = false, parseReason
            else
                ok, result = addon.profileOps.ImportTransferToContext(
                    package, payload.sections, payload.guid, payload.specID,
                    pending.expected)
                if ok and result and result.name then
                    PrintMsg(string.format(L("Imported profile \"%s\" was created."), result.name))
                end
            end
        end
        ui.HandleOperationResult(ok, result)
    end

    function ui.RefreshOperationControls(model, character, spec)
        local assignedProfileID = spec and spec.profileID or nil
        local assignedProfile = ui.FindProfile(model, assignedProfileID)
        ui.selectedAssignedProfileID = assignedProfileID
        ui.selectedCharacterModel = character
        ui.selectedSpecModel = spec
        ui.RefreshOperationStatus(model)

        local mutable = model.canMutate == true
        local hasContext = character ~= nil and spec ~= nil and assignedProfile ~= nil
        local alternatives = hasContext
            and ui.SpecChoices(
                model, character.guid, spec.specID, assignedProfileID, true) or {}
        local hasAlternative = #alternatives > 0
        if mutable and hasContext and hasAlternative then
            copyButton:Enable()
            useSameButton:Enable()
            useForButton:Enable()
        else
            copyButton:Disable()
            useSameButton:Disable()
            useForButton:Disable()
        end
        if mutable and hasContext and (spec.sharedCount or 0) > 1 then
            stopSharingButton:Enable()
        else stopSharingButton:Disable() end
        if hasContext then transferButton:Enable() else transferButton:Disable() end
        advancedButton:Enable()
        if mutable and hasContext then resetButton:Enable() else resetButton:Disable() end
        if mutable and character and not character.isCurrent then forgetButton:Enable()
        else forgetButton:Disable() end
        if mutable and hasContext then roleTemplateButton:Enable()
        else roleTemplateButton:Disable() end
        if mutable and (model.unusedProfileCount or 0) > 0 then cleanupButton:Enable()
        else cleanupButton:Disable() end

        local exportOnlyDialog = ui.pendingAction
            and (ui.pendingAction.kind == "transfer-export"
                or (ui.pendingAction.kind == "transfer-direction"
                    and ui.pendingAction.payload
                    and ui.pendingAction.payload.canImport ~= true))
        if dialog:IsShown() and ((not mutable and not exportOnlyDialog)
            or not addon.profileOps.CheckExpected(addon.dbRuntime.Refresh(),
                ui.pendingAction and ui.pendingAction.expected)) then
            dialog:Hide()
        end
    end

    copyButton:SetScript("OnClick", function()
        local model = ui.currentModel or ui.BuildViewModel()
        local character, spec = ui.selectedCharacterModel, ui.selectedSpecModel
        local target = ui.FindProfile(model, ui.selectedAssignedProfileID)
        if not character or not spec or not target then return end
        local targetLabel = ui.ContextLabel(character, spec)
        ui.ShowChoices("copy-source", L("Copy settings from..."),
            ui.SpecChoices(model, character.guid, spec.specID, target.profileID, true), {
                guid = character.guid,
                specID = spec.specID,
                targetProfileID = target.profileID,
                targetLabel = targetLabel,
            }, ui.CaptureExpected(character.guid, spec.specID, target.profileID))
    end)

    useSameButton:SetScript("OnClick", function()
        local model = ui.currentModel or ui.BuildViewModel()
        local character, spec = ui.selectedCharacterModel, ui.selectedSpecModel
        local target = ui.FindProfile(model, ui.selectedAssignedProfileID)
        if not character or not spec or not target then return end
        ui.ShowChoices("share-source", L("Use the same settings as..."),
            ui.SpecChoices(model, character.guid, spec.specID, target.profileID, true), {
                guid = character.guid,
                specID = spec.specID,
                targetLabel = ui.ContextLabel(character, spec),
            }, ui.CaptureExpected(character.guid, spec.specID, target.profileID))
    end)

    useForButton:SetScript("OnClick", function()
        local model = ui.currentModel or ui.BuildViewModel()
        local character, spec = ui.selectedCharacterModel, ui.selectedSpecModel
        local source = ui.FindProfile(model, ui.selectedAssignedProfileID)
        if not character or not spec or not source then return end
        ui.ShowChoices("share-target", L("Use these settings for..."),
            ui.SpecChoices(model, character.guid, spec.specID, source.profileID), {
                sourceProfileID = source.profileID,
                sourceLabel = ui.ContextLabel(character, spec),
            }, ui.CaptureExpected(character.guid, spec.specID, source.profileID))
    end)

    stopSharingButton:SetScript("OnClick", function()
        local model = ui.currentModel or ui.BuildViewModel()
        local character, spec = ui.selectedCharacterModel, ui.selectedSpecModel
        local profile = ui.FindProfile(model, ui.selectedAssignedProfileID)
        if not character or not spec or not profile or (spec.sharedCount or 0) <= 1 then return end
        local label = ui.ContextLabel(character, spec)
        ui.ShowConfirmation("stop-sharing", L("Stop sharing..."),
            string.format(L("Give \"%s\" its own copy of these settings? Future changes will no longer affect the other specializations."), label), {
                guid = character.guid,
                specID = spec.specID,
            }, ui.CaptureExpected(character.guid, spec.specID, profile.profileID))
    end)

    transferButton:SetScript("OnClick", function()
        local model = ui.currentModel or ui.BuildViewModel()
        local character, spec = ui.selectedCharacterModel, ui.selectedSpecModel
        local profile = ui.FindProfile(model, ui.selectedAssignedProfileID)
        if not character or not spec or not profile then return end
        local choices = {
            { kind = "transfer", direction = "export", label = L("Export this profile") },
        }
        if model.canMutate == true then
            choices[#choices + 1] = {
                kind = "transfer", direction = "import",
                label = L("Import into a new profile"),
            }
        end
        ui.ShowChoices("transfer-direction", L("Export / import profile..."), choices, {
            guid = character.guid,
            specID = spec.specID,
            profileID = profile.profileID,
            targetLabel = ui.ContextLabel(character, spec),
            canImport = model.canMutate == true,
        }, ui.CaptureExpected(character.guid, spec.specID, profile.profileID))
    end)

    advancedButton:SetScript("OnClick", function()
        ui.SetAdvancedShown(not ui.advancedShown)
        if not ui.advancedShown then actionScroll:SetVerticalScroll(0) end
    end)

    resetButton:SetScript("OnClick", function()
        local model = ui.currentModel or ui.BuildViewModel()
        local character, spec = ui.selectedCharacterModel, ui.selectedSpecModel
        local profile = ui.FindProfile(model, ui.selectedAssignedProfileID)
        if not character or not spec or not profile then return end
        local label = ui.ContextLabel(character, spec)
        local sharedCount = profile.references and profile.references.specs or 1
        local message = sharedCount > 1
            and string.format(L("Reset the settings used by \"%s\"? The same reset will affect %d specializations."), label, sharedCount)
            or string.format(L("Reset the settings used by \"%s\" to defaults?"), label)
        local futureReferences = profile.references
            and profile.references.total - profile.references.specs or 0
        if futureReferences > 0 then
            message = message .. " " .. L(
                "This profile is also a default for future specializations; they will use the reset settings.")
        end
        ui.ShowConfirmation("reset", L("Reset these settings..."), message, {
            profileID = profile.profileID,
        }, ui.CaptureExpected(character.guid, spec.specID, profile.profileID))
    end)

    forgetButton:SetScript("OnClick", function()
        local character = ui.selectedCharacterModel
        if not character then return end
        local message = string.format(
            L("Forget \"%s\"? Its character record will be removed, but profile settings will be kept."),
            character.displayName)
        ui.ShowConfirmation("forget", L("Forget this character..."), message, {
            guid = character.guid,
        }, ui.CaptureExpected(character.guid, ui.selectedSpecID))
    end)

    roleTemplateButton:SetScript("OnClick", function()
        local model = ui.currentModel or ui.BuildViewModel()
        local character, spec = ui.selectedCharacterModel, ui.selectedSpecModel
        local profile = ui.FindProfile(model, ui.selectedAssignedProfileID)
        if not character or not spec or not profile then return end
        ui.ShowChoices("role-template", L("Choose a role"),
            ui.RoleTemplateChoices(model), {
                profileID = profile.profileID,
                sourceLabel = ui.ContextLabel(character, spec),
            }, ui.CaptureExpected(nil, nil, profile.profileID))
    end)

    cleanupButton:SetScript("OnClick", function()
        local model = ui.currentModel or ui.BuildViewModel()
        local count = model.unusedProfileCount or 0
        if count <= 0 then return end
        ui.ShowConfirmation("cleanup", L("Delete unused settings..."),
            string.format(L("Delete %d unused settings records? Settings currently used by a specialization or future-specialization default will be kept."), count),
            nil, ui.CaptureExpected())
    end)

    primaryButton:SetScript("OnClick", ui.RunPendingAction)
    cancelButton:SetScript("OnClick", ui.CloseOperationDialog)
    dialogClose:SetScript("OnClick", ui.CloseOperationDialog)
    dialog:SetScript("OnHide", function()
        blocker:Hide()
        ui.pendingAction = nil
        ui.transferState = nil
        transferEditBox:ClearFocus()
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

    local profileButton = addon.settingsDesign.CreateShellButton(
        header, "StatsProActiveProfileButton", "display", "profile")
    profileButton:SetPoint("TOPLEFT", geometry.profileFieldInset, -5)
    profileButton:SetSize(geometry.profileFieldWidth, geometry.minHitTarget)
    profileButton.statsProText:SetJustifyH("LEFT")
    profileButton:EnableMouse(true)

    local manageButton = addon.settingsDesign.CreateShellButton(
        header, "StatsProManageProfilesButton", "field")
    manageButton:SetPoint("TOPRIGHT", -8, -5)
    manageButton:SetSize(geometry.manageWidth, geometry.minHitTarget)
    profileButton:SetPoint("TOPRIGHT", manageButton, "TOPLEFT", -8, 0)
    PushLocalizedLabel(function() manageButton:SetText(L("Profiles & sharing...")) end)

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

    local detailProfile
    manager:SetSize(geometry.managerMinWidth, geometry.managerMinHeight)
    ui.managerWidth = geometry.managerMinWidth
    ui.managerHeight = geometry.managerMinHeight
    function ui.ApplyManagerSize()
        local parentWidth = addon.settingsDesign.ReadUIParentWidth()
        local parentHeight = addon.settingsDesign.ReadUIParentHeight()
        if not parentWidth or not parentHeight then return false end
        local width = math.max(geometry.managerMinWidth,
            math.min(geometry.managerMaxWidth, parentWidth * geometry.managerWidthRatio))
        local height = math.max(geometry.managerMinHeight,
            math.min(geometry.managerMaxHeight, parentHeight * geometry.managerHeightRatio))
        if ui.managerWidth ~= width or ui.managerHeight ~= height then
            manager:SetSize(width, height)
            ui.managerWidth, ui.managerHeight = width, height
        end
        if detailProfile then
            detailProfile:SetWidth(math.max(1, width - geometry.managerDetailInset))
        end
        if type(ui.ApplyOperationPaneWidth) == "function" then
            ui.ApplyOperationPaneWidth(width)
        end
        return true
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
    PushLocalizedLabel(function() managerTitle:SetText(L("Profiles & sharing")) end)

    local managerCloseX = CreateFrame("Button", nil, manager, "UIPanelCloseButton")
    managerCloseX:SetPoint("TOPRIGHT", -4, -4)
    addon.settingsDesign.StyleCloseButton(managerCloseX)

    local managerLine = manager:CreateTexture(nil, "ARTWORK")
    managerLine:SetPoint("TOPLEFT", 14, -42)
    managerLine:SetPoint("TOPRIGHT", -14, -42)
    managerLine:SetHeight(1)
    addon.settingsDesign.ApplySeparator(managerLine)

    local divider = manager:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", 248, -52)
    divider:SetPoint("BOTTOMLEFT", 248, 14)
    divider:SetWidth(1)
    addon.settingsDesign.ApplySeparator(divider)

    local listSurface = addon.settingsDesign.CreateTextureSurface(manager, "viewport")
    listSurface:SetPoint("TOPLEFT", 12, -48)
    listSurface:SetPoint("BOTTOMLEFT", 12, 12)
    listSurface:SetWidth(230)

    local detailSurface = addon.settingsDesign.CreateTextureSurface(manager, "raised")
    detailSurface:SetPoint("TOPLEFT", 252, -48)
    detailSurface:SetPoint("BOTTOMRIGHT", -12, 12)

    local listTitle = manager:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(listTitle, 12, "OUTLINE", "managerListTitle")
    listTitle:SetPoint("TOPLEFT", 20, -54)
    PushLocalizedLabel(function() listTitle:SetText(L("Character")) end)

    local listScroll = CreateFrame(
        "ScrollFrame", "StatsProProfileManagerScroll", manager, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", 16, -76)
    listScroll:SetPoint("BOTTOMLEFT", 16, 16)
    listScroll:SetWidth(212)
    addon.settingsDesign.StyleScrollFrame(listScroll)
    local listChild = CreateFrame("Frame", nil, listScroll)
    listChild:SetSize(190, 1)
    listScroll:SetScrollChild(listChild)

    local emptyText = listChild:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(emptyText, 12, nil, "managerEmpty")
    emptyText:SetPoint("TOPLEFT", 6, -8)
    emptyText:SetWidth(178)
    emptyText:SetJustifyH("LEFT")
    addon.settingsDesign.SetRegionColor(emptyText, "textMuted")

    local detailCharacter = manager:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(detailCharacter, 16, "OUTLINE", "managerCharacter")
    detailCharacter:SetPoint("TOPLEFT", 266, -58)
    detailCharacter:SetPoint("TOPRIGHT", -20, -58)
    detailCharacter:SetJustifyH("LEFT")

    local detailContext = manager:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(detailContext, 12, nil, "managerContext")
    detailContext:SetPoint("TOPLEFT", detailCharacter, "BOTTOMLEFT", 0, -8)
    detailContext:SetPoint("TOPRIGHT", detailCharacter, "BOTTOMRIGHT", 0, -8)
    detailContext:SetJustifyH("LEFT")
    addon.settingsDesign.SetRegionColor(detailContext, "textSecondary")

    detailProfile = manager:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(detailProfile, 15, "OUTLINE", "managerProfile")
    detailProfile:SetPoint("TOPLEFT", detailContext, "BOTTOMLEFT", 0, -18)
    detailProfile:SetWidth(math.max(1, ui.managerWidth - geometry.managerDetailInset))
    detailProfile:SetHeight(20)
    detailProfile:SetJustifyH("LEFT")
    detailProfile:SetWordWrap(false)
    detailProfile:SetNonSpaceWrap(false)
    detailProfile:SetMaxLines(1)
    addon.settingsDesign.SetRegionColor(detailProfile, "accent")
    detailProfile:Hide()

    ui.headerProfileButton = profileButton
    ui.manager = manager
    ui.managerListSurface = listSurface
    ui.managerDetailSurface = detailSurface
    ui.managerTitle = managerTitle
    ui.managerRows = {}
    ui.detailCharacter = detailCharacter
    ui.detailContext = detailContext
    ui.detailProfile = detailProfile
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
        text:SetPoint("LEFT", 6, 0)
        local badge = row:CreateFontString(nil, "OVERLAY")
        RegisterConfigFont(badge, 10, "OUTLINE", "managerBadge")
        badge:SetPoint("RIGHT", -6, 0)
        badge:SetWidth(70)
        badge:SetJustifyH("RIGHT")
        addon.settingsDesign.SetRegionColor(badge, "positive")
        text:SetPoint("RIGHT", badge, "LEFT", -4, 0)
        text:SetWordWrap(false)
        text:SetMaxLines(1)
        row.background = background
        row.text = text
        row.badge = badge
        addon.settingsDesign.StyleListRow(row, text, "metadata")
        text:SetJustifyH("LEFT")
        row:SetScript("OnClick", function(button)
            local context = button.profileContext
            if not context then return end
            ui.selectedGUID = context.guid
            ui.selectedSpecID = context.specID
            ui.RefreshSafe()
        end)
        ui.managerRows[index] = row
        return row
    end

    function ui.RefreshAll()
        local model = ui.BuildViewModel()
        ui.currentModel = model
        ui.refreshCount = ui.refreshCount + 1

        local warning = false
        if model.readOnly then
            profileButton:SetText(L(model.mode == "corrupt"
                and "Corrupted data - profiles are read-only. Use /ss wipe to reset."
                or "Compatibility mode - profiles are read-only."))
            warning = true
        elseif model.pending then
            profileButton:SetText(L(model.combat == true
                and "Switch pending until combat ends"
                or "Waiting for a safe profile context."))
            warning = true
        elseif model.activeGUID and model.activeSpecID then
            profileButton:SetText(ui.FormatSpecName(model.activeSpecID, model.activeSpecName)
                .. " - " .. (model.activeDisplayName or L("Character")))
        else
            profileButton:SetText(L("Account default profile"))
        end
        addon.settingsDesign.RefreshOwnedControlTooltip(profileButton)
        addon.settingsDesign.SetRegionColor(
            profileButton.statsProText, warning and "warning" or "textPrimary")

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
        if selectedCharacter and not selectedSpec then
            if selectedCharacter.guid == model.activeGUID then
                for _, spec in ipairs(selectedCharacter.specs) do
                    if spec.specID == model.activeSpecID then selectedSpec = spec; break end
                end
            end
            selectedSpec = selectedSpec or selectedCharacter.specs[1]
        end
        if not selectedCharacter then
            for _, character in ipairs(model.characters) do
                if character.guid == model.activeGUID then
                    for _, spec in ipairs(character.specs) do
                        if spec.specID == model.activeSpecID then
                            selectedCharacter, selectedSpec = character, spec
                            break
                        end
                    end
                end
                if selectedCharacter then break end
            end
        end
        if not selectedCharacter then
            for _, character in ipairs(model.characters) do
                if character.specs[1] then
                    selectedCharacter, selectedSpec = character, character.specs[1]
                    break
                end
            end
        end
        ui.selectedGUID = selectedCharacter and selectedCharacter.guid or nil
        ui.selectedSpecID = selectedSpec and selectedSpec.specID or nil

        local rowIndex, y = 0, -2
        for _, character in ipairs(model.characters) do
            rowIndex = rowIndex + 1
            local row = ui.EnsureManagerRow(rowIndex)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, y)
            row.profileContext = nil
            row.statsProHeading = true
            row:Enable()
            row:EnableMouse(true)
            row.text:SetText(character.displayName)
            row.badge:SetText(character.isCurrent and L("Current") or "")
            addon.settingsDesign.RefreshOwnedControlTooltip(row)
            addon.settingsDesign.SetListRowSelected(row, false)
            row:Show()
            y = y - 26
            for _, spec in ipairs(character.specs) do
                rowIndex = rowIndex + 1
                row = ui.EnsureManagerRow(rowIndex)
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", 0, y)
                row.profileContext = { guid = character.guid, specID = spec.specID }
                row.statsProHeading = false
                row:Enable()
                row:EnableMouse(true)
                row.text:SetText("   " .. ui.FormatSpecName(spec.specID, spec.specName))
                row.badge:SetText(spec.isActive and L("Active") or "")
                addon.settingsDesign.RefreshOwnedControlTooltip(row)
                local selected = character.guid == ui.selectedGUID
                    and ui.selectedSpecID == spec.specID
                addon.settingsDesign.SetListRowSelected(row, selected)
                row:Show()
                y = y - addon.settingsDesign.tokens.geometry.listRowHeight
            end
            y = y - 4
        end
        for index = rowIndex + 1, #ui.managerRows do ui.managerRows[index]:Hide() end
        listChild:SetHeight(math.max(1, -y + 4))
        emptyText:SetText(#model.characters == 0 and L("No visited characters") or "")

        if selectedCharacter and selectedSpec then
            detailCharacter:SetText(ui.FormatSpecName(selectedSpec.specID, selectedSpec.specName))
            detailContext:SetText(selectedCharacter.displayName)
            local isShared = selectedSpec.sharedCount > 1
            if isShared then
                detailProfile:SetText(string.format(
                    L("Shared with %d specializations"), selectedSpec.sharedCount))
                addon.settingsDesign.SetRegionColor(detailProfile, "positive")
                detailProfile:Show()
            else
                detailProfile:SetText("")
                detailProfile:Hide()
            end
            ui.SetSharingSummaryVisible(isShared)
        else
            detailCharacter:SetText(L("No visited characters"))
            detailContext:SetText("")
            detailProfile:SetText("")
            detailProfile:Hide()
            ui.SetSharingSummaryVisible(false)
        end

        ui.RefreshOperationControls(model, selectedCharacter, selectedSpec)
    end
    ui.refreshAll = ui.RefreshAll

    function ui.OpenManager(selectActive)
        if not addon.presetRuntime.CancelAllPreviews(true) then return end
        if selectActive then
            ui.selectedGUID = addon.profileRuntime.activeGUID
            ui.selectedSpecID = addon.profileRuntime.activeSpecID
            -- Current character/spec rows are sorted first. Reopening Profiles
            -- must not retain a stale scroll offset that leaves that selection
            -- outside the viewport.
            listScroll:SetVerticalScroll(0)
        end
        -- manager:OnShow performs the single authoritative refresh.
        manager:Show()
    end

    local function ToggleManager()
        if manager:IsShown() then
            manager:Hide()
            return
        end
        ui.OpenManager(true)
    end
    manageButton:SetScript("OnClick", ToggleManager)

    function ui.HideManager()
        if manager:IsShown() then manager:Hide() end
    end

    owner.profileHeader = header
    PushLocalizedLabel(function() ui.RefreshSafe() end)
    return header, manager
end

function addon.settingsUI.FormatSimpleDropdownOptionText(option)
    if not option then return L("None") end
    local text = L(option.label)
    local detail = option.detail
    if type(detail) == "string" and not issecretvalue(detail) and detail ~= "" then
        return text .. " (" .. detail .. ")"
    end
    return text
end

function addon.settingsUI.CreateSimpleDropdownRow(parent, rows, frameName, labelKey,
        options, cursor, getValue, onSelect)
    local rowY = cursor.y

    local label = parent:CreateFontString(nil, "OVERLAY")
    label:SetPoint("TOPLEFT", cursor.padX, rowY - 4)

    local dropdown = CreateFrame("Frame", frameName, parent, "UIDropDownMenuTemplate")
    -- Placeholder anchor; AlignSwatchColumn re-anchors after every row is built.
    dropdown:SetPoint("TOPLEFT", cursor.padX + 100, rowY + CONFIG_DROPDOWN_Y_OFFSET)
    UIDropDownMenu_SetWidth(dropdown, addon.settingsDesign.tokens.geometry.dropdownWidth)
    UIDropDownMenu_JustifyText(dropdown, "LEFT")
    addon.settingsDesign.StyleDropdown(dropdown, label)

    local function GetOptions()
        if type(options) == "function" then return options() end
        return options
    end

    local function ResolveOption(value)
        local resolvedOptions = GetOptions()
        for _, opt in ipairs(resolvedOptions) do
            if opt.value == value then return opt end
        end
        return resolvedOptions[1]
    end

    local function RefreshDropdownText()
        label:SetText(L(labelKey))
        UIDropDownMenu_SetText(dropdown,
            addon.settingsUI.FormatSimpleDropdownOptionText(ResolveOption(getValue())))
        addon.settingsDesign.RefreshControl(dropdown.statsProTrigger)
    end

    UIDropDownMenu_Initialize(dropdown, function()
        local current = ResolveOption(getValue())
        if not current then return end
        for _, opt in ipairs(GetOptions()) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = addon.settingsUI.FormatSimpleDropdownOptionText(opt)
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
        dropdownX_base = cursor.padX,
        dropdownY = rowY + CONFIG_DROPDOWN_Y_OFFSET,
        dropdownParent = parent,
    })
    cursor.y = rowY - 30
    return dropdown, label
end

function addon.settingsUI.ApplyFrameSize(self)
    local frame = self.settingsUI.frame
    if not frame then return false end
    local geometry = self.settingsDesign.tokens.geometry
    local frameWidth = geometry.windowWidth
    local parentHeight = self.settingsDesign.ReadUIParentHeight()
    if not parentHeight then return false end
    local maxHeight = math.max(geometry.minHeight,
        math.min(geometry.maxHeight, parentHeight * geometry.parentHeightRatio))
    if frame:GetWidth() == frameWidth and frame:GetHeight() == maxHeight then
        return true
    end
    frame:SetSize(frameWidth, maxHeight)
    return true
end

function addon.settingsUI.BuildShell(self)
    --[[ ===== Frame ===== ]]
    local configFrame = CreateFrame("Frame", "StatsProConfigFrame", UIParent,
        "BackdropTemplate")
    self.settingsUI.frame = configFrame
    local shellGeometry = self.settingsDesign.tokens.geometry
    local configFrameWidth = shellGeometry.windowWidth
    -- Seed a usable shell before the first parent read. A transient secret/invalid
    -- UIParent height must not leave the already-shown frame at its default geometry.
    configFrame:SetSize(configFrameWidth, shellGeometry.minHeight)

    -- WARNING: cap by parent so the title, profile actions, and scroll viewport stay on-screen.
    -- The 260px floor leaves a positive viewport below the fixed 156px shell header.
    self.settingsUI.ApplyFrameSize(self)

    configFrame:SetPoint("CENTER")
    self.settingsDesign.ApplySurface(configFrame, "window")
    configFrame:EnableMouse(true)
    configFrame:SetMovable(true)
    configFrame:RegisterForDrag("LeftButton")
    configFrame:SetScript("OnDragStart", configFrame.StartMoving)
    configFrame:SetScript("OnDragStop", configFrame.StopMovingOrSizing)
    configFrame:SetClampedToScreen(true)
    configFrame:SetFrameStrata("DIALOG")
    self.profileUI.PushSpecialFrame("StatsProConfigFrame")

    configFrame:HookScript("OnShow", function()
        self.settingsUI.ApplyFrameSize(self)
        self.panelEditRuntime.SetRequested(true)
        if not self.profileUI.manager or not self.profileUI.manager:IsShown() then
            self.profileUI.PushSpecialFrame("StatsProConfigFrame")
        end
    end)

    -- Auto-close font picker + Blizzard dropdown lists when Settings UI hides (e.g., /ss
    -- toggle, click X, Esc). Both are parented to UIParent (NOT configFrame) so neither
    -- auto-hides via parent — without these calls Esc-while-langDropdown-open leaves an
    -- orphan dropdown list above (and stale language-preview state until user clicks elsewhere
    -- to trigger DropDownList1:OnHide and restore the committed locale).
    configFrame:HookScript("OnHide", function()
        self.profileUI.CancelSpecialFrameRestore("StatsProConfigFrame")
        self.profileUI.RemoveSpecialFrame("StatsProConfigFrame")
        self.panelEditRuntime.SetRequested(false)
        self.profileRuntime.CancelOwnedMutationPopups()
        self.presetRuntime.ForceCancelAllPreviews()
        pcall(_G.StaticPopup_Hide, self.developerLinks.popupKey)
        self.profileRuntime.CloseOwnedDropdownMenus()
        if self.settingsUI.CloseColorPicker then self.settingsUI.CloseColorPicker() end
        self.settingsUI.fontPicker.Hide(self)
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
    self.settingsDesign.StyleCloseButton(closeX)

    -- Compact project links share the title bar with the existing close affordance.
    -- Keeping them here avoids a second, redundant close row and preserves content height.
    local headerLinkGroup = CreateFrame("Frame", nil, configFrame)
    headerLinkGroup:SetPoint("RIGHT", closeX, "LEFT", -self.settingsDesign.tokens.spacing.xxs, 0)
    headerLinkGroup:SetSize(shellGeometry.minHitTarget * 2
        + self.settingsDesign.tokens.spacing.xs, shellGeometry.minHitTarget)

    local contactButton = self.settingsDesign.CreateDeveloperLinkButton(
        headerLinkGroup, "StatsProContactLinkButton", "contact",
        { atlas = "transmog-icon-chat" }, self.settingsDesign.Color("accent"))
    contactButton:SetPoint("RIGHT", headerLinkGroup, "RIGHT", 0, 0)

    local koFiButton = self.settingsDesign.CreateDeveloperLinkButton(
        headerLinkGroup, "StatsProKoFiLinkButton", "koFiLink", {
            texture = "Interface\\COMMON\\friendship-heart",
            texCoords = { 0.21875, 0.78125, 0.09375, 0.6875 },
            -- The cropped heart sits low inside its source texture. Compensate for
            -- that transparent padding so its visible centre matches Chat and X.
            offsetY = 3,
        }, { 1, 0.36, 0.35, 1 })
    koFiButton:SetPoint("RIGHT", contactButton, "LEFT",
        -self.settingsDesign.tokens.spacing.xs, 0)

    titleMetadata:SetPoint("RIGHT", headerLinkGroup, "LEFT",
        -self.settingsDesign.tokens.spacing.sm, 0)
    titleMetadata:SetJustifyH("LEFT")
    titleMetadata:SetWordWrap(false)
    titleMetadata:SetMaxLines(1)

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
            closeX = closeX,
            headerLinkGroup = headerLinkGroup,
            koFiButton = koFiButton,
            contactButton = contactButton,
        }
    end

    local context = {
        frame = configFrame,
        scrollChild = scrollChild,
        scrollChildWidth = scrollChildWidth,
        displayTab = displayTab,
        statsTab = statsTab,
        layoutTab = layoutTab,
        switchToTab = SwitchToTab,
        layoutDropdownRows = {},
        displayDropdownRows = {},
    }
    self.settingsUI.context = context
    return context
end

function addon.settingsUI.BuildLayoutTab(self, context)
    --[[ ===== LAYOUT TAB ===== ]]
    local layoutTab = context.layoutTab
    local layoutDropdownRows = context.layoutDropdownRows
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
            "Lock Frames", "isLocked", cd.padX + CONFIG_COL_OFFSET, rowY, function()
                addon.panelEditRuntime.Refresh()
            end, 140)
        cd.y = rowY - 26

        local DISPLAY_MODES = {
            { value = "flat",      label = "Flat" },
            { value = "sectioned", label = "Sectioned" },
            { value = "split",     label = "Split" },
        }
        self.settingsUI.CreateSimpleDropdownRow(
            layoutTab,
            layoutDropdownRows,
            "StatsProDisplayModeDropdown",
            "Display Mode:",
            DISPLAY_MODES,
            cd,
            function() return GetDB("displayMode") end,
            function(value, opt, dropdown)
                if not addon.hudPresets.BeforeManualEdit("displayMode") then
                    CloseDropDownMenus()
                    return false
                end
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
                addon.panelEditRuntime.Refresh()
                addon.hudPresets.RefreshUI()
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
    self.settingsUI.CreateSimpleDropdownRow(
        layoutTab,
        layoutDropdownRows,
        "StatsProTargetSnapshotDropdown",
        "Tooltip Targets:",
        self.archonTargets.GetAvailableSnapshotOptions,
        cd,
        self.archonTargets.GetTargetSnapshotDropdownValue,
        self.archonTargets.SelectTargetSnapshotDropdownValue)
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
        self.settingsUI.CreateSimpleDropdownRow(
            layoutTab,
            layoutDropdownRows,
            "StatsProLabelStyleDropdown",
            "Label Style:",
            LABEL_STYLE_OPTIONS,
            cd,
            function() return NormalizeLabelStyle(GetDB("labelStyle")) end,
            function(value, opt, dropdown)
                if not addon.hudPresets.BeforeManualEdit("labelStyle") then
                    CloseDropDownMenus()
                    return false
                end
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
                addon.hudPresets.RefreshUI()
            end)
    end
    CreateCheckbox(layoutTab, "StatsProMatchColorCheck",
        "Match Value Color to Stat", "matchValueColorToStat", cd.padX, cd.y)
    CursorAdvance(cd, 22)

    AlignSwatchColumn(layoutDropdownRows, CONFIG_DROPDOWN_GAP)
    layoutTab.contentHeight = CursorUsed(cd)
    layoutTab:SetHeight(layoutTab.contentHeight)
end

function addon.settingsUI.fontPicker.BuildFontsList(self, retryPending)
    local picker = self.settingsUI.fontPicker
    local lsmLen = LSM and #LSM:List(LSM.MediaType.FONT) or 0
    if picker.cachedFontsList and picker.cachedFontsListLen == lsmLen
        and not (retryPending and picker.cachedFontsListHasPending) then
        return picker.cachedFontsList
    end

    local list = {}
    local hasPending = false
    if LSM then
        for _, name in ipairs(LSM:List(LSM.MediaType.FONT)) do
            local path = type(name) == "string" and self.fontRuntime.rawLSMPath(name) or nil
            local usable, status = self.fontRuntime.usableCatalogPath(path)
            if status == "pending" then hasPending = true end
            if usable then
                list[#list + 1] = {
                    name = name,
                    path = usable,
                    sortKey = self.fontRuntime.asciiLower(name),
                }
            end
        end
    else
        local clientLocale = GetLocale()
        for _, font in ipairs(BLIZZARD_SHIPPED_FONTS) do
            if not font.locale or font.locale == clientLocale then
                local usable, status = self.fontRuntime.usableCatalogPath(font.path)
                if status == "pending" then hasPending = true end
                if usable then
                    list[#list + 1] = {
                        name = font.name,
                        path = usable,
                        sortKey = self.fontRuntime.asciiLower(font.name),
                    }
                end
            end
        end
    end

    -- Stable sort independent of LSM internal ordering. ASCII-only sort keys leave
    -- localized UTF-8 font names byte-stable while avoiding repeated casing work.
    table.sort(list, function(left, right)
        if left.sortKey ~= right.sortKey then return left.sortKey < right.sortKey end
        if left.name ~= right.name then return left.name < right.name end
        return FontPathKey(left.path) < FontPathKey(right.path)
    end)
    -- Ordinary caption refreshes reuse the catalogue, but an explicit populate retries
    -- pending loose files even when the LSM list length has not changed.
    picker.cachedFontsList = list
    picker.cachedFontsListLen = lsmLen
    picker.cachedFontsListHasPending = hasPending
    return list
end

function addon.settingsUI.fontPicker.CurrentFontName(self)
    local current = self.fontRuntime.preferredPath()
    for _, font in ipairs(self.settingsUI.fontPicker.BuildFontsList(self)) do
        if SameFontPath(font.path, current) then return font.name end
    end
    return self.fontRuntime.catalogName(current)
end

function addon.settingsUI.fontPicker.RefreshCaption(self)
    local picker = self.settingsUI.fontPicker
    if picker.dropdown then
        UIDropDownMenu_SetText(picker.dropdown, picker.CurrentFontName(self))
    end
end

function addon.settingsUI.fontPicker.Preview(self, path)
    local picker = self.settingsUI.fontPicker
    if SameFontPath(path, picker.previewedPath) then return end
    local applied, effectiveFont = ApplyTextStyleToAllPanels(path, GetNumberDB("fontSize"))
    if not applied then return false end
    picker.previewedPath = effectiveFont
    ReflowAllPanels()
    return true
end

function addon.settingsUI.fontPicker.CancelPreview(self, force)
    local picker = self.settingsUI.fontPicker
    local hadPreview = picker.previewedPath ~= nil
    picker.previewedPath = nil
    if self.profileRuntime.suppressIntermediateRefresh then return hadPreview end
    if not force and not hadPreview then return false end
    local restored = self.fontRuntime.applyCommittedTextStyle(
        self.fontRuntime.preferredPath(), GetNumberDB("fontSize"), true, true)
    ReflowAllPanels()
    return restored
end

function addon.settingsUI.fontPicker.Pick(self, font)
    local picker = self.settingsUI.fontPicker
    if not self.fontRuntime.canMutateDB(true) then return false end
    local applied = self.fontRuntime.applyCommittedTextStyle(
        font.path, GetNumberDB("fontSize"), false, false)
    if not applied then return false end
    self.fontRuntime.clearSavedAutoFont()
    ReflowAllPanels()
    picker.previewedPath = nil
    picker.RefreshCaption(self)
    CloseDropDownMenus()
    local context = self.settingsUI.context
    if context and type(context.refreshLanguageWarning) == "function" then
        context.refreshLanguageWarning()
    end
    return true
end

function addon.settingsUI.fontPicker.Hide(self)
    local picker = self.settingsUI.fontPicker
    if picker.frame and picker.frame:IsShown() then
        picker.frame:Hide()
        return
    end
    if picker.catcher and picker.catcher:IsShown() then picker.catcher:Hide() end
    local trigger = picker.dropdown and picker.dropdown.statsProTrigger
    if trigger then
        trigger.statsProActive = false
        self.settingsDesign.RefreshControl(trigger)
    end
end

function addon.settingsUI.fontPicker.BuildFrame(self)
    local picker = self.settingsUI.fontPicker
    local context = self.settingsUI.context
    local config = context and context.frame
    local frameWidth = picker.columns * picker.buttonWidth
        + picker.padding * 2 + picker.scrollbarWidth
    local frameHeight = picker.visibleRows * picker.rowHeight + picker.padding * 2

    picker.frame = CreateFrame("Frame", "StatsProFontPicker", UIParent, "BackdropTemplate")
    picker.frame:SetSize(frameWidth, frameHeight)
    picker.frame:SetFrameStrata("DIALOG")
    picker.frame:SetFrameLevel((config and config:GetFrameLevel() or 100) + 50)
    picker.frame:SetClampedToScreen(true)
    self.settingsDesign.ApplySurface(picker.frame, "window")
    picker.frame:Hide()

    picker.catcher = CreateFrame("Frame", nil, UIParent)
    picker.catcher:SetAllPoints(UIParent)
    picker.catcher:SetFrameStrata("DIALOG")
    picker.catcher:SetFrameLevel(picker.frame:GetFrameLevel() - 1)
    picker.catcher:EnableMouse(true)
    picker.catcher:Hide()
    picker.catcher:SetScript("OnMouseDown", function() picker.Hide(self) end)
    picker.frame.statsProCatcher = picker.catcher

    local surface = self.settingsDesign.CreateTextureSurface(picker.frame, "viewport")
    surface:SetPoint("TOPLEFT", picker.padding - 2, -(picker.padding - 2))
    surface:SetPoint("BOTTOMRIGHT", -(picker.padding + picker.scrollbarWidth - 2),
        picker.padding - 2)
    picker.frame.statsProViewport = surface

    picker.scroll = CreateFrame(
        "ScrollFrame", "StatsProFontPickerScroll", picker.frame, "UIPanelScrollFrameTemplate")
    picker.scroll:SetPoint("TOPLEFT", picker.padding, -picker.padding)
    picker.scroll:SetPoint("BOTTOMRIGHT", -(picker.padding + picker.scrollbarWidth), picker.padding)
    self.settingsDesign.StyleScrollFrame(picker.scroll)

    picker.content = CreateFrame("Frame", nil, picker.scroll)
    picker.content:SetSize(picker.columns * picker.buttonWidth, 100)
    picker.scroll:SetScrollChild(picker.content)

    picker.frame:SetScript("OnHide", function()
        -- OnHide is the single restore path for Escape, click-outside, commit, and
        -- Settings teardown. Invalidate every delayed pending-file retry first.
        picker.retryGeneration = picker.retryGeneration + 1
        self.profileUI.RemoveSpecialFrame("StatsProFontPicker")
        if picker.catcher then picker.catcher:Hide() end
        local trigger = picker.dropdown and picker.dropdown.statsProTrigger
        if trigger then
            trigger.statsProActive = false
            self.settingsDesign.RefreshControl(trigger)
        end
        picker.CancelPreview(self, true)
        local owner = self.settingsUI.context and self.settingsUI.context.frame
        if owner and owner:IsShown()
            and not (self.profileUI.manager and self.profileUI.manager:IsShown())
            and not (self.profileUI.operationDialog
                and self.profileUI.operationDialog:IsShown()) then
            -- Blizzard walks UISpecialFrames live. Restore Settings on the next tick
            -- so one Escape cannot close both the picker and its owner.
            self.profileUI.DeferSpecialFrameRestore("StatsProConfigFrame", function()
                return owner:IsShown() and not picker.frame:IsShown()
                    and not (self.profileUI.manager and self.profileUI.manager:IsShown())
                    and not (self.profileUI.operationDialog
                        and self.profileUI.operationDialog:IsShown())
            end)
        else
            self.profileUI.CancelSpecialFrameRestore("StatsProConfigFrame")
            self.profileUI.RemoveSpecialFrame("StatsProConfigFrame")
        end
    end)
end

function addon.settingsUI.fontPicker.Populate(self)
    local picker = self.settingsUI.fontPicker
    local fonts = picker.BuildFontsList(self, true)
    local currentPath = self.fontRuntime.preferredPath()
    local rows = math.ceil(#fonts / picker.columns)
    local currentRow
    local hoveredVisibleButton

    picker.content:SetHeight(math.max(rows * picker.rowHeight, 1))
    for index, font in ipairs(fonts) do
        local button = picker.buttons[index]
        if not button then
            button = CreateFrame("Button", nil, picker.content)
            button:SetSize(picker.buttonWidth, picker.rowHeight)
            button.bg = button:CreateTexture(nil, "BACKGROUND")
            button.bg:SetAllPoints()
            button.bg:SetColorTexture(0, 0, 0, 0)
            button.text = button:CreateFontString(nil, "OVERLAY")
            button.text:SetPoint("LEFT", 6, 0)
            button.text:SetPoint("RIGHT", -4, 0)
            button.text:SetWordWrap(false)
            button.text:SetMaxLines(1)
            self.settingsDesign.StyleListRow(button, button.text, "body")
            -- The generic rowHover fill is intentionally subtle and became
            -- effectively invisible while the live font preview changed the HUD.
            -- Keep a dedicated Button highlight so the hovered font remains clear.
            button:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
            local highlight = button:GetHighlightTexture()
            local hoverColor = self.settingsDesign.Color("accent")
            highlight:SetVertexColor(
                hoverColor[1], hoverColor[2], hoverColor[3], 0.18)
            button.statsProFontHoverTexture = highlight
            button.text:SetJustifyH("LEFT")

            button:SetScript("OnEnter", function(target)
                picker.hoverGeneration = picker.hoverGeneration + 1
                if picker.Preview(self, target.fontPath) == false and picker.previewedPath then
                    picker.CancelPreview(self)
                end
            end)
            button:SetScript("OnLeave", function()
                local generation = picker.hoverGeneration
                C_Timer.After(0, function()
                    if generation == picker.hoverGeneration then picker.CancelPreview(self) end
                end)
            end)
            button:SetScript("OnClick", function(target)
                if picker.Pick(self, { name = target.fontName, path = target.fontPath }) then
                    picker.Hide(self)
                end
            end)
            picker.buttons[index] = button
        end

        local row = math.floor((index - 1) / picker.columns)
        local column = (index - 1) % picker.columns
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", column * picker.buttonWidth, -row * picker.rowHeight)
        button.fontName = font.name
        button.fontPath = font.path
        button.text:SetText(font.name)
        if SameFontPath(font.path, currentPath) then
            self.settingsDesign.SetListRowSelected(button, true)
            currentRow = row
        else
            self.settingsDesign.SetListRowSelected(button, false)
        end
        button:Show()
        if button.statsProHovered == true then hoveredVisibleButton = button end
    end

    for index = #fonts + 1, #picker.buttons do picker.buttons[index]:Hide() end
    -- A visible retry may rebind a pooled button without firing leave/enter. Keep
    -- tooltip and preview attached to the row that is actually under the pointer.
    if hoveredVisibleButton then
        self.settingsDesign.RefreshOwnedControlTooltip(hoveredVisibleButton)
        if not SameFontPath(hoveredVisibleButton.fontPath, picker.previewedPath) then
            if picker.Preview(self, hoveredVisibleButton.fontPath) == false
                and picker.previewedPath then
                picker.CancelPreview(self)
            end
        end
    elseif picker.previewedPath then
        picker.CancelPreview(self)
    end

    if currentRow then
        local centerOffset = math.floor(picker.visibleRows / 2)
        local targetScroll = math.max(0, (currentRow - centerOffset) * picker.rowHeight)
        local maxScroll = math.max(0,
            rows * picker.rowHeight - picker.visibleRows * picker.rowHeight)
        picker.scroll:SetVerticalScroll(math.min(targetScroll, maxScroll))
    else
        picker.scroll:SetVerticalScroll(0)
    end
end

function addon.settingsUI.fontPicker.SchedulePendingRetry(self, generation, attempt)
    local picker = self.settingsUI.fontPicker
    local delays = self.fontRuntime.pendingRetryDelays
    if not picker.cachedFontsListHasPending or attempt > #delays then return end
    C_Timer.After(delays[attempt], function()
        -- Hidden/reopened pickers own a newer generation; stale probes are no-ops.
        if generation ~= picker.retryGeneration
            or not picker.frame or not picker.frame:IsShown() then
            return
        end
        picker.Populate(self)
        picker.SchedulePendingRetry(self, generation, attempt + 1)
    end)
end

function addon.settingsUI.fontPicker.Show(self)
    local picker = self.settingsUI.fontPicker
    if not picker.initialized then
        picker.BuildFrame(self)
        picker.initialized = true
    end
    picker.previewedPath = nil
    picker.hoverGeneration = picker.hoverGeneration + 1
    picker.retryGeneration = picker.retryGeneration + 1
    picker.Populate(self)

    local context = self.settingsUI.context
    local config = context and context.frame
    picker.frame:SetFrameLevel((config and config:GetFrameLevel() or 100) + 50)
    picker.catcher:SetFrameLevel(picker.frame:GetFrameLevel() - 1)
    local dropdown = picker.dropdown
    local button = _G["StatsProFontDropdownButton"] or dropdown.Button
    picker.frame:ClearAllPoints()
    if button then
        picker.frame:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, -2)
    else
        picker.frame:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 16, -2)
    end

    self.profileUI.CancelSpecialFrameRestore("StatsProConfigFrame")
    self.profileUI.RemoveSpecialFrame("StatsProConfigFrame")
    self.profileUI.PushSpecialFrame("StatsProFontPicker")
    picker.catcher:Show()
    picker.frame:Show()
    picker.SchedulePendingRetry(self, picker.retryGeneration, 1)
    if dropdown.statsProTrigger then
        dropdown.statsProTrigger.statsProActive = true
        self.settingsDesign.RefreshControl(dropdown.statsProTrigger)
    end
end

function addon.settingsUI.fontPicker.Toggle(self)
    local picker = self.settingsUI.fontPicker
    if picker.frame and picker.frame:IsShown() then
        picker.Hide(self)
    else
        picker.Show(self)
    end
end

function addon.settingsUI.fontPicker.RegisterLSMCallback(self)
    local picker = self.settingsUI.fontPicker
    if picker.lsmCallbackRegistered or not LSM
        or type(LSM.RegisterCallback) ~= "function" then return end
    picker.lsmCallbackRegistered = true
    -- LSM registration is add-only in normal play. Invalidate synchronously, then
    -- coalesce registration bursts into one next-tick visible-picker refresh.
    LSM.RegisterCallback(self, "LibSharedMedia_Registered", function(_, mediaType)
        if mediaType ~= LSM.MediaType.FONT then return end
        picker.cachedFontsList = nil
        picker.cachedFontsListLen = -1
        picker.cachedFontsListHasPending = false
        if picker.catalogRefreshScheduled then return end
        picker.catalogRefreshScheduled = true
        C_Timer.After(0, function()
            picker.catalogRefreshScheduled = false
            picker.RefreshCaption(self)
            if not picker.frame or not picker.frame:IsShown() then return end
            picker.retryGeneration = picker.retryGeneration + 1
            picker.Populate(self)
            picker.SchedulePendingRetry(self, picker.retryGeneration, 1)
        end)
    end)
end

function addon.settingsUI.fontPicker.Initialize(self, context, dropdown)
    local picker = self.settingsUI.fontPicker
    picker.dropdown = dropdown
    picker.columns = 3
    picker.buttonWidth = 160
    picker.rowHeight = self.settingsDesign.tokens.geometry.fontRowHeight
    picker.padding = 8
    picker.scrollbarWidth = 22
    picker.visibleRows = 14
    context.refreshLanguageWarning = context.refreshLanguageWarning or function() end

    picker.RegisterLSMCallback(self)
    picker.RefreshCaption(self)
    PushRefresher(function() picker.RefreshCaption(self) end)

    local trigger = _G["StatsProFontDropdownButton"] or dropdown.Button
    if trigger then
        trigger:SetScript("OnClick", function()
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            picker.Toggle(self)
        end)
    end
end

function addon.settingsUI.localization.Preview(self, value)
    local state = self.settingsUI.localization
    local locale = value == "auto"
        and self.NormalizeOutputLocale(GetLocale()) or value
    -- Dedup repeated hover events without comparing or caching rendered strings.
    if locale == state.previewLocale then return end
    state.previewLocale = locale
    cached.activeLabels = LABELS_BY_LOCALE[locale] or LABELS_BY_LOCALE.enUS
    cached.activeLabelsLocale = LABELS_BY_LOCALE[locale] and locale or "enUS"

    -- Always evaluate the hovered locale against the committed baseline. Otherwise
    -- ruRU -> fallback -> deDE would compare against the fallback and fail to restore.
    local requirement = LOCALE_GLYPH_REQ[locale] or GLYPH_LATIN
    local current = self.fontRuntime.currentPath()
    local fallback = FindCompatibleFont(current, requirement)
    if fallback and not SameFontPath(fallback, current) then
        local applied = ApplyTextStyleToAllPanels(fallback, GetNumberDB("fontSize"))
        if applied then state.previewSwappedFont = true end
    elseif state.previewSwappedFont then
        local restored = ApplyTextStyleToAllPanels(
            current, GetNumberDB("fontSize"), true)
        if restored then state.previewSwappedFont = false end
    end

    state.previewActive = true
    ApplyConfigFont(ResolveConfigFont(locale))
    RefreshConfigLocalization()
    self:RunUpdateStatsSafe()
end

function addon.settingsUI.localization.CancelPreview(self)
    local state = self.settingsUI.localization
    if not state.previewActive then return end
    if self.profileRuntime.suppressIntermediateRefresh then
        state.previewActive = false
        state.previewSwappedFont = false
        state.previewLocale = nil
        return
    end

    local active = ResolveActiveLocale()
    cached.activeLabels = LABELS_BY_LOCALE[active] or LABELS_BY_LOCALE.enUS
    cached.activeLabelsLocale = LABELS_BY_LOCALE[active] and active or "enUS"
    if state.previewSwappedFont then
        local restored = self.fontRuntime.applyCommittedTextStyle(
            self.fontRuntime.preferredPath(), GetNumberDB("fontSize"), true, true)
        if restored then state.previewSwappedFont = false end
    end
    state.previewActive = false
    state.previewLocale = nil
    ApplyConfigFont(ResolveConfigFont(active))
    RefreshConfigLocalization()
    self:RunUpdateStatsSafe()
end

function addon.settingsUI.localization.CommitPreview(self)
    local state = self.settingsUI.localization
    if state.previewSwappedFont then
        local restored = self.fontRuntime.applyCommittedTextStyle(
            self.fontRuntime.preferredPath(), GetNumberDB("fontSize"), true, true)
        if restored then state.previewSwappedFont = false end
    end
    state.previewActive = false
    state.previewLocale = nil
end

function addon.settingsUI.BuildAppearanceTab(self, context)
    --[[ ===== APPEARANCE TAB (Lua var: displayTab) ===== ]]
    local displayTab = context.displayTab
    local displayDropdownRows = context.displayDropdownRows
    local scrollChild = context.scrollChild
    local scrollChildWidth = context.scrollChildWidth
    local ownerFrame = context.frame
    local cd = NewCursor(displayTab, 12, -8)

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
            local baseSurface = self.settingsDesign.CreateTextureSurface(button, "raised")
            baseSurface:SetAllPoints(button)
            button.statsProSurface = baseSurface
            local selectionRail = button:CreateTexture(nil, "ARTWORK")
            selectionRail:SetPoint("TOPLEFT", 0, -4)
            selectionRail:SetPoint("BOTTOMLEFT", 0, 4)
            selectionRail:SetWidth(2)
            local selectionColor = self.settingsDesign.Color("accent")
            selectionRail:SetColorTexture(
                selectionColor[1], selectionColor[2], selectionColor[3], selectionColor[4])
            selectionRail:Hide()
            button.statsProSelectionRail = selectionRail
            local label = button:CreateFontString(nil, "OVERLAY")
            self.settingsDesign.StyleListRow(button, label, "body")
            label:SetPoint("LEFT", 10, 0)
            label:SetPoint("RIGHT", -58, 0)
            label:SetJustifyH("LEFT")
            label:SetWordWrap(false)
            label:SetMaxLines(1)
            PushLocalizedLabel(function() label:SetText(L(definition.label)) end)
            local preview = {}
            for previewIndex, colorKey in ipairs({ "crit", "haste", "mastery" }) do
                local color = definition.colors[colorKey]
                local swatch = button:CreateTexture(nil, "ARTWORK")
                swatch:SetPoint("RIGHT", button, "RIGHT", -10 - (3 - previewIndex) * 12, 0)
                swatch:SetSize(7, 7)
                swatch:SetColorTexture(color.r, color.g, color.b, 1)
                preview[previewIndex] = swatch
            end
            button.statsProPresetPreview = preview
            self.settingsDesign.RegisterMutationControl(button)
            button:SetScript("OnClick", function()
                local ok, reason = self.appearancePresets.StartPreview(presetID)
                self.presetRuntime.ReportStartResult(ok, reason)
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
        presetUI.compactBodyTop = cd.y

        local warning = displayTab:CreateFontString(nil, "OVERLAY")
        warning:SetPoint("TOPLEFT", cd.padX, cd.y)
        warning:SetSize(426, 36)
        warning:SetJustifyH("LEFT")
        warning:SetJustifyV("TOP")
        warning:SetWordWrap(true)
        self.settingsDesign.StyleWarning(displayTab, warning)
        self.settingsDesign.SetWarningVisible(warning, false)
        presetUI.warning = warning
        presetUI.warningY = cd.y
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
    end

    -- Hidden preview actions must not reserve a permanent hole in the Appearance tab.
    -- The lower body moves only when a live preview actually needs actions and, for a
    -- shared profile, its warning. Keeping the body under one parent preserves every
    -- Typography/Readability/Localization relative anchor during the reflow.
    local appearanceBody = CreateFrame("Frame", nil, displayTab)
    appearanceBody:SetPoint("TOPLEFT", displayTab, "TOPLEFT", 0, 0)
    appearanceBody:SetPoint("TOPRIGHT", displayTab, "TOPRIGHT", 0, 0)
    cd = NewCursor(appearanceBody, 12, -4)

    -- Typography section: text rendering (font face + size).
    CursorSection(cd, "Typography")
    do
        local rowY = cd.y

        local fontLabel = appearanceBody:CreateFontString(nil, "OVERLAY")
        RegisterConfigFont(fontLabel, 12, nil, "role:body")
        fontLabel:SetPoint("TOPLEFT", cd.padX, rowY)
        PushLocalizedLabel(function() fontLabel:SetText(L("Font:")) end)

        -- SharedMedia can register faces after Settings construction. The stateful
        -- picker owns catalogue invalidation, pending probes, pooling, hover preview,
        -- and Escape restoration without rebuilding the Settings shell.
        local fontDropdown = CreateFrame("Frame", "StatsProFontDropdown", appearanceBody,
            "UIDropDownMenuTemplate")
        fontDropdown:SetPoint("TOPLEFT", cd.padX + 100,
            rowY + CONFIG_DROPDOWN_Y_OFFSET)
        UIDropDownMenu_SetWidth(fontDropdown,
            addon.settingsDesign.tokens.geometry.dropdownWidth)
        UIDropDownMenu_JustifyText(fontDropdown, "LEFT")
        addon.settingsDesign.StyleDropdown(fontDropdown, fontLabel)
        self.settingsUI.fontPicker.Initialize(self, context, fontDropdown)


        tinsert(displayDropdownRows, {
            text = fontLabel, dropdown = fontDropdown,
            maxTextWidth = addon.settingsDesign.tokens.geometry.dropdownLabelMaxWidth,
            dropdownX_base = cd.padX, dropdownY = rowY + CONFIG_DROPDOWN_Y_OFFSET, dropdownParent = appearanceBody,
        })

        -- WHY no text-alignment control: three-column rendering pins labels RIGHT,
        -- ratings RIGHT, values LEFT. Legacy saves may still carry textAlign, but
        -- migration preserves unknown fields and nothing reads it at runtime.

        cd.y = rowY - 32
    end

    -- Font Size slider — text rendering size. Naturally pairs with Font dropdown above.
    -- ReflowAllPanels (not UpdateStats) for the same reason as font picker: size change
    -- only affects measurements, not text content. Slider fires OnValueChanged per
    -- step-tick during drag (8→9→...→32 = up to 25 events), intentionally preserving
    -- live visual preview because this control is adjusted rarely but benefits hugely
    -- from immediate feedback.
    CreateConfigSlider(appearanceBody, "StatsProFontSlider", "Font Size:", "fontSize", cd,
        8, 32, 1, "8", "32", "%d",
        function()
            local applied = self.fontRuntime.applyCommittedTextStyle(
                self.fontRuntime.preferredPath(), GetNumberDB("fontSize"), false, true)
            if applied then ReflowAllPanels() end
            return applied
        end)

    -- Text Opacity slider — adjust panel text transparency. Stored as INT 25-100 in DB
    -- (matches CreateConfigSlider's format-string contract); cached as float 0.25-1.0
    -- for SetAlpha. Default 100 = zero behavior change for existing users.
    CreateConfigSlider(appearanceBody, "StatsProTextAlphaSlider", "Text Opacity:", "textAlpha", cd,
        25, 100, 5, "25%", "100%", "%d%%",
        function(value)
            cached.textAlpha = value / 100
            ApplyTextAlphaToAllPanels(cached.textAlpha)
        end)

    CursorGap(cd, 4)
    CursorSection(cd, "Readability")
    self.settingsUI.CreateSimpleDropdownRow(
        appearanceBody,
        displayDropdownRows,
        "StatsProTextOutlineDropdown",
        "Text Outline:",
        self.readabilityConfig.textOutlineOptions,
        cd,
        self.readabilityConfig.getTextOutlineStyle,
        self.readabilityConfig.selectTextOutlineStyle)

    CreateConfigSlider(appearanceBody, "StatsProPanelBackgroundSlider", "Panel Background:", "panelBackgroundAlpha", cd,
        0, 80, 5, "0%", "80%", "%d%%",
        self.readabilityConfig.changePanelBackgroundAlpha)

    CursorGap(cd, 4)

    -- Localization section. Always shown — useful even on enUS for screenshot-locale
    -- picks (中文 / 한국어). Placed at bottom: typically set once on install and
    -- never revisited.
    CursorSection(cd, "Localization")
    do
        local rowY = cd.y

        local langLabel = appearanceBody:CreateFontString(nil, "OVERLAY")
        RegisterConfigFont(langLabel, 12, nil, "role:body")
        langLabel:SetPoint("TOPLEFT", cd.padX, rowY)
        PushLocalizedLabel(function() langLabel:SetText(L("Language:")) end)

        -- Linear scan LANGUAGE_OPTIONS for opt.value == value match. Four callsites.
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
        -- for the collapsed field while keeping locale variants distinguishable.
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

        local langDropdown = CreateFrame("Frame", "StatsProLanguageDropdown", appearanceBody, "UIDropDownMenuTemplate")
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
                        self.settingsUI.localization.CancelPreview(self)
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
                    -- drifted. The stable cancel method does the same conditional restore for
                    -- the close-without-pick path.
                    -- ApplyConfigFont is unconditionally called inside MAS so the settings
                    -- UI doesn't share this asymmetry — panels are the only side affected.
                    self.settingsUI.localization.CommitPreview(self)
                    -- WHY: auto-switch may have changed db.font; PushRefresher only fires on Reset.
                    self.settingsUI.fontPicker.RefreshCaption(self)
                    UIDropDownMenu_SetText(langDropdown, CompactLabel(opt))
                    CloseDropDownMenus()
                    context.refreshLanguageWarning()
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
                        self.settingsUI.localization.Preview(self, button.value)
                    end)
                    btn._statsProLangPreviewHooked = true
                end
            end
        end

        if DropDownList1 then
            DropDownList1:HookScript("OnShow", HookLanguageMenuButtons)
            DropDownList1:HookScript("OnHide", function()
                self.settingsUI.localization.CancelPreview(self)
            end)
        end

        -- 24 + cd.gap (6) = 30 effective; matches Display Mode dropdown row pattern.
        CursorAdvance(cd, 24)

        local langWarn = appearanceBody:CreateFontString(nil, "OVERLAY")
        addon.settingsDesign.StyleWarning(appearanceBody, langWarn)
        local langWarnHeight = addon.settingsDesign.tokens.geometry.warningHeight
        langWarn:SetPoint("TOPLEFT", cd.padX, cd.y)
        langWarn:SetWidth(scrollChildWidth - (cd.padX * 2))
        langWarn:SetHeight(langWarnHeight)
        langWarn:SetJustifyH("LEFT")
        langWarn:SetJustifyV("TOP")
        langWarn:SetWordWrap(true)
        langWarn:SetMaxLines(2)
        langWarn:SetText("")
        if self.__statsproSmoke == true then ownerFrame.languageWarning = langWarn end

        context.refreshLanguageWarning = function()
            local active = ResolveActiveLocale()
            local req    = LOCALE_GLYPH_REQ[active] or GLYPH_LATIN
            if FontSupports(self.fontRuntime.preferredPath(), req) then
                langWarn:SetText("")
                addon.settingsDesign.SetWarningVisible(langWarn, false)
            else
                local requirementLabel = L(
                    addon.fontRuntime.GlyphRequirementLabelKey(req))
                langWarn:SetText(string.format(L(
                    "|cffffaa44⚠|r The selected font may not render %s correctly. Pick a SharedMedia font with proper coverage."
                ), requirementLabel))
                addon.settingsDesign.SetWarningVisible(langWarn, true)
            end
        end

        -- WHY register as localized: warning wording and the presentation-only requirement
        -- label both change with the output locale. Internal font-coverage tokens never cross
        -- this UI boundary. The language commit handler also calls this for an immediate recheck.
        local function RefreshLanguageControls()
            UIDropDownMenu_SetText(langDropdown, CurrentLabel())
            context.refreshLanguageWarning()
        end
        PushLocalizedLabel(RefreshLanguageControls)
        -- WHY fixed two-line reservation: localized warnings wrap inside the padded
        -- scroll content. Avoid GetStringHeight arithmetic because the measurement can
        -- become secret-tainted when the active text contains restricted glyph data.
        CursorAdvance(cd, langWarnHeight)

        -- Reset button: re-syncs both dropdown SetText and warning state.
        PushRefresher(RefreshLanguageControls)

        tinsert(displayDropdownRows, {
            text = langLabel, dropdown = langDropdown,
            maxTextWidth = addon.settingsDesign.tokens.geometry.dropdownLabelMaxWidth,
            dropdownX_base = cd.padX, dropdownY = rowY + CONFIG_DROPDOWN_Y_OFFSET, dropdownParent = appearanceBody,
        })
    end

    -- Align Appearance-tab dropdowns into one column. Re-runs on language change via
    -- RefreshConfigLocalization (alignmentGroups iteration), so locale label-width shifts
    -- automatically widen or shrink the column.
    AlignSwatchColumn(displayDropdownRows, CONFIG_DROPDOWN_GAP)

    appearanceBody.contentHeight = CursorUsed(cd)
    appearanceBody:SetHeight(appearanceBody.contentHeight)
    -- SYNC: shell/localization verification reads the tab-level section registry.
    -- The movable body owns these surfaces visually, but the tab remains their logical
    -- settings section owner.
    for _, section in ipairs(appearanceBody.statsProSections or {}) do
        tinsert(displayTab.statsProSections, section)
    end
    do
        local presetUI = self.appearancePresets.ui
        local cancel = presetUI and presetUI.cancel
        local apply = presetUI and presetUI.apply
        local warningY = presetUI and presetUI.warningY
        local compactBodyTop = presetUI and presetUI.compactBodyTop
        if not presetUI or not cancel or not apply
            or type(warningY) ~= "number" or type(compactBodyTop) ~= "number" then
            error("StatsPro appearance preset layout is incomplete")
        end
        presetUI.lowerBody = appearanceBody
        presetUI.refreshLayout = function(hasSession, warningVisible)
            local actionY = warningY
            if hasSession and warningVisible then
                actionY = actionY - 42
            end

            cancel:ClearAllPoints()
            cancel:SetPoint("TOPRIGHT", displayTab, "TOPRIGHT", -140, actionY)
            apply:ClearAllPoints()
            apply:SetPoint("TOPRIGHT", displayTab, "TOPRIGHT", -12, actionY)

            local bodyTop = compactBodyTop
            if hasSession then
                bodyTop = actionY - 32
            end
            appearanceBody:ClearAllPoints()
            appearanceBody:SetPoint("TOPLEFT", displayTab, "TOPLEFT", 0, bodyTop)
            appearanceBody:SetPoint("TOPRIGHT", displayTab, "TOPRIGHT", 0, bodyTop)

            displayTab.contentHeight = math.abs(bodyTop) + appearanceBody.contentHeight
            displayTab:SetHeight(displayTab.contentHeight)
            if ownerFrame.activeTabIndex == 3 then
                scrollChild:SetHeight(displayTab.contentHeight)
            end
        end
        self.appearancePresets.RefreshUI()
    end
end

addon.settingsUI.dependentStatGroups = {
    {
        section = "Offensive Stats",
        masterName = "StatsProOffensiveCheck",
        masterLabel = "Show Offensive Stats",
        masterKey = "showOffensive",
        hideZeroName = "StatsProHideZeroOffCheck",
        hideZeroKey = "hideZeroOffensive",
        entries = {
            { name = "StatsProCritCheck", label = "Show Crit", key = "showCrit",
                color = "crit", column = 1, row = 0 },
            { name = "StatsProHasteCheck", label = "Show Haste", key = "showHaste",
                color = "haste", column = 2, row = 0 },
            { name = "StatsProMasteryCheck", label = "Show Mastery", key = "showMastery",
                color = "mastery", column = 1, row = 1 },
            { name = "StatsProVersCheck", label = "Show Versatility",
                key = "showVersatility", color = "versatility", column = 2, row = 1 },
        },
    },
    {
        section = "Tertiary Stats",
        masterName = "StatsProTertiaryCheck",
        masterLabel = "Show Tertiary Stats",
        masterKey = "showTertiary",
        hideZeroName = "StatsProHideZeroCheck",
        hideZeroKey = "hideZeroTertiary",
        entries = {
            { name = "StatsProLeechCheck", label = "Show Leech", key = "showLeech",
                color = "leech", column = 1, row = 0 },
            { name = "StatsProAvoidanceCheck", label = "Show Avoidance",
                key = "showAvoidance", color = "avoidance", column = 2, row = 0 },
            { name = "StatsProSpeedCheck", label = "Show Speed", key = "showSpeed",
                color = "speed", column = 1, row = 1 },
        },
    },
    {
        section = "Defensive Stats",
        masterName = "StatsProDefensiveCheck",
        masterLabel = "Show Defensive Stats",
        masterKey = "showDefensive",
        hideZeroName = "StatsProHideZeroDefCheck",
        hideZeroKey = "hideZeroDefensive",
        entries = {
            { name = "StatsProDodgeCheck", label = "Show Dodge", key = "showDodge",
                color = "dodge", column = 1, row = 0 },
            { name = "StatsProParryCheck", label = "Show Parry", key = "showParry",
                color = "parry", column = 2, row = 0 },
            { name = "StatsProBlockCheck", label = "Show Block", key = "showBlock",
                color = "block", column = 1, row = 1 },
            { name = "StatsProArmorCheck", label = "Show Armor", key = "showArmor",
                color = "armor", column = 2, row = 1 },
            { name = "StatsProStaggerCheck", label = "Show Stagger",
                key = "showStagger", color = "stagger", column = 1, row = 2 },
        },
    },
}

function addon.settingsUI.BuildDependentStatGroup(self, parent, cursor, definition)
    CursorSection(cursor, definition.section)
    local rowY = cursor.y
    local subControls = {}
    local function ApplySubControlsEnabled(masterOn)
        for _, control in ipairs(subControls) do
            SetCheckboxEnabled(control, masterOn, definition.masterLabel)
        end
    end

    CreateCheckbox(parent, definition.masterName, definition.masterLabel,
        definition.masterKey, cursor.padX, rowY,
        function(checked) ApplySubControlsEnabled(checked) end)
    CreateCheckbox(parent, definition.hideZeroName, "Hide Zero Values",
        definition.hideZeroKey, cursor.padX + CONFIG_COL_OFFSET, rowY)
    cursor.y = rowY - 26

    local columns = { {}, {} }
    local rowCount = 0
    local rowPitch = 22 + cursor.gap
    for _, entry in ipairs(definition.entries) do
        local control, swatch, text = CreateCheckboxColor(parent, entry.name,
            entry.label, entry.key, entry.color,
            cursor.padX + (entry.column - 1) * CONFIG_COL_OFFSET,
            cursor.y - entry.row * rowPitch)
        subControls[#subControls + 1] = control
        columns[entry.column][#columns[entry.column] + 1] = {
            text = text,
            swatch = swatch,
        }
        rowCount = math.max(rowCount, entry.row + 1)
    end
    cursor.y = cursor.y - rowCount * rowPitch
    AlignSwatchColumn(columns[1])
    AlignSwatchColumn(columns[2])
    ApplySubControlsEnabled(GetBoolDB(definition.masterKey))
    PushRefresher(function()
        ApplySubControlsEnabled(GetBoolDB(definition.masterKey))
    end)
end

function addon.settingsUI.BuildStatsTab(self, context)
    --[[ ===== STATS TAB ===== ]]
    local statsTab = context.statsTab
    local scrollChild = context.scrollChild
    local ownerFrame = context.frame
    local cs = NewCursor(statsTab, 12, -8)

    CursorSection(cs, "Quick Setup")
    local setupUI = self.hudPresets.BuildCardList(statsTab, cs.padX, cs.y, 426)
    local statsBody = CreateFrame("Frame", nil, statsTab)
    statsBody:SetPoint("TOPLEFT", statsTab, "TOPLEFT", 0, setupUI.compactBodyTop)
    statsBody:SetPoint("TOPRIGHT", statsTab, "TOPRIGHT", 0, setupUI.compactBodyTop)

    local setupCancel = self.settingsDesign.CreateShellButton(statsTab, nil, "field")
    setupCancel:SetSize(160, 28)
    PushLocalizedLabel(function() setupCancel:SetText(L("Cancel preview")) end)
    setupCancel:SetScript("OnClick", function() self.hudPresets.CancelPreview() end)
    setupUI.cancel = setupCancel

    local setupApply = self.settingsDesign.CreateShellButton(statsTab, nil, "primary")
    setupApply:SetSize(120, 28)
    PushLocalizedLabel(function() setupApply:SetText(L("Apply")) end)
    setupApply.statsProBlocksInCombat = true
    self.settingsDesign.RegisterMutationControl(setupApply)
    setupApply:SetScript("OnClick", function()
        local ok, reason = self.hudPresets.ApplyPreview()
        if not ok then PrintMsg(self.profileUI.OperationErrorText(reason)) end
    end)
    setupUI.apply = setupApply
    setupUI.refreshLayout = function(hasSession, warningVisible)
        local actionY = setupUI.warningY
        if hasSession and warningVisible then actionY = actionY - 42 end
        setupCancel:ClearAllPoints()
        setupCancel:SetPoint("TOPRIGHT", statsTab, "TOPRIGHT", -140, actionY)
        setupApply:ClearAllPoints()
        setupApply:SetPoint("TOPRIGHT", statsTab, "TOPRIGHT", -12, actionY)
        local bodyTop = setupUI.compactBodyTop
        if hasSession then bodyTop = actionY - 36 end
        setupUI.bodyTop = bodyTop
        statsBody:ClearAllPoints()
        statsBody:SetPoint("TOPLEFT", statsTab, "TOPLEFT", 0, bodyTop)
        statsBody:SetPoint("TOPRIGHT", statsTab, "TOPRIGHT", 0, bodyTop)
        if statsBody.contentHeight then
            statsTab.contentHeight = math.abs(bodyTop) + statsBody.contentHeight
            statsTab:SetHeight(statsTab.contentHeight)
            if ownerFrame.activeTabIndex == 1 then
                scrollChild:SetHeight(statsTab.contentHeight)
            end
        end
    end
    if self.__statsproSmoke == true then
        statsTab.quickSetupView = setupUI
        statsTab.statsBody = statsBody
    end

    cs = NewCursor(statsBody, 12, -4)

    -- Character-sheet rows. Inline color swatches per row drive label color +
    -- matchValueColorToStat coloring.
    CursorSection(cs, "Character")
    do
        local rowY = cs.y
        local leftRows, rightRows = {}, {}
        local _, sw, txt
        _, sw, txt = CreateCheckboxColor(statsBody, "StatsProMainStatCheck",
            "Show Main Stat", "showMainStat", "mainStat", cs.padX,                       rowY)
        leftRows[#leftRows + 1]   = { text = txt, swatch = sw }
        _, sw, txt = CreateCheckboxColor(statsBody, "StatsProStaminaCheck",
            "Show Stamina",   "showStamina",  "stamina",  cs.padX + CONFIG_COL_OFFSET, rowY)
        rightRows[#rightRows + 1] = { text = txt, swatch = sw }
        AlignSwatchColumn(leftRows)
        AlignSwatchColumn(rightRows)
        cs.y = rowY - 26
    end

    CursorGap(cs, 6)

    self.settingsUI.BuildDependentStatGroup(
        self, statsBody, cs, self.settingsUI.dependentStatGroups[1])

    CursorGap(cs, 6)

    self.settingsUI.BuildDependentStatGroup(
        self, statsBody, cs, self.settingsUI.dependentStatGroups[2])

    CursorGap(cs, 6)

    self.settingsUI.BuildDependentStatGroup(
        self, statsBody, cs, self.settingsUI.dependentStatGroups[3])

    CursorGap(cs, 6)

    CursorSection(cs, "Gear")
    do
        local rowY = cs.y
        local leftRows, rightRows = {}, {}
        local sw, txt
        _, sw, txt = CreateCheckboxColor(statsBody, "StatsProItemLevelCheck",
            "Show Item Level", "showItemLevel", "itemLevel", cs.padX, rowY,
            function(checked) if checked then addon.itemLevelRuntime.MarkDirty() end end)
        leftRows[#leftRows + 1] = { text = txt, swatch = sw }
        -- Durability swatch is the override color used when Auto Color is OFF.
        -- WHY: also mark dirty so re-enabling after a long off period gets fresh values
        -- on the next tick, not whatever was cached when last enabled.
        _, sw, txt = CreateCheckboxColor(statsBody, "StatsProDurabilityCheck", "Show Durability",  "showDurability", "durability", cs.padX + CONFIG_COL_OFFSET, rowY,
            function() addon.durabilityRuntime.MarkDirty() end)
        rightRows[#rightRows + 1] = { text = txt, swatch = sw }
        AlignSwatchColumn(leftRows)
        AlignSwatchColumn(rightRows)
        cs.y = rowY - 26
        CreateCheckbox(statsBody, "StatsProRepairCostCheck", "Show Repair Cost", "showRepairCost", cs.padX, cs.y,
            function() addon.durabilityRuntime.MarkDirty() end)
        CursorAdvance(cs, 22)
        CreateCheckbox(statsBody, "StatsProAutoColorCheck",
            "Auto Color by Threshold", "useAutoColorDurability", cs.padX, cs.y)
        CursorAdvance(cs, 22)
        -- WHY: onChange forces recompute via dirty flag; otherwise display stays stale
        -- until the next equipment event (which may be far off).
        -- WHY: this is a full-width row with no right-column peer. The normal 200px
        -- checkbox bound truncates longer translations; 400px still fits the 450px
        -- scroll child after the 12px row padding and 22px checkbox chrome.
        CreateCheckbox(statsBody, "StatsProWorstDurCheck",
            "Use Worst Slot (instead of average)", "useWorstDurability", cs.padX, cs.y,
            function() addon.durabilityRuntime.MarkDirty() end, 400)
        CursorAdvance(cs, 22)
    end

    statsBody.contentHeight = CursorUsed(cs)
    statsBody:SetHeight(statsBody.contentHeight)
    for _, section in ipairs(statsBody.statsProSections or {}) do
        tinsert(statsTab.statsProSections, section)
    end
    statsTab.contentHeight = math.abs(setupUI.bodyTop or setupUI.compactBodyTop)
        + statsBody.contentHeight
    statsTab:SetHeight(statsTab.contentHeight)
    self.hudPresets.RegisterView(setupUI)
end

function addon:OpenConfigMenu()
    -- Opening Settings is discovery enough. Keep navigation zero-write; the delayed
    -- onboarding check commits the marker even if this happens before profile bootstrap
    -- or Settings closes before the first-install timer fires.
    self.hudPresets.settingsDiscovered = true
    local welcome = self.hudPresets.welcome
    if welcome and welcome:IsShown() then
        welcome.statsProSettingsHandoff = true
        self.hudPresets.MarkWelcomeSeen()
        welcome:Hide()
        welcome.statsProSettingsHandoff = nil
    end
    -- Settings remains inspectable under a future schema, but the shared write gate
    -- explains once per session why every mutating control is read-only.
    self.dbRuntime.GetWritableSettings(true)
    local settingsFrame = self.settingsUI.frame
    if settingsFrame then
        if self.settingsUI.buildState == "failed" then
            if settingsFrame:IsShown() then settingsFrame:Hide() end
            PrintMsg("Settings could not be opened. Run /reload and try again.")
            return
        end
        if self.settingsUI.buildState == "building" then return end
        if settingsFrame:IsShown() then
            settingsFrame:Hide()
        else
            settingsFrame:Show()
            -- Always reopen on the first tab (Stats) — predictable UX, matches initial open.
            if settingsFrame.SwitchToTab then settingsFrame.SwitchToTab(1) end
            self.profileUI.RefreshSafe()
        end
        return
    end

    self.settingsDesign.mutationControls = self.settingsDesign.mutationControls or {}
    local mutationControls = self.settingsDesign.mutationControls
    local mutationControlCount = #mutationControls
    self.settingsUI.buildState = "building"
    local buildStage = "registry reset"
    local buildOK, buildFailure = xpcall(function()
        -- These registries belong to the one-shot Settings window. Persistent launcher
        -- labels intentionally live in localizedPersistentLabels and survive this reset.
        wipe(configRefreshers)
        wipe(alignmentGroups)
        wipe(localizedConfigLabels)
        wipe(localizedConfigFonts)

        buildStage = "shell"
        local context = self.settingsUI.BuildShell(self)
        buildStage = "layout tab"
        self.settingsUI.BuildLayoutTab(self, context)
        buildStage = "appearance tab"
        self.settingsUI.BuildAppearanceTab(self, context)
        buildStage = "stats tab"
        self.settingsUI.BuildStatsTab(self, context)

        --[[ ===== Initial state ===== ]]
        buildStage = "initial state"
        self.settingsDesign.RefreshMutationControls()
        context.switchToTab(1)
        -- CreateFrame starts shown, before the OnShow hook above exists. Explicitly seed
        -- the first-open state; later opens are handled by the hook.
        self.panelEditRuntime.SetRequested(true)
        self.settingsUI.buildState = "ready"
    end, function(failure)
        local message = type(failure) == "string" and failure or "unknown error"
        return "Settings build failed during " .. buildStage .. ": " .. message
    end)
    if not buildOK then
        self.settingsUI.buildState = "failed"
        local partialFrame = self.settingsUI.frame
        if partialFrame then pcall(partialFrame.Hide, partialFrame) end
        self.profileUI.CancelSpecialFrameRestore("StatsProConfigFrame")
        self.profileUI.RemoveSpecialFrame("StatsProConfigFrame")
        for index = #mutationControls, mutationControlCount + 1, -1 do
            mutationControls[index].statsProMutationRegistered = false
            tremove(mutationControls, index)
        end
        wipe(configRefreshers)
        wipe(alignmentGroups)
        wipe(localizedConfigLabels)
        wipe(localizedConfigFonts)
        self.settingsUI.context = nil
        error(buildFailure, 0)
    end
end

function addon:ShowConfigMenu()
    local settingsFrame = self.settingsUI.frame
    if settingsFrame and settingsFrame:IsShown() then return end
    self:OpenConfigMenu()
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
        local xOfs = NormalizePositionOffset(x, 0, "x")
        local yOfs = NormalizePositionOffset(y, fallbackY or 0, "y")
        return string.format("%s: %s/%s  %+.0f/%+.0f", label, point, relativePoint, xOfs, yOfs)
    end
    PrintMsg(PosLine("main",      GetDB("point"),           GetDB("relativePoint"),           GetDB("xOfs"),           GetDB("yOfs"),           defaults.yOfs))
    PrintMsg(PosLine("side",      GetDB("defensive_point"), GetDB("defensive_relativePoint"), GetDB("defensive_xOfs"), GetDB("defensive_yOfs"), defaults.defensive_yOfs))
end

local function PrintDebugPerf()
    local durabilityRetry = addon.durabilityRuntime.retryStates.durability
    local repairRetry = addon.durabilityRuntime.retryStates.repair
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
    PrintMsg(string.format("debug perf: dirty durability=%s itemLevel=%s repairCost=%s repairComplete=%s durability=%s durabilityComplete=%s",
        tostring(durabilityDirty),
        tostring(itemLevelDirty),
        SAFE_NUM.DumpNumber(cached.repairCost, "%d", "?"),
        tostring(cached.repairCostComplete),
        SAFE_NUM.DumpNumber(cached.durabilityValue, "%.1f", "?"),
        tostring(cached.durabilityComplete)))
    PrintMsg(string.format("debug perf: retry durability=%d/%d scheduled=%s repair=%d/%d scheduled=%s",
        durabilityRetry.attempt,
        #addon.durabilityRuntime.retryDelays,
        tostring(durabilityRetry.scheduledGeneration == addon.durabilityRuntime.generation),
        repairRetry.attempt,
        #addon.durabilityRuntime.retryDelays,
        tostring(repairRetry.scheduledGeneration == addon.durabilityRuntime.generation)))
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
    PrintMsg(string.format("bucket: mode=%s labelStyle=%s dur=%s armorDR=%s vers=%s cost=%s",
        tostring(mode), tostring(cached.labelStyle),
        SAFE_NUM.DumpNumber(cached.durabilityValue, "%.1f", "?"),
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
    local function SmokeFontState(region)
        local font, size, flags = region:GetFont()
        if flags == "" then flags = nil end
        return font, size, flags, region:GetFontObject()
    end

    addon.__test = {
        currentDBVersion = function() return CURRENT_DB_VERSION end,
        dbCompatibilityState = function()
            addon.dbRuntime.Refresh()
            return {
                readOnly = addon.dbRuntime.readOnly,
                mode = addon.dbRuntime.mode,
                version = addon.dbRuntime.version,
                warnedMode = addon.dbRuntime.warnedMode,
                generation = addon.dbRuntime.generation,
            }
        end,
        dbValidationCount = function() return addon.dbRuntime.validationCount end,
        dbGraphLimits = function()
            return {
                maxDepth = addon.dbRuntime.maxGraphDepth,
                maxNodes = addon.dbRuntime.maxGraphNodes,
            }
        end,
        cloneSerializable = addon.dbRuntime.CloneSerializable,
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
                activeRole = runtime.activeRole,
                forceReapply = runtime.forceReapply,
                corruptRollbackRetryCount = runtime.corruptRollbackRetryCount,
                corruptRollbackRetryScheduled = runtime.corruptRollbackRetryToken ~= nil,
                corruptRollbackRoot = runtime.corruptRollbackRoot,
                contextRetryCount = runtime.contextRetryCount,
                contextRetryScheduled = runtime.contextRetryToken ~= nil,
                bootstrapPending = runtime.bootstrapPending,
                pendingResolution = runtime.pendingResolution,
                scheduled = runtime.scheduledToken ~= nil,
                noSpecRetryScheduled = runtime.noSpecRetryToken ~= nil,
                transitioning = runtime.transitioning,
                suppressIntermediateRefresh = runtime.suppressIntermediateRefresh,
                requestGeneration = runtime.requestGeneration,
                activationCount = runtime.activationCount,
                applyCount = runtime.applyCount,
                configRefreshCount = runtime.configRefreshCount,
                structuralCommitCount = runtime.structuralCommitCount,
                contextReadCount = runtime.contextReadCount,
                updateCount = updateCount,
                isLoaded = isLoaded,
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
        hudPresets = {
            order = function() return CopyTable(addon.hudPresets.order) end,
            definitions = function() return CopyTable(addon.hudPresets.definitions) end,
            allowlist = function() return CopyTable(addon.hudPresets.allowlist) end,
            currentID = addon.hudPresets.CurrentID,
            startPreview = addon.hudPresets.StartPreview,
            cancelPreview = addon.hudPresets.CancelPreview,
            applyPreview = addon.hudPresets.ApplyPreview,
            maybeShowWelcome = addon.hudPresets.MaybeShowWelcome,
            setRuntimeFailureCount = function(count)
                addon.hudPresets.testRuntimeFailureCount = count or 0
            end,
            state = function()
                local session = addon.hudPresets.session
                local account = addon.dbRuntime.GetAccount()
                return {
                    active = session ~= nil,
                    presetID = session and session.presetID or nil,
                    welcomeSeen = account and rawget(account, "quickSetupSeen"),
                    welcomeShown = addon.hudPresets.welcome
                        and addon.hudPresets.welcome:IsShown() or false,
                }
            end,
        },
        profileViewModel = addon.profileUI.BuildViewModel,
        formatProfileSpecName = addon.profileUI.FormatSpecName,
        profileOps = {
            normalizeName = function(rawName)
                return addon.profileOps.NormalizeNameShape(
                    rawName, addon.profileOps.maxNameCodepoints, false)
            end,
            uniqueName = addon.profileOps.UniqueProfileName,
            specProfileName = addon.profileRuntime.SpecProfileName,
            countReferences = addon.profileOps.CountReferences,
            copySettingsToContext = addon.profileOps.CopySettingsToContext,
            assign = addon.profileOps.Assign,
            makeContextIndependent = addon.profileOps.MakeContextIndependent,
            setRoleTemplate = addon.profileOps.SetRoleTemplate,
            resetProfile = addon.profileOps.ResetProfile,
            deleteUnusedProfiles = addon.profileOps.DeleteUnusedProfiles,
            importAndAssign = addon.profileOps.ImportAndAssign,
            importTransferToContext = addon.profileOps.ImportTransferToContext,
            fullWipe = addon.profileOps.FullWipe,
            forgetCharacter = addon.profileOps.ForgetCharacter,
            setFailureStage = function(stage) addon.profileOps.testFailureStage = stage end,
            setTransitioning = function(value) addon.profileRuntime.transitioning = value == true end,
            state = function()
                return {
                    inProgress = addon.profileOps.inProgress,
                    operationCount = addon.profileOps.operationCount,
                    maxUniqueNameCandidates = addon.profileOps.maxUniqueNameCandidates,
                }
            end,
            setMaxUniqueNameCandidates = function(value)
                addon.profileOps.maxUniqueNameCandidates = value
            end,
        },
        profileTransfer = {
            serialize = addon.profileTransfer.Serialize,
            parse = addon.profileTransfer.Parse,
            decodePayload = function(value)
                if type(value) ~= "string" then return nil end
                local encoded = value:match(
                    "^SPP1:[0-9A-Fa-f]+:([A-Za-z0-9+/=]+)$")
                return encoded and addon.profileTransfer.Base64Decode(encoded) or nil
            end,
            encodePayload = function(payload)
                if type(payload) ~= "string" then return nil end
                return addon.profileTransfer.prefix
                    .. addon.profileTransfer.Adler32(payload) .. ":"
                    .. addon.profileTransfer.Base64Encode(payload)
            end,
        },
        destructivePromptState = function()
            return {
                importPending = addon.legacyImport.pending ~= nil,
                resetPending = addon.resetRuntime.pending ~= nil,
                wipePending = addon.wipeRuntime.pending ~= nil,
                wipeCorruptRecovery = addon.wipeRuntime.pending ~= nil
                    and addon.wipeRuntime.pending.corruptRecovery == true,
            }
        end,
        profileUIState = function()
            local ui = addon.profileUI
            local rows = {}
            for index, row in ipairs(ui.managerRows or {}) do
                rows[index] = {
                    shown = row:IsShown(),
                    enabled = row:IsEnabled(),
                    mouseEnabled = row:IsMouseEnabled(),
                    text = row.text:GetText(),
                    badge = row.badge:GetText(),
                    textColor = row.text.textColor and CopyTable(row.text.textColor) or nil,
                    badgeColor = row.badge.textColor and CopyTable(row.badge.textColor) or nil,
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
                    shown = button:IsShown(),
                    text = button:GetText(),
                }
            end
            return {
                refreshCount = ui.refreshCount,
                selectedGUID = ui.selectedGUID,
                selectedSpecID = ui.selectedSpecID,
                selectedAssignedProfileID = ui.selectedAssignedProfileID,
                headerProfile = ui.headerProfileButton and ui.headerProfileButton:GetText() or nil,
                headerProfileColor = ui.headerProfileButton
                    and ui.headerProfileButton.statsProText
                    and ui.headerProfileButton.statsProText.textColor
                    and CopyTable(ui.headerProfileButton.statsProText.textColor) or nil,
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
                detailProfileShown = ui.detailProfile and ui.detailProfile:IsShown() or false,
                detailProfileColor = ui.detailProfile and ui.detailProfile.textColor
                    and CopyTable(ui.detailProfile.textColor) or nil,
                detailProfileWidth = ui.detailProfile and ui.detailProfile:GetWidth() or nil,
                detailProfileWordWrap = ui.detailProfile and ui.detailProfile.wordWrap,
                detailProfileNonSpaceWrap = ui.detailProfile
                    and ui.detailProfile.nonSpaceWrap,
                detailProfileMaxLines = ui.detailProfile and ui.detailProfile.maxLines or nil,
                operationStatus = ui.operationStatus and ui.operationStatus:GetText() or nil,
                actions = actions,
                advancedShown = ui.advancedShown == true,
                operationDialogShown = ui.operationDialog and ui.operationDialog:IsShown() or false,
                operationBlockerShown = ui.operationBlocker
                    and ui.operationBlocker:IsShown() or false,
                operationBlockerLevel = ui.operationBlocker
                    and ui.operationBlocker:GetFrameLevel() or nil,
                operationDialogLevel = ui.operationDialog
                    and ui.operationDialog:GetFrameLevel() or nil,
                operationDialogMessage = ui.operationDialogMessage
                    and ui.operationDialogMessage:GetText() or nil,
                operationMode = ui.pendingAction and ui.pendingAction.mode or nil,
                operationKind = ui.pendingAction and ui.pendingAction.kind or nil,
                transferKind = ui.transferState and ui.transferState.kind or nil,
                transferText = ui.transferEditBox and ui.transferEditBox:GetText() or nil,
                transferTextSelected = ui.transferEditBox
                    and ui.transferEditBox.highlightedText or nil,
                transferTextFocused = ui.transferEditBox
                    and ui.transferEditBox:HasFocus() or false,
                transferSummary = ui.transferSummary and ui.transferSummary:GetText() or nil,
                transferHint = ui.transferHint and ui.transferHint:GetText() or nil,
                transferSections = (function()
                    local sections = {}
                    for section, check in pairs(ui.transferChecks or {}) do
                        sections[section] = {
                            enabled = check:IsEnabled(),
                            checked = check:GetChecked() == true,
                        }
                    end
                    return sections
                end)(),
                choices = choices,
            }
        end,
        previewFontForSmoke = function(path)
            return addon.settingsUI.fontPicker.Preview(addon, path)
        end,
        previewLanguageForSmoke = function(locale)
            return addon.settingsUI.localization.Preview(addon, locale)
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
        availableArchonSnapshotOptions = function()
            return CopyTable(addon.archonTargets.GetAvailableSnapshotOptions())
        end,
        resolveArchonSnapshotKey = addon.archonTargets.ResolveAvailableSnapshotKey,
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
                controls[index] = {
                    kind = control.statsProControlKind,
                    name = control:GetName(),
                    enabled = addon.settingsDesign.IsControlEnabled(control),
                    state = control.statsProControlState or control.statsProButtonState,
                    width = control:GetWidth(),
                    height = control:GetHeight(),
                    role = control.statsProButtonRole,
                    mutatesSettings = control.statsProMutatesSettings == true,
                    selected = control.statsProSelected == true,
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
            local settingsFrame = addon.settingsUI.frame
            if not settingsFrame then return nil end
            local sections = {}
            for tabIndex, tab in ipairs(settingsFrame.tabContents or {}) do
                sections[tabIndex] = {}
                for sectionIndex, section in ipairs(tab.statsProSections or {}) do
                    sections[tabIndex][sectionIndex] = {
                        key = section.key,
                        surface = section.surface,
                        text = section.text,
                        rail = section.rail,
                        line = section.line,
                        y = section.y,
                    }
                end
            end
            return {
                shell = settingsFrame.settingsShell,
                tabs = settingsFrame.tabButtons,
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
        asciiLower = addon.fontRuntime.asciiLower,
        sameFontPath = SameFontPath,
        isBlizzardFontPath = IsBlizzardFontPath,
        fontSupports = FontSupports,
        findCompatibleFont = FindCompatibleFont,
        usableFontPath = addon.fontRuntime.usablePath,
        trySetFontForSmoke = addon.fontRuntime.trySetFont,
        safeDefaultFontPath = addon.fontRuntime.safeDefaultPath,
        currentRuntimeFontPath = addon.fontRuntime.currentPath,
        applyCommittedTextStyle = addon.fontRuntime.applyCommittedTextStyle,
        fontRuntimeState = function()
            return {
                pendingSavedFont = addon.fontRuntime.pendingSavedFont,
                pendingRetryAttempt = addon.fontRuntime.pendingRetryAttempt,
                pendingRetryScheduled = addon.fontRuntime.pendingRetryScheduled,
            }
        end,
        applyConfigFont = ApplyConfigFont,
        registerConfigFont = RegisterConfigFont,
        formatRepairCost = FormatRepairCost,
        refreshDurabilityCache = RefreshDurabilityCache,
        durabilityState = function()
            local durabilityRetry = addon.durabilityRuntime.retryStates.durability
            local repairRetry = addon.durabilityRuntime.retryStates.repair
            return {
                durabilityValue = cached.durabilityValue,
                durabilityLastCompleteAverage = cached.durabilityLastCompleteAverage,
                durabilityLastCompleteWorst = cached.durabilityLastCompleteWorst,
                durabilityComplete = cached.durabilityComplete,
                durabilityHasItems = cached.durabilityHasItems,
                repairCost = cached.repairCost,
                repairCostComplete = cached.repairCostComplete,
                dirty = durabilityDirty,
                retryLimit = #addon.durabilityRuntime.retryDelays,
                durabilityRetryAttempt = durabilityRetry.attempt,
                durabilityScheduledAttempt = durabilityRetry.scheduledAttempt,
                durabilityRetryScheduled = durabilityRetry.scheduledGeneration
                    == addon.durabilityRuntime.generation,
                repairRetryAttempt = repairRetry.attempt,
                repairScheduledAttempt = repairRetry.scheduledAttempt,
                repairRetryScheduled = repairRetry.scheduledGeneration
                    == addon.durabilityRuntime.generation,
            }
        end,
        itemLevelState = function()
            return {
                overall = cached.itemLevelOverall,
                equipped = cached.itemLevelEquipped,
                complete = cached.itemLevelComplete,
                dirty = itemLevelDirty,
                generation = addon.itemLevelRuntime.generation,
                attempt = addon.itemLevelRuntime.attempt,
                retryLimit = addon.itemLevelRuntime.maxAttempts,
            }
        end,
        versatilityState = function()
            return {
                total = cached.versTotal,
                rating = cached.versTotalRating,
                percentVisible = cached.cleanRowVisibility.showVersatility,
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
            local mainLabelFont, mainLabelSize, mainLabelFlags, mainLabelObject =
                SmokeFontState(mainPanel.labelText)
            local mainRatingFont, _, mainRatingFlags, mainRatingObject =
                SmokeFontState(mainPanel.ratingText)
            local mainValueFont, _, mainValueFlags, mainValueObject =
                SmokeFontState(mainPanel.valueText)
            local mainRepairFont, _, mainRepairFlags, mainRepairObject =
                SmokeFontState(mainPanel.repairText)
            local mainRepairLabelFont, _, mainRepairLabelFlags, mainRepairLabelObject =
                SmokeFontState(mainPanel.repairLabelText)
            local sideLabelFont, sideLabelSize, sideLabelFlags, sideLabelObject =
                SmokeFontState(defensivePanel.labelText)
            local sideRatingFont, _, sideRatingFlags, sideRatingObject =
                SmokeFontState(defensivePanel.ratingText)
            local sideValueFont, _, sideValueFlags, sideValueObject =
                SmokeFontState(defensivePanel.valueText)
            local sideRepairFont, _, sideRepairFlags, sideRepairObject =
                SmokeFontState(defensivePanel.repairText)
            local sideRepairLabelFont, _, sideRepairLabelFlags, sideRepairLabelObject =
                SmokeFontState(defensivePanel.repairLabelText)
            return {
                mainAppliedFont = mainPanel.appliedFont,
                mainAppliedSize = mainPanel.appliedSize,
                mainAppliedTextOutlineStyle = mainPanel.appliedTextOutlineStyle,
                mainAppliedFontFlags = mainPanel.appliedFontFlags,
                mainOwnedFontObject = mainPanel.fontObject,
                mainOwnedRegionCount = #mainPanel.fontObjectRegions,
                mainDirectRegionCount = #mainPanel.directFontRegions,
                mainLabelFont = mainLabelFont,
                mainLabelSize = mainLabelSize,
                mainLabelFlags = mainLabelFlags,
                mainLabelObject = mainLabelObject,
                mainRatingFont = mainRatingFont,
                mainRatingFlags = mainRatingFlags,
                mainRatingObject = mainRatingObject,
                mainValueFont = mainValueFont,
                mainValueFlags = mainValueFlags,
                mainValueObject = mainValueObject,
                mainRepairFont = mainRepairFont,
                mainRepairFlags = mainRepairFlags,
                mainRepairObject = mainRepairObject,
                mainRepairLabelFont = mainRepairLabelFont,
                mainRepairLabelFlags = mainRepairLabelFlags,
                mainRepairLabelObject = mainRepairLabelObject,
                mainFontRegions = mainPanel:FontRegions(),
                sideAppliedFont = defensivePanel.appliedFont,
                sideAppliedSize = defensivePanel.appliedSize,
                sideAppliedTextOutlineStyle = defensivePanel.appliedTextOutlineStyle,
                sideAppliedFontFlags = defensivePanel.appliedFontFlags,
                sideOwnedFontObject = defensivePanel.fontObject,
                sideOwnedRegionCount = #defensivePanel.fontObjectRegions,
                sideDirectRegionCount = #defensivePanel.directFontRegions,
                sideLabelFont = sideLabelFont,
                sideLabelSize = sideLabelSize,
                sideLabelFlags = sideLabelFlags,
                sideLabelObject = sideLabelObject,
                sideRatingFont = sideRatingFont,
                sideRatingFlags = sideRatingFlags,
                sideRatingObject = sideRatingObject,
                sideValueFont = sideValueFont,
                sideValueFlags = sideValueFlags,
                sideValueObject = sideValueObject,
                sideRepairFont = sideRepairFont,
                sideRepairFlags = sideRepairFlags,
                sideRepairObject = sideRepairObject,
                sideRepairLabelFont = sideRepairLabelFont,
                sideRepairLabelFlags = sideRepairLabelFlags,
                sideRepairLabelObject = sideRepairLabelObject,
                sideFontRegions = defensivePanel:FontRegions(),
            }
        end,
        configFontState = function()
            local entries = {}
            for i, entry in ipairs(localizedConfigFonts) do
                local actualFont, _, actualFlags, actualObject = SmokeFontState(entry.fs)
                entries[i] = {
                    region = entry.fs,
                    appliedFont = entry.appliedFont,
                    appliedFlags = entry.appliedFlags,
                    actualFont = actualFont,
                    actualFlags = actualFlags,
                    actualObject = actualObject,
                    ownedObject = entry.group and entry.group.object or nil,
                    roleKey = entry.roleKey,
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
                mainRatingText = mainPanel.ratingText:GetText(),
                mainValueText = mainPanel.valueText:GetText(),
                mainRatingPoints = mainPanel.ratingText.points,
                mainValuePoints = mainPanel.valueText.points,
                mainBackgroundTextureAlpha = mainPanel.backgroundTexture and mainPanel.backgroundTexture.colorTexture and mainPanel.backgroundTexture.colorTexture.a or nil,
                mainBackgroundTexturePoints = mainPanel.backgroundTexture and mainPanel.backgroundTexture.points or nil,
                mainRepairPoints = mainPanel.repairText.points,
                mainRepairShown = mainPanel.repairText:IsShown(),
                mainRepairLabelShown = mainPanel.repairLabelText:IsShown(),
                mainRepairLabelWidth = mainPanel.repairLabelText:GetWidth(),
                mainFirstOverlayHeight = firstOverlay and firstOverlay:GetHeight() or nil,
                mainSecondOverlayPoints = secondOverlay and secondOverlay.points or nil,
                mainLabelFlags = select(3, SmokeFontState(mainPanel.labelText)),
                mainRatingFlags = select(3, SmokeFontState(mainPanel.ratingText)),
                mainValueFlags = select(3, SmokeFontState(mainPanel.valueText)),
                mainRepairFlags = select(3, SmokeFontState(mainPanel.repairText)),
                mainRepairLabelFlags = select(3, SmokeFontState(mainPanel.repairLabelText)),
                sideShown = defensivePanel:IsShown(),
                sideFrameWidth = defensivePanel.frame:GetWidth(),
                sideFrameHeight = defensivePanel.frame:GetHeight(),
                sideCachedRatingW = defensivePanel.cachedRatingW,
                sideCachedValueW = defensivePanel.cachedValueW,
                sideRenderedRatingW = defensivePanel.lastRenderedRatingW,
                sideRenderedValueW = defensivePanel.lastRenderedValueW,
                sideLabelText = defensivePanel.labelText:GetText(),
                sideRatingText = defensivePanel.ratingText:GetText(),
                sideValueText = defensivePanel.valueText:GetText(),
                sideRatingPoints = defensivePanel.ratingText.points,
                sideBackgroundTextureAlpha = defensivePanel.backgroundTexture and defensivePanel.backgroundTexture.colorTexture and defensivePanel.backgroundTexture.colorTexture.a or nil,
                sideLabelFlags = select(3, SmokeFontState(defensivePanel.labelText)),
                sideRatingFlags = select(3, SmokeFontState(defensivePanel.ratingText)),
                sideValueFlags = select(3, SmokeFontState(defensivePanel.valueText)),
                sideRepairFlags = select(3, SmokeFontState(defensivePanel.repairText)),
                sideRepairLabelFlags = select(3, SmokeFontState(defensivePanel.repairLabelText)),
            }
        end,
        panelEditAffordanceState = function()
            local function Snapshot(panel)
                local border = panel.editOutline.backdropBorderColor
                return {
                    shown = panel.editOutline:IsShown(),
                    visible = type(panel.editOutline.IsVisible) ~= "function"
                        or panel.editOutline:IsVisible(),
                    parentIsUIParent = panel.editOutline:GetParent() == UIParent,
                    outlineMouseEnabled = panel.editOutline.mouseEnabled == true,
                    handleMouseEnabled = panel.editHandle.mouseEnabled == true,
                    borderAlpha = border and border.a or nil,
                    dragging = panel.editDragging == true,
                    frameShown = panel.frame:IsShown(),
                    frameWidth = panel.frame:GetWidth(),
                    frameHeight = panel.frame:GetHeight(),
                    startMovingCalls = rawget(panel.frame, "startMovingCalls") or 0,
                    stopMovingCalls = rawget(panel.frame, "stopMovingCalls") or 0,
                }
            end
            local settingsFrame = addon.settingsUI.frame
            return {
                requested = addon.panelEditRuntime.requested == true,
                configShown = settingsFrame and settingsFrame:IsShown() or false,
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
    addon:ShowConfigMenu()
end)

if addon.__test then
    addon.__test.launcherButton = function() return launcherBtn end
end

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
        if cb then
            cb:SetChecked(GetBoolDB("isVisible"))
            addon.settingsDesign.RefreshControl(cb)
        end
        return false
    end
    db.isVisible = visible
    CacheSettings()
    addon:RunUpdateStatsSafe()
    -- WHY: master Visible checkbox in config menu may be open; sync its state.
    local cb = _G["StatsProVisibleCheck"]
    if cb then
        cb:SetChecked(visible)
        addon.settingsDesign.RefreshControl(cb)
    end
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
        PrintMsg(L("Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help"))
    else
        addon:OpenConfigMenu()
    end
end
