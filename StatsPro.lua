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

local DEFENSIVE_HEADER = "|cff808080— Defensive —|r"

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
local CURRENT_RELEASE = "1.0.4"
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
    { label = "Crit",    api = GetCritChance,    ratingCR = CR_CRIT_MELEE,  colorKey = "crit"    },
    { label = "Haste",   api = GetHaste,         ratingCR = CR_HASTE_MELEE, colorKey = "haste"   },
    { label = "Mastery", api = GetMasteryEffect, ratingCR = CR_MASTERY,     colorKey = "mastery" },
    -- versatility handled specially (dual-source: rating + flat)
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
    "showTertiary", "hideZeroTertiary", "showLeech", "showAvoidance", "showSpeed",
    "showStrength", "showAgility", "showIntellect",
    -- Defensive & durability:
    "showDefensive", "hideZeroDefensive",
    "showDodge", "showParry", "showBlock", "showArmor",
    "showDurability", "showRepairCost", "useAutoColorDurability", "useWorstDurability",
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
    -- WHY custom build over GetCoinTextureString: the Blizzard helper sizes inline
    -- icons to font height. Building manually with slightly smaller icons (fontSize-2,
    -- floor 8) keeps the row compact when it overhangs leftward off the panel.
    -- Same texture paths as GetCoinTextureString uses internally.
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local sz = math.max(8, GetDB("fontSize") - 2)
    local function icon(name)
        return "|TInterface\\MoneyFrame\\UI-" .. name .. "Icon:" .. sz .. ":" .. sz .. ":2:0|t"
    end
    local out = ""
    if g > 0 then out = g .. icon("Gold") end
    if s > 0 then out = out .. (out ~= "" and " " or "") .. s .. icon("Silver") end
    if c > 0 or out == "" then out = out .. (out ~= "" and " " or "") .. c .. icon("Copper") end
    return out
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
    -- panel just for one row. This FontString sits at the bottom row (below the column
    -- area), RIGHT-anchored to frame.right but its width does NOT participate in panel
    -- auto-fit math — wide repair strings extend leftward past frame.left if needed.
    local repairText = frame:CreateFontString(nil, "OVERLAY")
    repairText:SetFont(GetDB("font"), GetDB("fontSize"), "OUTLINE")
    repairText:SetJustifyH("RIGHT")
    repairText:SetJustifyV("BOTTOM")
    repairText:SetTextColor(1, 1, 1, 1)
    repairText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 4)
    repairText:Hide()

    self.frame = frame
    self.labelText = labelText
    self.ratingText = ratingText
    self.valueText = valueText
    self.repairText = repairText

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
    self.repairText:Hide()
    -- WARNING: reset lineCount cache too; otherwise re-show may use stale height after font change
    self.lastLineCount = -1
end

function Panel:IsShown()
    return self.frame:IsShown()
end

