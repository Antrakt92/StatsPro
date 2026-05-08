-- Pure Lua 5.1 smoke checks for StatsPro logic that can run without a WoW client.

local assertionCount = 0

local function fail(name, detail)
    error(string.format("%s: %s", name, detail or "assertion failed"), 0)
end

local function check(name, ok, detail)
    assertionCount = assertionCount + 1
    if not ok then fail(name, detail) end
end

local function eq(name, actual, expected)
    assertionCount = assertionCount + 1
    if actual ~= expected then
        fail(name, string.format("expected %q, got %q", tostring(expected), tostring(actual)))
    end
end

local function near(name, actual, expected, epsilon)
    assertionCount = assertionCount + 1
    epsilon = epsilon or 0.00001
    if type(actual) ~= "number" or math.abs(actual - expected) > epsilon then
        fail(name, string.format("expected %.6f, got %s", expected, tostring(actual)))
    end
end

local function deepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for k, v in pairs(value) do
        out[deepCopy(k, seen)] = deepCopy(v, seen)
    end
    return out
end

local function wipeTable(t)
    for k in pairs(t) do
        t[k] = nil
    end
end

local function contains(t, value)
    for _, v in ipairs(t) do
        if v == value then return true end
    end
    return false
end

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local validAnchorPoints = {
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

local function validatePointArgs(args)
    local point = args[1]
    if type(point) ~= "string" or not validAnchorPoints[point] then
        error("invalid SetPoint point: " .. tostring(point), 3)
    end

    local xOfs, yOfs
    if #args >= 5 then
        local relativePoint = args[3]
        if type(relativePoint) ~= "string" or not validAnchorPoints[relativePoint] then
            error("invalid SetPoint relativePoint: " .. tostring(relativePoint), 3)
        end
        xOfs, yOfs = args[4], args[5]
    elseif #args == 3 and type(args[2]) == "number" and type(args[3]) == "number" then
        xOfs, yOfs = args[2], args[3]
    end

    if xOfs ~= nil and not isFiniteNumber(xOfs) then
        error("invalid SetPoint x offset: " .. tostring(xOfs), 3)
    end
    if yOfs ~= nil and not isFiniteNumber(yOfs) then
        error("invalid SetPoint y offset: " .. tostring(yOfs), 3)
    end
end

local function makeFrame(name)
    local frame = {
        name = name,
        shown = true,
        width = 100,
        height = 20,
        frameLevel = 1,
        points = {},
        scripts = {},
        text = "",
        fontSize = 12,
        enabled = true,
        verticalScroll = 0,
    }

    function frame:SetSize(w, h) self.width, self.height = w, h end
    function frame:GetWidth() return self.width end
    function frame:GetHeight() return self.height end
    function frame:SetWidth(w) self.width = w end
    function frame:SetHeight(h) self.height = h end
    function frame:SetMovable() end
    function frame:EnableMouse() end
    function frame:SetClampedToScreen() end
    function frame:SetBackdrop() end
    function frame:SetBackdropColor() end
    function frame:SetBackdropBorderColor() end
    function frame:SetColorTexture() end
    function frame:SetVertexColor() end
    function frame:SetBlendMode() end
    function frame:SetFont(font, size)
        if type(font) ~= "string" then error("SetFont font must be a string", 2) end
        if not isFiniteNumber(size) then error("SetFont size must be a finite number", 2) end
        self.font, self.fontSize = font, size
    end
    function frame:SetJustifyH() end
    function frame:SetJustifyV() end
    function frame:SetTextColor() end
    function frame:SetText(text) self.text = text or "" end
    function frame:GetText() return self.text end
    function frame:SetPoint(...)
        local args = { ... }
        validatePointArgs(args)
        self.points[#self.points + 1] = args
    end
    function frame:ClearAllPoints() self.points = {} end
    function frame:GetPoint()
        local p = self.points[1]
        if not p then return "CENTER", nil, "CENTER", 0, 0 end
        return p[1], p[2], p[3], p[4], p[5]
    end
    function frame:SetUserPlaced() end
    function frame:SetScale(scale)
        if not isFiniteNumber(scale) then error("SetScale scale must be a finite number", 2) end
        self.scale = scale
    end
    function frame:GetScale() return self.scale or 1 end
    function frame:SetAlpha(alpha)
        if not isFiniteNumber(alpha) then error("SetAlpha alpha must be a finite number", 2) end
        self.alpha = alpha
    end
    function frame:Hide() self.shown = false end
    function frame:Show() self.shown = true end
    function frame:IsShown() return self.shown end
    function frame:Enable() self.enabled = true end
    function frame:Disable() self.enabled = false end
    function frame:IsEnabled() return self.enabled end
    function frame:RegisterForDrag() end
    function frame:SetScript(event, fn) self.scripts[event] = fn end
    function frame:HookScript(event, fn) self.scripts["hook:" .. event] = fn end
    function frame:RegisterEvent(event)
        self.events = self.events or {}
        self.events[event] = true
    end
    function frame:RegisterUnitEvent(event)
        self:RegisterEvent(event)
    end
    function frame:SetFrameStrata() end
    function frame:SetFrameLevel(level) self.frameLevel = level end
    function frame:GetFrameLevel() return self.frameLevel end
    function frame:SetAllPoints() end
    function frame:SetScrollChild(child) self.scrollChild = child end
    function frame:SetVerticalScroll(value) self.verticalScroll = value or 0 end
    function frame:GetVerticalScroll() return self.verticalScroll end
    function frame:GetVerticalScrollRange() return 0 end
    function frame:SetNormalFontObject() end
    function frame:SetHighlightFontObject() end
    function frame:SetHighlightTexture()
        self.highlightTexture = self.highlightTexture or makeFrame(nil)
    end
    function frame:GetHighlightTexture()
        self.highlightTexture = self.highlightTexture or makeFrame(nil)
        return self.highlightTexture
    end
    function frame:SetChecked(value) self.checked = value end
    function frame:GetChecked() return self.checked end
    function frame:GetName() return self.name end
    function frame:StartMoving() end
    function frame:StopMovingOrSizing() end
    function frame:SetMinMaxValues(minValue, maxValue) self.minValue, self.maxValue = minValue, maxValue end
    function frame:SetValueStep(step) self.valueStep = step end
    function frame:SetObeyStepOnDrag() end
    function frame:SetValue(value) self.value = value end
    function frame:GetValue() return self.value or 0 end
    function frame:SetOrientation() end
    function frame:EnableKeyboard() end
    function frame:SetAutoFocus() end
    function frame:SetMultiLine() end
    function frame:SetMaxLetters() end
    function frame:SetMaxLines() end
    function frame:SetNumeric() end
    function frame:SetTextInsets() end
    function frame:SetWordWrap() end
    function frame:GetStringWidth()
        return #(self.text or "") * ((self.fontSize or 12) * 0.5)
    end
    function frame:GetStringHeight()
        local text = self.text or ""
        local _, lines = text:gsub("\n", "\n")
        return (lines + 1) * (self.fontSize or 12)
    end
    function frame:CreateFontString()
        return makeFrame(nil)
    end
    function frame:CreateTexture()
        return makeFrame(nil)
    end

    return frame
end

local function makeEnv(locale, opts)
    opts = opts or {}
    local env = {}
    local currentLocale = locale or "enUS"
    local lastCoinCall

    local std = {
        assert = assert,
        collectgarbage = collectgarbage,
        error = error,
        getmetatable = getmetatable,
        ipairs = ipairs,
        math = math,
        next = next,
        pairs = pairs,
        pcall = pcall,
        print = print,
        rawget = rawget,
        rawset = rawset,
        select = select,
        setmetatable = setmetatable,
        string = string,
        table = table,
        tonumber = tonumber,
        tostring = tostring,
        type = type,
        unpack = unpack,
        xpcall = xpcall,
    }

    setmetatable(env, { __index = std })
    env._G = env
    env.__frames = {}
    env.__setLocale = function(value) currentLocale = value end
    env.__lastCoinCall = function() return lastCoinCall end
    env.__fireEvent = function(event, ...)
        for _, frame in ipairs(env.__frames) do
            if frame.events and frame.events[event] and frame.scripts and type(frame.scripts.OnEvent) == "function" then
                frame.scripts.OnEvent(frame, event, ...)
            end
        end
    end

    if opts.statsProDB == nil then
        env.StatsProDB = {}
    else
        env.StatsProDB = opts.statsProDB
    end
    env.SwiftStatsDB = opts.swiftStatsDB
    env.SwiftStatsLocalDB = opts.swiftStatsLocalDB
    env.SlashCmdList = {}
    env.UISpecialFrames = {}
    env.UIParent = makeFrame("UIParent")
    env.UIParent:SetSize(1920, 1080)
    env.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
    env.C_AddOns = {
        GetAddOnMetadata = function(_, field)
            if field == "Version" then return "@project-version@" end
            return nil
        end,
    }
    env.C_Timer = {
        After = function(_, fn)
            if type(fn) == "function" then fn() end
        end,
    }
    env.Settings = {
        RegisterCanvasLayoutCategory = function(_, name) return { name = name } end,
        RegisterAddOnCategory = function() end,
    }
    env.SettingsPanel = makeFrame("SettingsPanel")
    env.HideUIPanel = function(frame) if frame and frame.Hide then frame:Hide() end end
    env.LibStub = function() return nil end
    env.issecretvalue = function() return false end
    env.CopyTable = deepCopy
    env.tinsert = table.insert
    env.tremove = table.remove
    env.wipe = wipeTable
    env.tContains = contains
    env.GetLocale = function() return currentLocale end
    env.GetAddOnMetadata = env.C_AddOns.GetAddOnMetadata
    env.InCombatLockdown = function() return false end
    env.CloseDropDownMenus = function() end
    env.UIDropDownMenu_SetText = function(frame, text) if frame then frame.dropdownText = text end end
    env.UIDropDownMenu_SetWidth = function() end
    env.UIDropDownMenu_JustifyText = function() end
    env.UIDropDownMenu_Initialize = function(frame, fn) if frame then frame.dropdownInit = fn end end
    env.UIDropDownMenu_CreateInfo = function() return {} end
    env.UIDropDownMenu_AddButton = function() end
    env.UIDropDownMenu_SetSelectedValue = function() end
    env.UIDROPDOWNMENU_OPEN_MENU = nil
    env.DropDownList1 = makeFrame("DropDownList1")
    for i = 1, 8 do
        env["DropDownList1Button" .. i] = makeFrame("DropDownList1Button" .. i)
    end
    env.ColorPickerFrame = makeFrame("ColorPickerFrame")
    function env.ColorPickerFrame:GetColorRGB() return 1, 1, 1 end
    function env.ColorPickerFrame:SetupColorPickerAndShow() self:Show() end
    env.OpenColorPicker = function() end
    env.PlaySound = function() end
    env.PlaySoundFile = function() end
    env.SOUNDKIT = {}
    env.WrapTextInColorCode = function(text, color) return (color or "") .. (text or "") .. "|r" end
    env.FONT_COLOR_CODE_CLOSE = "|r"
    env.ITEM_QUALITY_COLORS = {}
    env.BackdropTemplateMixin = {}
    env.Mixin = function(target, ...)
        for i = 1, select("#", ...) do
            local source = select(i, ...)
            if type(source) == "table" then
                for k, v in pairs(source) do target[k] = v end
            end
        end
        return target
    end
    env.CreateFromMixins = function(...)
        return env.Mixin({}, ...)
    end

    env.CreateFrame = function(_, name)
        local frame = makeFrame(name)
        env.__frames[#env.__frames + 1] = frame
        if name then
            env[name] = frame
            env[name .. "Text"] = env[name .. "Text"] or makeFrame(name .. "Text")
            env[name .. "Low"] = env[name .. "Low"] or makeFrame(name .. "Low")
            env[name .. "High"] = env[name .. "High"] or makeFrame(name .. "High")
            env[name .. "Button"] = env[name .. "Button"] or makeFrame(name .. "Button")
            frame.Button = env[name .. "Button"]
        end
        return frame
    end

    local function zero() return 0 end
    env.GetCritChance = zero
    env.GetSpellCritChance = zero
    env.GetRangedCritChance = zero
    env.GetHaste = zero
    env.GetMeleeHaste = zero
    env.GetSpellHaste = zero
    env.GetRangedHaste = zero
    env.GetMasteryEffect = zero
    env.GetMastery = zero
    env.GetVersatilityBonus = zero
    env.GetCombatRating = zero
    env.GetCombatRatingBonus = zero
    env.GetDodgeChance = zero
    env.GetParryChance = zero
    env.GetBlockChance = zero
    env.GetLifesteal = zero
    env.GetAvoidance = zero
    env.GetSpeed = zero
    env.GetUnitSpeed = function() return 0, 0, 0, 0 end
    env.GetAverageItemLevel = function() return 0, 0 end
    env.UnitStat = function(_, statId) return 0, statId == 3 and 100 or 0 end
    env.UnitArmor = function() return 0, 0 end
    env.UnitEffectiveLevel = function() return 80 end
    env.UnitClass = function() return "Warrior", "WARRIOR" end
    env.UnitRace = function() return "Human", "Human" end
    env.UnitSex = function() return 2 end
    env.GetSpecialization = function() return nil end
    env.GetSpecializationInfo = function() return nil end
    env.GetSpecializationRole = function() return nil end
    env.C_SpecializationInfo = {
        GetSpecialization = function() return nil end,
        GetSpecializationInfo = function() return nil end,
        GetSpecializationRole = function() return nil end,
    }
    env.PaperDollFrame_GetArmorReduction = zero
    env.GetInventoryItemDurability = function() return nil, nil end
    env.GetInventoryItemLink = function() return nil end
    env.C_TooltipInfo = {
        GetInventoryItem = function() return nil end,
    }
    env.TooltipUtil = {
        SurfaceArgs = function() end,
    }
    env.GetCoinTextureString = function(copper, fontSize)
        lastCoinCall = { copper = copper, fontSize = fontSize }
        return string.format("coin:%s:%s", tostring(copper), tostring(fontSize))
    end

    local constants = {
        "CR_CRIT_MELEE", "CR_CRIT_RANGED", "CR_CRIT_SPELL",
        "CR_HASTE_MELEE", "CR_HASTE_RANGED", "CR_HASTE_SPELL",
        "CR_MASTERY", "CR_VERSATILITY_DAMAGE_DONE", "CR_VERSATILITY_DAMAGE_TAKEN",
        "CR_LIFESTEAL", "CR_AVOIDANCE", "CR_SPEED",
        "CR_DODGE", "CR_PARRY", "CR_BLOCK",
    }
    for i, name in ipairs(constants) do env[name] = i end
    env.DURABILITY_SLOT_MIN = 1
    env.DURABILITY_SLOT_MAX = 19
    env.MERCHANT_SHOW = "MERCHANT_SHOW"
    env.GameFontNormalLarge = {}
    env.GameFontHighlight = {}
    env.GameFontHighlightSmall = {}

    return env
end

local function loadStatsPro(locale, opts)
    local env = makeEnv(locale, opts)
    local addon = { __statsproSmoke = true }
    local chunk, loadErr = loadfile("StatsPro.lua")
    if not chunk then error(loadErr, 0) end
    setfenv(chunk, env)
    local ok, runtimeErr = pcall(chunk, "StatsPro", addon)
    if not ok then error(runtimeErr, 0) end
    if not addon.__test then
        error("missing addon.__test; StatsPro smoke bridge was not initialized", 0)
    end
    return env, addon, addon.__test
end

do
    local ok, err = pcall(loadStatsPro, "enUS", { statsProDB = true })
    check("load.root_non_table_self_heals", ok, err)
end

do
    local ok, err = pcall(loadStatsPro, "enUS", { statsProDB = { font = {} } })
    check("load.font_table_falls_back_before_migration", ok, err)
end

local env, addon, test = loadStatsPro("enUS")

local function runMigrate(db)
    env.StatsProDB = db
    test.migrateDB()
    return db
end

local function runCache(db)
    env.StatsProDB = db
    test.cacheSettings()
    return db
end

local function assertColor(name, color, r, g, b)
    near(name .. ".r", color.r, r)
    near(name .. ".g", color.g, g)
    near(name .. ".b", color.b, b)
end

local function exists(name, value)
    check(name, value ~= nil, "missing")
    return value
end

local function hasScript(name, frame, scriptName)
    frame = exists(name .. ".frame", frame)
    check(name, type(frame.scripts) == "table" and type(frame.scripts[scriptName]) == "function",
        "missing " .. scriptName .. " script")
    return frame.scripts[scriptName]
end

local function runScript(name, frame, scriptName, ...)
    local fn = hasScript(name, frame, scriptName)
    local ok, err = pcall(fn, ...)
    check(name, ok, err)
end

local function runDropdownInit(name, dropdown)
    dropdown = exists(name .. ".frame", dropdown)
    check(name .. ".initializer_exists", type(dropdown.dropdownInit) == "function", "missing dropdown initializer")
    local ok, err = pcall(dropdown.dropdownInit)
    check(name, ok, err)
end

do
    local db = runMigrate({})
    eq("db.empty_default_population.version", db.dbVersion, test.currentDBVersion())
    eq("db.empty_default_population.force_locale", db.forceLocale, "auto")
    eq("db.empty_default_population.font_size", db.fontSize, 14)
    check("db.empty_default_population.colors", type(db.colors) == "table", "colors table missing")
    assertColor("db.empty_default_population.crit", db.colors.crit, 1, 0, 0)
end

do
    local db = runMigrate({ dbVersion = 4, useLocalizedLabels = false })
    eq("db.v4_use_localized_false_to_enUS.force", db.forceLocale, "enUS")
    eq("db.v4_use_localized_false_to_enUS.legacy_removed", db.useLocalizedLabels, nil)
    eq("db.v4_use_localized_false_to_enUS.version", db.dbVersion, test.currentDBVersion())
end

do
    local db = runMigrate({
        dbVersion = 5,
        colors = { primary = { r = 0.25, g = 0.5, b = 0.75 } },
    })
    assertColor("db.v5_primary_color_split.mainStat", db.colors.mainStat, 0.25, 0.5, 0.75)
    eq("db.v5_primary_color_split.primary_removed", db.colors.primary, nil)
    eq("db.v5_primary_color_split.intermediate_removed", db.colors.intellect, nil)
end

do
    local db = runMigrate({
        dbVersion = 6,
        showStrength = false,
        showAgility = true,
        showIntellect = false,
        colors = {
            strength = { r = 1, g = 0.84, b = 0 },
            agility = { r = 0.2, g = 0.3, b = 0.4 },
            intellect = { r = 1, g = 0.84, b = 0 },
        },
    })
    eq("db.v6_main_stat_toggle_and_color_collapse.show", db.showMainStat, true)
    assertColor("db.v6_main_stat_toggle_and_color_collapse.color", db.colors.mainStat, 0.2, 0.3, 0.4)
    eq("db.v6_main_stat_toggle_and_color_collapse.strength_removed", db.showStrength, nil)
    eq("db.v6_main_stat_toggle_and_color_collapse.color_agility_removed", db.colors.agility, nil)
end

do
    local db = runMigrate({
        dbVersion = 6,
        showStrength = "false",
        showAgility = false,
        showIntellect = false,
    })
    eq("db.v6_legacy_boolean_string_not_truthy", db.showMainStat, false)
end

do
    local db = runMigrate({ dbVersion = 7, showDurability = true })
    eq("db.v7_repair_preserve_visible_layout", db.showRepairCost, true)
end

do
    local db = runMigrate({ dbVersion = 7, showDurability = false, showRepairCost = true })
    eq("db.v7_repair_no_new_repair_only_row", db.showRepairCost, false)
end

do
    local db = runMigrate({ dbVersion = "7", showDurability = true })
    eq("db.version_string_migrates_without_error.version", db.dbVersion, test.currentDBVersion())
    eq("db.version_string_migrates_without_error.repair", db.showRepairCost, true)
end

do
    local db = runMigrate({ dbVersion = "bad" })
    eq("db.version_invalid_runs_forward_migrations.string", db.dbVersion, test.currentDBVersion())
    db = runMigrate({ dbVersion = 0 / 0 })
    eq("db.version_invalid_runs_forward_migrations.nan", db.dbVersion, test.currentDBVersion())
end

do
    local defaults = test.copyDefaults()
    local db = runMigrate({ font = {}, fontBeforeAutoSwitch = {} })
    eq("db.malformed_font_self_heals.font", db.font, defaults.font)
    eq("db.malformed_font_self_heals.saved_auto_font", db.fontBeforeAutoSwitch, nil)
end

do
    local legacyEnv, _, legacyTest = loadStatsPro("enUS", {
        statsProDB = {},
        swiftStatsDB = true,
        swiftStatsLocalDB = true,
    })
    legacyEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    eq("db.legacy_roots_ignore_non_tables", legacyEnv.StatsProDB.dbVersion, legacyTest.currentDBVersion())
end

eq("numbers.font_size_clamp_round.low", test.normalizeNumberSetting("fontSize", -5), 8)
eq("numbers.font_size_clamp_round.high", test.normalizeNumberSetting("fontSize", 100), 32)
eq("numbers.font_size_clamp_round.string", test.normalizeNumberSetting("fontSize", "15.4"), 15)
near("numbers.scale_clamp_round", test.normalizeNumberSetting("scale", 1.36), 1.4)
eq("numbers.text_alpha_clamp_step", test.normalizeNumberSetting("textAlpha", 22), 25)
near("numbers.update_interval_clamp_step", test.normalizeNumberSetting("updateInterval", 0.83), 0.85)

do
    local nan = 0 / 0
    eq("numbers.nan_falls_back.font_size", test.normalizeNumberSetting("fontSize", nan), 14)
    near("numbers.nan_falls_back.scale", test.normalizeNumberSetting("scale", nan), 1)
    eq("numbers.nan_falls_back.text_alpha", test.normalizeNumberSetting("textAlpha", nan), 100)
    near("numbers.nan_falls_back.update_interval", test.normalizeNumberSetting("updateInterval", nan), 0.5)
end

do
    local inf = 1 / 0
    eq("numbers.inf_handled.font_size_pos", test.normalizeNumberSetting("fontSize", inf), 14)
    eq("numbers.inf_handled.font_size_neg", test.normalizeNumberSetting("fontSize", -inf), 14)
    near("numbers.inf_handled.scale_pos", test.normalizeNumberSetting("scale", inf), 1)
    near("numbers.inf_handled.scale_neg", test.normalizeNumberSetting("scale", -inf), 1)
end

do
    env.StatsProDB = { isVisible = "false", showRepairCost = "false" }
    eq("booleans.string_false_uses_default.visible", test.getBoolDB("isVisible"), true)
    eq("booleans.string_false_uses_default.repair", test.getBoolDB("showRepairCost"), false)
end

do
    local boolEnv, boolAddon, boolTest = loadStatsPro("enUS", {
        statsProDB = { showTertiary = "false" },
    })
    boolTest.migrateDB()
    boolTest.cacheSettings()
    local ok, err = pcall(function() boolAddon:OpenConfigMenu() end)
    check("booleans.master_dependency_uses_real_boolean.open", ok, err)
    eq("booleans.master_dependency_uses_real_boolean.leech_disabled",
        boolEnv.StatsProLeechCheck:IsEnabled(), false)
end

do
    local posEnv = loadStatsPro("enUS", {
        statsProDB = {
            point = "NOPE",
            relativePoint = {},
            xOfs = 0 / 0,
            yOfs = 0 / 0,
            defensive_point = "NOPE",
            defensive_relativePoint = "WRONG",
            defensive_xOfs = 0 / 0,
            defensive_yOfs = 0 / 0,
        },
    })
    local ok, err = pcall(posEnv.__fireEvent, "PLAYER_ENTERING_WORLD")
    check("position.invalid_anchor_falls_back", ok, err)
    local mainPoint = posEnv.StatsProFrame.points[1]
    local defensivePoint = posEnv.StatsProDefensiveFrame.points[1]
    eq("position.invalid_anchor_falls_back.main_point", mainPoint[1], "CENTER")
    eq("position.invalid_anchor_falls_back.main_relative", mainPoint[3], "CENTER")
    eq("position.nan_offset_falls_back.main_x", mainPoint[4], 0)
    eq("position.nan_offset_falls_back.main_y", mainPoint[5], 0)
    eq("position.invalid_anchor_falls_back.defensive_point", defensivePoint[1], "CENTER")
    eq("position.invalid_anchor_falls_back.defensive_relative", defensivePoint[3], "CENTER")
    eq("position.nan_offset_falls_back.defensive_x", defensivePoint[4], 0)
    eq("position.nan_offset_falls_back.defensive_y", defensivePoint[5], -100)
end

do
    local failures = test.collectRenderRoutingSmokeFailures()
    eq("routing.existing_invariants.count", #failures, 0)
end

do
    runCache(runMigrate({ forceLocale = "auto" }))
    local failures = test.collectLabelStyleSmokeFailures()
    eq("labels.existing_utf8_invariants.count", #failures, 0)
    eq("labels.full_short_hidden_enUS.full", test.getStyledLabelText("Crit", "full"), "Crit:")
    eq("labels.full_short_hidden_enUS.short", test.getStyledLabelText("Crit", "short"), "C:")
    eq("labels.full_short_hidden_enUS.hidden", test.getStyledLabelText("Crit", "hidden"), "")
    runCache(runMigrate({ forceLocale = "ruRU" }))
    eq("labels.short_ruRU_first_utf8_char", test.getStyledLabelText("Crit", "short"), "К:")
end

eq("fonts.path_key_slash_case", test.fontPathKey("Fonts/ARIALN.TTF"), "fonts\\arialn.ttf")
eq("fonts.path_same_slash_case", test.sameFontPath("Fonts/ARIALN.TTF", "fonts\\arialn.ttf"), true)
eq("fonts.blizzard_path_detection.true", test.isBlizzardFontPath("Fonts\\ARIALN.TTF"), true)
eq("fonts.blizzard_path_detection.false", test.isBlizzardFontPath("Interface\\AddOns\\Media\\font.ttf"), false)
eq("fonts.known_glyph_support.latin", test.fontSupports("Fonts\\FRIZQT__.TTF", "Latin"), true)
eq("fonts.known_glyph_support.cyr", test.fontSupports("Fonts\\ARIALN.TTF", "Cyrillic"), true)
eq("fonts.known_glyph_support.cjk", test.fontSupports("Fonts\\ARKai_T.ttf", "Hans"), true)
eq("fonts.unknown_path_latin_only.latin", test.fontSupports("Interface\\AddOns\\Media\\Mystery.ttf", "Latin"), true)
eq("fonts.unknown_path_latin_only.hangul", test.fontSupports("Interface\\AddOns\\Media\\Mystery.ttf", "Hangul"), false)

do
    runMigrate({ fontSize = "15.4" })
    local formatted = test.formatRepairCost(12345)
    local call = env.__lastCoinCall()
    eq("repair.coin_string_uses_normalized_font_size.copper", call.copper, 12345)
    eq("repair.coin_string_uses_normalized_font_size.font", call.fontSize, 15)
    eq("repair.coin_string_uses_normalized_font_size.return", formatted, "coin:12345:15")
end

do
    local r, g, b = test.normalizeColor({ r = "2", g = "-1", b = "bad" }, { r = 0.25, g = 0.5, b = 0.75 })
    near("color.normalize_fallback_and_clamp.r", r, 1)
    near("color.normalize_fallback_and_clamp.g", g, 0)
    near("color.normalize_fallback_and_clamp.b", b, 0.75)
    eq("color.rgb_to_hex_clamps_invalid_channels", test.rgbToHex(2, -1, "bad"), "ff0000")
end

do
    runCache(runMigrate({ forceLocale = "auto" }))

    local ok, err = pcall(function() addon:OpenConfigMenu() end)
    check("config.open_constructs_frame", ok, err)

    exists("config.frame_registered.frame", env.StatsProConfigFrame)
    exists("config.frame_registered.scroll", env.StatsProConfigScroll)
    check("config.frame_registered.special", contains(env.UISpecialFrames, "StatsProConfigFrame"),
        "StatsProConfigFrame missing from UISpecialFrames")

    local coreControls = {
        "StatsProVisibleCheck",
        "StatsProLockCheck",
        "StatsProDisplayModeDropdown",
        "StatsProScaleSlider",
        "StatsProRefreshSlider",
    }
    for _, name in ipairs(coreControls) do
        exists("config.core_controls_exist." .. name, env[name])
    end

    local layoutControls = {
        "StatsProSplitCharacterCheck",
        "StatsProSplitOffensiveCheck",
        "StatsProRatingCheck",
        "StatsProPercentageCheck",
        "StatsProLabelStyleDropdown",
        "StatsProMatchColorCheck",
    }
    for _, name in ipairs(layoutControls) do
        exists("config.layout_controls_exist." .. name, env[name])
    end

    local statsControls = {
        "StatsProMainStatCheck",
        "StatsProItemLevelCheck",
        "StatsProOffensiveCheck",
        "StatsProCritCheck",
        "StatsProTertiaryCheck",
        "StatsProDefensiveCheck",
        "StatsProDurabilityCheck",
        "StatsProRepairCostCheck",
    }
    for _, name in ipairs(statsControls) do
        exists("config.stats_controls_exist." .. name, env[name])
    end

    local appearanceControls = {
        "StatsProFontDropdown",
        "StatsProFontSlider",
        "StatsProTextAlphaSlider",
        "StatsProLanguageDropdown",
    }
    for _, name in ipairs(appearanceControls) do
        exists("config.appearance_controls_exist." .. name, env[name])
    end

    runDropdownInit("config.dropdown_initializers.display_mode", env.StatsProDisplayModeDropdown)
    runDropdownInit("config.dropdown_initializers.label_style", env.StatsProLabelStyleDropdown)
    runDropdownInit("config.dropdown_initializers.language", env.StatsProLanguageDropdown)

    local switchToTab = exists("config.tab_switching.switcher", env.StatsProConfigFrame.SwitchToTab)
    ok, err = pcall(switchToTab, 2)
    check("config.tab_switching.layout", ok, err)
    ok, err = pcall(switchToTab, 3)
    check("config.tab_switching.appearance", ok, err)

    ok, err = pcall(function() addon:OpenConfigMenu() end)
    check("config.reopen_toggle.hide", ok, err)
    ok, err = pcall(function() addon:OpenConfigMenu() end)
    check("config.reopen_toggle.show", ok, err)

    runScript("config.font_picker_lazy_scaffold.open", env.StatsProFontDropdownButton, "OnClick",
        env.StatsProFontDropdownButton)
    exists("config.font_picker_lazy_scaffold.frame", env.StatsProFontPicker)
    exists("config.font_picker_lazy_scaffold.scroll", env.StatsProFontPickerScroll)
end

print(string.format("StatsPro smoke: PASS (%d assertions)", assertionCount))