-- Hide frame if no lines; otherwise apply text+height.
-- WARNING: in 12.x, label/value strings may be secret-tainted (built from in-combat stat
-- API returns). String comparisons (==, ~=) on secrets error. Use lineCount (always a
-- real number) for empty-check, and SetText every call instead of deduping by text.
-- FontString:SetText accepts secrets — that's how Blizzard's own UI renders them.
function Panel:SetTextSafe(labelStr, ratingStr, valueStr, lineCount, repairStr)
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

    -- Repair string lives on its own FontString anchored BOTTOMRIGHT, RIGHT-justified.
    -- Excluded from auto-fit width math (see WHY at the FontString creation in Panel:New).
    -- Counts as one extra row for height purposes.
    local hasRepair = repairStr and repairStr ~= ""
    if hasRepair then
        self.repairText:SetText(repairStr)
        self.repairText:Show()
    else
        self.repairText:Hide()
    end
    self.lastRepairText = repairStr or ""

    -- Auto-fit width to (label + gap + rating + gap + value). Min width prevents the
    -- frame from collapsing when all columns are very short.
    -- WHY 2px gaps: labels RIGHT-justified, rating RIGHT-justified, value LEFT-justified
    -- — at each column boundary one side is justified outward, so visible gap equals
    -- exactly this constant with no per-row variance from internal column padding.
    -- WARNING: GetStringWidth() on a FontString whose text contains secret-tainted
    -- substrings (e.g. in-combat stat reads that became secret) returns a secret-
    -- tainted NUMBER. Arithmetic on a secret number errors. SetText itself accepts
    -- secrets (Blizzard whitelisted display), but width measurement is not whitelisted.
    -- Mitigation: cache the last NON-secret width per FontString. On each render,
    -- read GetStringWidth and only refresh the cache if the result is non-secret.
    local labelW = self.labelText:GetStringWidth()
    if labelW and not issecretvalue(labelW) then
        self.cachedLabelW = labelW
    end
    local ratingW = self.ratingText:GetStringWidth()
    if ratingW and not issecretvalue(ratingW) then
        self.cachedRatingW = ratingW
    end
    local valueW = self.valueText:GetStringWidth()
    if valueW and not issecretvalue(valueW) then
        self.cachedValueW = valueW
    end

    -- Reposition ratingText so its right edge sits just before the value column.
    -- ratingText anchors to frame.RIGHT with a NEGATIVE x-offset = -(valueW + rGap).
    -- rGap = 2 ONLY when BOTH columns have content (real boundary between them).
    -- valueW=0, ratingW>0 (rating-only): rOffset=0 → rating right-edge at frame.right.
    -- valueW>0, ratingW=0 (rated/non-rated mixed rows): rOffset=-valueW; rating empty
    --   so visible position doesn't matter, but no spurious 2px slack in totalW.
    local hasRating = (self.cachedRatingW or 0) > 0
    local hasValue  = (self.cachedValueW  or 0) > 0
    local rGap = (hasRating and hasValue) and 2 or 0
    local rOffset = -((self.cachedValueW or 0) + rGap)
    self.ratingText:ClearAllPoints()
    self.ratingText:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", rOffset, 0)
    self.ratingText:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", rOffset, 0)

    -- Total = label + (single 2px gap if anything follows) + rating + rGap + value
    local lGap = (hasRating or hasValue) and 2 or 0
    local totalW = math.max(
        (self.cachedLabelW or 0) + lGap + (self.cachedRatingW or 0) + rGap + (self.cachedValueW or 0),
        80)
    self.frame:SetWidth(totalW)

    local effectiveLineCount = lineCount + (hasRepair and 1 or 0)
    if effectiveLineCount ~= self.lastLineCount then
        local fontSize = GetDB("fontSize")
        self.frame:SetHeight((effectiveLineCount * fontSize) + 8)
        self.lastLineCount = effectiveLineCount
    end
end

function Panel:ApplyStyle(font, size)
    self.labelText:SetFont(font, size, "OUTLINE")
    self.ratingText:SetFont(font, size, "OUTLINE")
    self.valueText:SetFont(font, size, "OUTLINE")
    self.repairText:SetFont(font, size, "OUTLINE")
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
    -- Force resize on next SetTextSafe
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
                string.format("|cff%s%s:|r", primaryStr, def.label),
                rCol, vCol)
        end
    end
end

local function BuildOffensiveLines(labels, ratings, values)
    -- WHY guard: with both display toggles off the user wants offensive rows hidden
    -- entirely. Without this guard the percent-only branch of FmtRatingPct would still
    -- fire (single-column routing), producing visible percent rows and ignoring intent.
    if not (cached.showRating or cached.showPercentage) then return end
    local cs = cached.colorStrings

    -- skip the GetCombatRating fetch when rating display is off (no consumer)
    local needRating = cached.showRating
    for _, def in ipairs(OFFENSIVE_STATS) do
        local val = safeCall(def.api)
        local rating = needRating and safeCall(GetCombatRating, def.ratingCR) or 0
        local statColor = cs[def.colorKey]
        local rStr, vStr = FmtRatingPct(rating, val, statColor)
        PushRow(labels, ratings, values,
            string.format("|cff%s%s:|r", statColor, def.label),
            rStr, vStr)
    end

    -- Versatility: dual-source (rating bonus + flat). Cache OOC; in combat use cached.
    local versFromRating = safeCall(GetCombatRatingBonus, CR_VERSATILITY_DAMAGE_DONE)
    local versFlat       = safeCall(GetVersatilityBonus,  CR_VERSATILITY_DAMAGE_DONE)
    local versRating     = safeCall(GetCombatRating,      CR_VERSATILITY_DAMAGE_DONE)
    -- WARNING: must check ALL three for secret state before arithmetic. Different APIs may
    -- have different secret states despite same combat status (defensive: guard everything).
    if not issecretvalue(versFromRating) and not issecretvalue(versFlat) and not issecretvalue(versRating) then
        cached.versTotal = versFromRating + versFlat
        cached.versTotalRating = versRating
    end
    local versStr = cs.versatility
    local vRatStr, vValStr = FmtRatingPct(cached.versTotalRating, cached.versTotal, versStr)
    PushRow(labels, ratings, values,
        string.format("|cff%sVers:|r", versStr),
        vRatStr, vValStr)
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
                    string.format("|cff%s%s:|r", statColor, def.label),
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
                string.format("|cff%sSpeed:|r", statColor),
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
                    string.format("|cff%s%s:|r", statColor, def.label),
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
                string.format("|cff%sArmor:|r", armorStr),
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
            string.format("|cff%sDurability:|r", durStr),
            rCol, vCol)
    end
    if cached.showRepairCost and cached.repairCost > 0 then
        -- WHY returned separately (not pushed into label/rating/value columns): the
        -- coin string with embedded icons is much wider than typical percent values.
        -- A dedicated FontString outside the column system carries it (see Panel:New
        -- comment) so wide repairs don't bloat the panel; they extend leftward freely.
        -- Don't wrap in |cff...|r — coin icons render inline as textures and the
        -- color tag would tint them. The "Repair:" label is bundled into the same
        -- string with explicit color so the row reads naturally.
        repairStr = string.format("|cff%sRepair:|r ", durStr) .. FormatRepairCost(cached.repairCost)
    end
    return labels, ratings, values, repairStr
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
    -- repairStr is returned separately because it's rendered on a 4th FontString
    -- outside the 3-column system (see Panel:New). Goes into whichever panel hosts
    -- the durability rows in the active display mode.
    local mainLabels, mainRatings, mainValues = BuildMainLines()
    local defLabels,  defRatings,  defValues  = BuildDefensiveLines()
    local durLabels,  durRatings,  durValues, repairStr = BuildDurabilityLines()

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
            #mainLabels, "")
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
                #sideLabels, repairStr)
        else
            defensivePanel:Hide()
        end
    elseif mode == "sectioned" then
        local cLabels, cRatings, cValues = {}, {}, {}
        AppendRows(cLabels, cRatings, cValues, mainLabels, mainRatings, mainValues)
        if #defLabels > 0 then
            PushHeader(cLabels, cRatings, cValues, DEFENSIVE_HEADER)
            AppendRows(cLabels, cRatings, cValues, defLabels, defRatings, defValues)
        end
        AppendRows(cLabels, cRatings, cValues, durLabels, durRatings, durValues)
        mainPanel:SetTextSafe(
            JoinLinesSecretSafe(cLabels),
            JoinLinesSecretSafe(cRatings),
            JoinValuesCol(cValues),
            #cLabels, repairStr)
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
            #cLabels, repairStr)
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
    if not StatsProDB.colors then StatsProDB.colors = {} end
    local current = StatsProDB.colors[statName] or defaults.colors[statName]
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
    if not StatsProDB.colors then StatsProDB.colors = {} end
    local initialColor = StatsProDB.colors[statName] or defaults.colors[statName]
    btn:SetBackdropColor(initialColor.r, initialColor.g, initialColor.b, 1)
    btn:SetScript("OnClick", function(self) OpenColorPicker(self, statName) end)
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

    if not StatsProDB.colors then StatsProDB.colors = {} end
    local initialColor = StatsProDB.colors[statName] or defaults.colors[statName]
    colorBtn:SetBackdropColor(initialColor.r, initialColor.g, initialColor.b, 1)
    colorBtn:SetScript("OnClick", function(self) OpenColorPicker(self, statName) end)
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
    -- WHY: register only once per session; Reset rebuilds the frame but keeps the global name
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
        local currentFontName = "Friz Quadrata TT"
        for _, f in ipairs(BuildFontsList()) do
            if f.path == GetDB("font") then currentFontName = f.name; break end
        end
        UIDropDownMenu_SetText(fontDropdown, currentFontName)
        UIDropDownMenu_SetWidth(fontDropdown, 150)

        -- WHY: text-alignment buttons removed — two-column rendering anchors labels to
        -- the LEFT and values to the RIGHT regardless of any global alignment setting.
        -- The defaults.textAlign field is kept in DB only for backward compat with
        -- v1.0 saves; it has no runtime effect.

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
    end

    statsTab.contentHeight = CursorUsed(cs)
    statsTab:SetHeight(statsTab.contentHeight)

    --[[ ===== DEFENSIVE TAB ===== ]]
    local cdef = NewCursor(defensiveTab, 12, -8)

    CursorSection(cdef, "Defensive Stats")
    do
        local rowY = cdef.y
        -- Master toggles: no per-stat color
        CreateCheckbox(defensiveTab, "StatsProDefensiveCheck",   "Show Defensive Stats", "showDefensive",     cdef.padX,       rowY)
        CreateCheckbox(defensiveTab, "StatsProHideZeroDefCheck", "Hide Zero Values",     "hideZeroDefensive", cdef.padX + 220, rowY)
        cdef.y = rowY - 26
        -- Each defensive stat with its own inline color swatch
        CreateCheckboxColor(defensiveTab, "StatsProDodgeCheck", "Show Dodge", "showDodge", "dodge", cdef.padX,       cdef.y)
        CreateCheckboxColor(defensiveTab, "StatsProParryCheck", "Show Parry", "showParry", "parry", cdef.padX + 220, cdef.y)
        CursorAdvance(cdef, 22)
        CreateCheckboxColor(defensiveTab, "StatsProBlockCheck", "Show Block", "showBlock", "block", cdef.padX,       cdef.y)
        CreateCheckboxColor(defensiveTab, "StatsProArmorCheck", "Show Armor", "showArmor", "armor", cdef.padX + 220, cdef.y)
        CursorAdvance(cdef, 22)
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

    --[[ ===== Reset action (footer button wired here so it can rebuild config) ===== ]]
    resetBtn:SetScript("OnClick", function()
        for k, v in pairs(defaults) do
            if type(v) ~= "table" then StatsProDB[k] = v end
        end
        StatsProDB.colors = CopyTable(defaults.colors)
        StatsProDB.dbVersion = CURRENT_DB_VERSION

        CacheSettings()
        ApplyTextStyleToAllPanels(defaults.font, defaults.fontSize)
        SetAllPanelsScale(defaults.scale)
        LoadAllPositions()
        SetAllPanelsLockState(defaults.isLocked)
        UpdateStats()

        configFrame:Hide()
        configFrame = nil
        addon:OpenConfigMenu()

        PrintMsg("Settings reset to defaults")
    end)

    --[[ ===== Initial state ===== ]]
    SwitchToTab(1)
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
    elseif arg == "help" or arg == "?" then
        PrintMsg("Commands: /ss (config), /ss show, /ss hide, /ss toggle")
    else
        addon:OpenConfigMenu()
    end
end
