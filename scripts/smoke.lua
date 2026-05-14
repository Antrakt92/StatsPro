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

local function printContains(env, needle)
    for _, line in ipairs(env.__prints) do
        if line:find(needle, 1, true) then return true end
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

local function runFrameHandlers(frame, event, ...)
    if frame.scripts and type(frame.scripts[event]) == "function" then
        frame.scripts[event](frame, ...)
    end
    local hooks = frame.hooks and frame.hooks[event]
    if hooks then
        for _, fn in ipairs(hooks) do
            fn(frame, ...)
        end
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
        hooks = {},
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
    function frame:SetBackdrop(backdrop) self.backdrop = backdrop end
    function frame:SetBackdropColor(r, g, b, a) self.backdropColor = { r = r, g = g, b = b, a = a } end
    function frame:SetBackdropBorderColor() end
    function frame:SetColorTexture(r, g, b, a) self.colorTexture = { r = r, g = g, b = b, a = a } end
    function frame:SetVertexColor() end
    function frame:SetBlendMode() end
    function frame:SetFont(font, size, flags)
        if type(font) ~= "string" then error("SetFont font must be a string", 2) end
        if not isFiniteNumber(size) then error("SetFont size must be a finite number", 2) end
        self.font, self.fontSize, self.fontFlags = font, size, flags
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
    function frame:ClearPointState() self.points = {} end
    function frame:GetPoint()
        local p = self.points[1]
        if self.noPoint then return nil end
        if not p then return "CENTER", nil, "CENTER", 0, 0 end
        return p[1], p[2], p[3], p[4], p[5]
    end
    function frame:SetUserPlaced(value) self.userPlaced = value ~= false end
    function frame:SetScale(scale)
        if not isFiniteNumber(scale) then error("SetScale scale must be a finite number", 2) end
        self.scale = scale
    end
    function frame:GetScale() return self.scale or 1 end
    function frame:SetAlpha(alpha)
        if not isFiniteNumber(alpha) then error("SetAlpha alpha must be a finite number", 2) end
        self.alpha = alpha
    end
    function frame:Hide()
        if not self.shown then return end
        self.shown = false
        runFrameHandlers(self, "OnHide")
    end
    function frame:Show()
        if self.shown then return end
        self.shown = true
        runFrameHandlers(self, "OnShow")
    end
    function frame:IsShown() return self.shown end
    function frame:Enable() self.enabled = true end
    function frame:Disable() self.enabled = false end
    function frame:IsEnabled() return self.enabled end
    function frame:RegisterForDrag() end
    function frame:SetScript(event, fn) self.scripts[event] = fn end
    function frame:HookScript(event, fn)
        self.hooks[event] = self.hooks[event] or {}
        self.hooks[event][#self.hooks[event] + 1] = fn
    end
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
    local lsm

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
    env.__timers = {}
    env.__timerOrder = 0
    env.__closedDropdowns = 0
    env.__prints = {}
    env.print = function(text)
        env.__prints[#env.__prints + 1] = text
    end
    env.__setLocale = function(value) currentLocale = value end
    env.__lastCoinCall = function() return lastCoinCall end
    env.__fireEvent = function(event, ...)
        for _, frame in ipairs(env.__frames) do
            if frame.events and frame.events[event] and frame.scripts and type(frame.scripts.OnEvent) == "function" then
                frame.scripts.OnEvent(frame, event, ...)
            end
        end
    end
    env.__flushNextTimer = function(maxDelay)
        local bestIndex, best
        for i, timer in ipairs(env.__timers) do
            if maxDelay == nil or timer.delay <= maxDelay then
                if not best or timer.delay < best.delay or (timer.delay == best.delay and timer.order < best.order) then
                    bestIndex, best = i, timer
                end
            end
        end
        if not best then return false end
        table.remove(env.__timers, bestIndex)
        best.fn()
        return true
    end
    env.__flushTimers = function(maxDelay)
        local count = 0
        while env.__flushNextTimer(maxDelay) do
            count = count + 1
        end
        return count
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
        After = function(delay, fn)
            if type(fn) == "function" then
                env.__timerOrder = env.__timerOrder + 1
                env.__timers[#env.__timers + 1] = {
                    delay = tonumber(delay) or 0,
                    order = env.__timerOrder,
                    fn = fn,
                }
            end
        end,
    }
    env.Settings = {
        RegisterCanvasLayoutCategory = function(_, name) return { name = name } end,
        RegisterAddOnCategory = function() end,
    }
    env.SettingsPanel = makeFrame("SettingsPanel")
    env.HideUIPanel = function(frame) if frame and frame.Hide then frame:Hide() end end
    if opts.lsmFonts then
        local names = {}
        local paths = {}
        for _, font in ipairs(opts.lsmFonts) do
            names[#names + 1] = font.name
            paths[font.name] = font.path
        end
        lsm = {
            MediaType = { FONT = "font" },
            List = function(_, mediaType)
                if mediaType == "font" then return names end
                return {}
            end,
            Fetch = function(_, mediaType, name)
                if mediaType == "font" then return paths[name] end
                return nil
            end,
        }
    end
    env.LibStub = function(name)
        if name == "LibSharedMedia-3.0" then return lsm end
        return nil
    end
    env.issecretvalue = opts.issecretvalue or function() return false end
    env.CopyTable = deepCopy
    env.tinsert = table.insert
    env.tremove = table.remove
    env.wipe = wipeTable
    env.tContains = contains
    env.GetLocale = function() return currentLocale end
    env.GetAddOnMetadata = env.C_AddOns.GetAddOnMetadata
    env.InCombatLockdown = function() return false end
    env.CloseDropDownMenus = function()
        env.__closedDropdowns = env.__closedDropdowns + 1
        if env.DropDownList1 then env.DropDownList1:Hide() end
    end
    env.UIDropDownMenu_SetText = function(frame, text) if frame then frame.dropdownText = text end end
    env.UIDropDownMenu_SetWidth = function() end
    env.UIDropDownMenu_JustifyText = function() end
    env.UIDropDownMenu_Initialize = function(frame, fn)
        if frame then
            frame.dropdownInit = function(...)
                frame.dropdownEntries = {}
                env.__currentDropdown = frame
                local ok, err = pcall(fn, ...)
                env.__currentDropdown = nil
                if not ok then error(err, 0) end
            end
        end
    end
    env.UIDropDownMenu_CreateInfo = function() return {} end
    env.UIDropDownMenu_AddButton = function(info)
        local dropdown = env.__currentDropdown
        if dropdown then
            dropdown.dropdownEntries = dropdown.dropdownEntries or {}
            dropdown.dropdownEntries[#dropdown.dropdownEntries + 1] = {
                text = info.text,
                value = info.value,
                checked = info.checked,
                func = info.func,
            }
        end
    end
    env.UIDropDownMenu_SetSelectedValue = function() end
    env.UIDROPDOWNMENU_OPEN_MENU = nil
    env.DropDownList1 = makeFrame("DropDownList1")
    for i = 1, 8 do
        env["DropDownList1Button" .. i] = makeFrame("DropDownList1Button" .. i)
    end
    env.ColorPickerFrame = makeFrame("ColorPickerFrame")
    env.ColorPickerFrame.shown = false
    env.__setColorPickerRGB = function(r, g, b)
        env.ColorPickerFrame.colorRGB = { r = r, g = g, b = b }
    end
    function env.ColorPickerFrame:GetColorRGB()
        local rgb = self.colorRGB or {}
        return rgb.r or 1, rgb.g or 1, rgb.b or 1
    end
    function env.ColorPickerFrame:SetupColorPickerAndShow(opts)
        self.colorPickerOptions = opts or {}
        self.colorPickerCancelActive = true
        self.colorRGB = { r = opts and opts.r or 1, g = opts and opts.g or 1, b = opts and opts.b or 1 }
        if type(self.colorPickerOptions.swatchFunc) == "function" then self.colorPickerOptions.swatchFunc() end
        self:Show()
    end
    function env.__acceptColorPicker()
        local picker = env.ColorPickerFrame
        local opts = picker.colorPickerOptions
        if opts and type(opts.swatchFunc) == "function" then opts.swatchFunc() end
        picker.colorPickerCancelActive = false
        picker:Hide()
        picker.colorPickerOptions = nil
    end
    function env.__cancelColorPicker()
        local picker = env.ColorPickerFrame
        local opts = picker.colorPickerOptions
        if picker.shown and picker.colorPickerCancelActive and opts and type(opts.cancelFunc) == "function" then
            opts.cancelFunc()
        end
        picker.colorPickerCancelActive = false
        picker:Hide()
        picker.colorPickerOptions = nil
    end
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
    env.GetCritChance = opts.getCritChance or zero
    env.GetSpellCritChance = opts.getSpellCritChance or zero
    env.GetRangedCritChance = opts.getRangedCritChance or zero
    env.GetHaste = opts.getHaste or zero
    env.GetMeleeHaste = opts.getMeleeHaste or zero
    env.GetSpellHaste = opts.getSpellHaste or zero
    env.GetRangedHaste = opts.getRangedHaste or zero
    env.GetMasteryEffect = opts.getMasteryEffect or zero
    env.GetMastery = opts.getMastery or zero
    env.GetVersatilityBonus = opts.getVersatilityBonus or zero
    env.GetCombatRating = opts.getCombatRating or zero
    env.GetCombatRatingBonus = opts.getCombatRatingBonus or zero
    env.GetDodgeChance = opts.getDodgeChance or zero
    env.GetParryChance = opts.getParryChance or zero
    env.GetBlockChance = opts.getBlockChance or zero
    env.GetLifesteal = opts.getLifesteal or zero
    env.GetAvoidance = opts.getAvoidance or zero
    env.GetSpeed = opts.getSpeed or zero
    env.GetUnitSpeed = opts.getUnitSpeed or function() return 0, 0, 0, 0 end
    env.GetAverageItemLevel = opts.getAverageItemLevel or function() return 0, 0 end
    env.UnitStat = opts.unitStat or function(_, statId) return 0, statId == 3 and 100 or 0 end
    env.UnitArmor = opts.unitArmor or function() return 0, 0 end
    env.UnitEffectiveLevel = opts.unitEffectiveLevel or function() return 80 end
    env.UnitClass = function() return opts.unitClassName or "Warrior", opts.unitClassToken or "WARRIOR" end
    env.UnitRace = function() return "Human", "Human" end
    env.UnitSex = function() return 2 end
    env.GetSpecialization = function() return nil end
    env.GetSpecializationInfo = function() return nil end
    env.GetSpecializationRole = function() return nil end
    env.C_SpecializationInfo = {
        GetSpecialization = function() return opts.specIndex end,
        GetSpecializationInfo = function()
            return opts.specID, opts.specName, nil, nil, opts.specRole, opts.primaryStat
        end,
        GetSpecializationRole = function() return nil end,
    }
    env.C_PaperDollInfo = {
        GetStaggerPercentage = opts.getStaggerPercentage or function() return nil end,
    }
    env.PaperDollFrame_GetArmorReduction = opts.paperDollFrameGetArmorReduction or zero
    env.GetInventoryItemDurability = opts.getInventoryItemDurability or function() return nil, nil end
    env.GetInventoryItemLink = function() return nil end
    env.C_TooltipInfo = {
        GetInventoryItem = opts.getTooltipInventoryItem or function() return nil end,
    }
    env.TooltipUtil = {
        SurfaceArgs = opts.surfaceTooltipArgs or function() end,
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

do
    local mainInsets = exists("panel.background_insets.main", env.StatsProFrame.backdrop and env.StatsProFrame.backdrop.insets)
    local sideInsets = exists("panel.background_insets.side", env.StatsProDefensiveFrame.backdrop and env.StatsProDefensiveFrame.backdrop.insets)
    eq("panel.background_insets.main.left", mainInsets.left, 0)
    eq("panel.background_insets.main.right", mainInsets.right, 0)
    eq("panel.background_insets.main.top", mainInsets.top, 0)
    eq("panel.background_insets.main.bottom", mainInsets.bottom, 0)
    eq("panel.background_insets.side.left", sideInsets.left, 0)
    eq("panel.background_insets.side.right", sideInsets.right, 0)
    eq("panel.background_insets.side.top", sideInsets.top, 0)
    eq("panel.background_insets.side.bottom", sideInsets.bottom, 0)
end

do
    test.renderMainPanelForSmoke("Crit:\nHaste:", "903 |\n199 |", "29.6%\n9.7%", 2, "438 coin", "Repair:")
    local visualState = test.panelVisualState()
    eq("panel.background_texture.height_uses_content_bounds", visualState.mainFrameHeight, 43)
    local topLeft = exists("panel.background_texture.top_left", visualState.mainBackgroundTexturePoints and visualState.mainBackgroundTexturePoints[1])
    local bottomRight = exists("panel.background_texture.bottom_right", visualState.mainBackgroundTexturePoints and visualState.mainBackgroundTexturePoints[2])
    eq("panel.background_texture.top_left.point", topLeft[1], "TOPLEFT")
    eq("panel.background_texture.top_left.x", topLeft[4], -4)
    eq("panel.background_texture.top_left.y", topLeft[5], 4)
    eq("panel.background_texture.bottom_right.point", bottomRight[1], "BOTTOMRIGHT")
    eq("panel.background_texture.bottom_right.x", bottomRight[4], 4)
    eq("panel.background_texture.bottom_right.y", bottomRight[5], -4)
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

local function callScript(name, frame, scriptName, ...)
    local fn = hasScript(name, frame, scriptName)
    local ok, err = pcall(fn, frame, ...)
    check(name, ok, err)
end

local function flushTimers(name, env, maxDelay, expectedCount)
    local ok, result = pcall(env.__flushTimers, maxDelay)
    check(name, ok, result)
    if expectedCount ~= nil then
        eq(name .. ".count", result, expectedCount)
    end
    return result
end

local function fireEvent(name, env, event, ...)
    local ok, err = pcall(env.__fireEvent, event, ...)
    check(name, ok, err)
end

local function runDropdownInit(name, dropdown)
    dropdown = exists(name .. ".frame", dropdown)
    check(name .. ".initializer_exists", type(dropdown.dropdownInit) == "function", "missing dropdown initializer")
    local ok, err = pcall(dropdown.dropdownInit)
    check(name, ok, err)
    return dropdown.dropdownEntries or {}
end

local function selectDropdownValue(name, dropdown, value)
    local entries = runDropdownInit(name .. ".init", dropdown)
    for _, entry in ipairs(entries) do
        if entry.value == value then
            check(name .. ".func_exists", type(entry.func) == "function", "missing dropdown callback")
            local ok, err = pcall(entry.func)
            check(name, ok, err)
            return entry
        end
    end
    fail(name, "missing dropdown value " .. tostring(value))
end

local function slash(name, env, msg)
    local fn = exists(name .. ".handler", env.SlashCmdList.STATSPRO)
    local ok, err = pcall(fn, msg)
    check(name, ok, err)
end

local function clickCheckbox(name, frame, checked)
    frame = exists(name .. ".frame", frame)
    frame:SetChecked(checked)
    callScript(name, frame, "OnClick")
end

local function changeSlider(name, frame, value)
    frame = exists(name .. ".frame", frame)
    frame:SetValue(value)
    callScript(name, frame, "OnValueChanged", value)
end

local function findFrame(name, env, predicate)
    for _, frame in ipairs(env.__frames) do
        if predicate(frame) then return frame end
    end
    fail(name, "matching frame not found")
end

local function countFrameField(env, field, value)
    local count = 0
    for _, frame in ipairs(env.__frames) do
        if frame[field] == value then count = count + 1 end
    end
    return count
end

local function blockDumpContains(blocks, needle)
    for _, block in ipairs(blocks or {}) do
        for _, field in ipairs({ "labels", "ratings", "values" }) do
            for _, value in ipairs(block[field] or {}) do
                if type(value) == "string" and value:find(needle, 1, true) then return true end
            end
        end
    end
    return false
end

do
    local db = runMigrate({})
    eq("db.empty_default_population.version", db.dbVersion, test.currentDBVersion())
    eq("db.empty_default_population.force_locale", db.forceLocale, "auto")
    eq("db.empty_default_population.font_size", db.fontSize, 14)
    eq("db.empty_default_population.panel_background_alpha", db.panelBackgroundAlpha, 0)
    eq("db.empty_default_population.text_outline_style", db.textOutlineStyle, "outline")
    eq("db.empty_default_population.split_item_level", db.splitItemLevel, true)
    eq("db.empty_default_population.show_stagger", db.showStagger, false)
    check("db.empty_default_population.colors", type(db.colors) == "table", "colors table missing")
    assertColor("db.empty_default_population.crit", db.colors.crit, 1, 0, 0)
    assertColor("db.empty_default_population.stagger", db.colors.stagger, 0.3, 0.8, 0.5)
end

do
    local db = runMigrate({ dbVersion = 8, splitItemLevel = false })
    eq("db.v8_preserves_existing_split_item_level_false.value", db.splitItemLevel, false)
    eq("db.v8_preserves_existing_split_item_level_false.version", db.dbVersion, test.currentDBVersion())
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
eq("numbers.panel_background_alpha_clamp.low", test.normalizeNumberSetting("panelBackgroundAlpha", -5), 0)
eq("numbers.panel_background_alpha_clamp.high", test.normalizeNumberSetting("panelBackgroundAlpha", 100), 80)
eq("numbers.panel_background_alpha_clamp.step", test.normalizeNumberSetting("panelBackgroundAlpha", 43), 45)
near("numbers.update_interval_clamp_step", test.normalizeNumberSetting("updateInterval", 0.83), 0.85)

do
    local nan = 0 / 0
    eq("numbers.nan_falls_back.font_size", test.normalizeNumberSetting("fontSize", nan), 14)
    near("numbers.nan_falls_back.scale", test.normalizeNumberSetting("scale", nan), 1)
    eq("numbers.nan_falls_back.text_alpha", test.normalizeNumberSetting("textAlpha", nan), 100)
    eq("numbers.nan_falls_back.panel_background_alpha", test.normalizeNumberSetting("panelBackgroundAlpha", nan), 0)
    near("numbers.nan_falls_back.update_interval", test.normalizeNumberSetting("updateInterval", nan), 0.5)
end

do
    local inf = 1 / 0
    eq("numbers.inf_handled.font_size_pos", test.normalizeNumberSetting("fontSize", inf), 14)
    eq("numbers.inf_handled.font_size_neg", test.normalizeNumberSetting("fontSize", -inf), 14)
    near("numbers.inf_handled.scale_pos", test.normalizeNumberSetting("scale", inf), 1)
    near("numbers.inf_handled.scale_neg", test.normalizeNumberSetting("scale", -inf), 1)
    eq("numbers.inf_handled.panel_background_alpha_pos", test.normalizeNumberSetting("panelBackgroundAlpha", inf), 0)
    eq("numbers.inf_handled.panel_background_alpha_neg", test.normalizeNumberSetting("panelBackgroundAlpha", -inf), 0)
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
    local queuedEnv = makeEnv("enUS")
    local ran = false
    queuedEnv.C_Timer.After(0.1, function() ran = true end)
    eq("lifecycle.timer_queue_does_not_run_immediately.queued", #queuedEnv.__timers, 1)
    eq("lifecycle.timer_queue_does_not_run_immediately.ran", ran, false)
    flushTimers("lifecycle.timer_queue_flushes", queuedEnv, 0.1, 1)
    eq("lifecycle.timer_queue_flushes.ran", ran, true)
end

do
    local freshEnv, _, freshTest = loadStatsPro("enUS", {
        statsProDB = { xOfs = 33, yOfs = -44, defensive_yOfs = -123, scale = 1.4 },
    })
    fireEvent("lifecycle.pew_fresh_db_initializes.fire", freshEnv, "PLAYER_ENTERING_WORLD")
    eq("lifecycle.pew_fresh_db_initializes.version", freshEnv.StatsProDB.dbVersion, freshTest.currentDBVersion())
    local mainPoint = freshEnv.StatsProFrame.points[1]
    local defensivePoint = freshEnv.StatsProDefensiveFrame.points[1]
    eq("lifecycle.pew_fresh_db_initializes.main_x", mainPoint[4], 33)
    eq("lifecycle.pew_fresh_db_initializes.main_y", mainPoint[5], -44)
    eq("lifecycle.pew_fresh_db_initializes.defensive_y", defensivePoint[5], -123)
    near("lifecycle.pew_fresh_db_initializes.scale", freshEnv.StatsProFrame:GetScale(), 1.4)
end

do
    local legacySource = {
        fontSize = 17,
        colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } },
    }
    local localSource = { fontSize = 12 }
    local legacyEnv = loadStatsPro("enUS", {
        statsProDB = {},
        swiftStatsDB = legacySource,
        swiftStatsLocalDB = localSource,
    })
    fireEvent("lifecycle.pew_legacy_priority.fire", legacyEnv, "PLAYER_ENTERING_WORLD")
    eq("lifecycle.pew_legacy_priority.font_size", legacyEnv.StatsProDB.fontSize, 17)
    assertColor("lifecycle.pew_legacy_priority.color_copied", legacyEnv.StatsProDB.colors.crit, 0.2, 0.3, 0.4)
    legacySource.colors.crit.r = 0.9
    near("lifecycle.pew_legacy_priority.deep_copy", legacyEnv.StatsProDB.colors.crit.r, 0.2)

    local fallbackEnv = loadStatsPro("enUS", {
        statsProDB = {},
        swiftStatsLocalDB = { fontSize = 19 },
    })
    fireEvent("lifecycle.pew_legacy_local_fallback.fire", fallbackEnv, "PLAYER_ENTERING_WORLD")
    eq("lifecycle.pew_legacy_local_fallback.font_size", fallbackEnv.StatsProDB.fontSize, 19)
end

do
    local idempotentSource = { fontSize = 18 }
    local idempotentEnv = loadStatsPro("enUS", {
        statsProDB = {},
        swiftStatsDB = idempotentSource,
    })
    fireEvent("lifecycle.pew_idempotent.first", idempotentEnv, "PLAYER_ENTERING_WORLD")
    idempotentEnv.StatsProDB.fontSize = 22
    idempotentSource.fontSize = 9
    fireEvent("lifecycle.pew_idempotent.second", idempotentEnv, "PLAYER_ENTERING_WORLD")
    eq("lifecycle.pew_idempotent.no_recapture", idempotentEnv.StatsProDB.fontSize, 22)
end

do
    local logoutEnv = loadStatsPro("enUS")
    logoutEnv.StatsProFrame:ClearAllPoints()
    logoutEnv.StatsProFrame:SetPoint("TOPLEFT", logoutEnv.UIParent, "TOPLEFT", 41, -42)
    logoutEnv.StatsProDefensiveFrame:ClearAllPoints()
    logoutEnv.StatsProDefensiveFrame:SetPoint("BOTTOMRIGHT", logoutEnv.UIParent, "BOTTOMRIGHT", -17, 23)
    fireEvent("lifecycle.logout_saves_positions.fire", logoutEnv, "PLAYER_LOGOUT")
    eq("lifecycle.logout_saves_positions.main_point", logoutEnv.StatsProDB.point, "TOPLEFT")
    eq("lifecycle.logout_saves_positions.main_x", logoutEnv.StatsProDB.xOfs, 41)
    eq("lifecycle.logout_saves_positions.defensive_point", logoutEnv.StatsProDB.defensive_point, "BOTTOMRIGHT")
    eq("lifecycle.logout_saves_positions.defensive_x", logoutEnv.StatsProDB.defensive_xOfs, -17)

    local nilPointEnv = loadStatsPro("enUS", {
        statsProDB = { point = "BOTTOM", xOfs = 7, yOfs = 8 },
    })
    nilPointEnv.StatsProFrame.noPoint = true
    fireEvent("lifecycle.logout_nil_point_preserves_db.fire", nilPointEnv, "PLAYER_LOGOUT")
    eq("lifecycle.logout_nil_point_preserves_db.point", nilPointEnv.StatsProDB.point, "BOTTOM")
    eq("lifecycle.logout_nil_point_preserves_db.x", nilPointEnv.StatsProDB.xOfs, 7)
end

do
    local dragEnv = loadStatsPro("enUS")
    fireEvent("lifecycle.drag_guard.fire", dragEnv, "PLAYER_ENTERING_WORLD")
    callScript("lifecycle.drag_guard.start", dragEnv.StatsProFrame, "OnDragStart")
    callScript("lifecycle.drag_guard.stop", dragEnv.StatsProFrame, "OnDragStop")
    callScript("lifecycle.drag_guard.right_click_suppressed", dragEnv.StatsProFrame, "OnMouseUp", "RightButton")
    eq("lifecycle.drag_guard.config_not_opened", dragEnv.StatsProConfigFrame, nil)
    flushTimers("lifecycle.drag_guard.timer_flush", dragEnv, 0.11, 1)
    callScript("lifecycle.drag_guard.right_click_after_timer", dragEnv.StatsProFrame, "OnMouseUp", "RightButton")
    exists("lifecycle.drag_guard.config_opened", dragEnv.StatsProConfigFrame)
end

do
    local slashEnv = loadStatsPro("enUS")
    fireEvent("slash.pew", slashEnv, "PLAYER_ENTERING_WORLD")
    slash("slash.default_opens_config", slashEnv, "")
    exists("slash.default_opens_config.frame", slashEnv.StatsProConfigFrame)
    slash("slash.hide", slashEnv, "hide")
    eq("slash.hide.visible", slashEnv.StatsProDB.isVisible, false)
    eq("slash.hide.checkbox_synced", slashEnv.StatsProVisibleCheck:GetChecked(), false)
    slash("slash.show", slashEnv, "show")
    eq("slash.show.visible", slashEnv.StatsProDB.isVisible, true)
    slash("slash.toggle", slashEnv, "toggle")
    eq("slash.toggle.visible", slashEnv.StatsProDB.isVisible, false)
    slashEnv.StatsProDB.fontBeforeAutoSwitch = "Fonts\\ARIALN.TTF"
    slashEnv.StatsProDB.useLocalizedLabels = false
    slashEnv.StatsProDB.panelBackgroundAlpha = 55
    slashEnv.StatsProDB.textOutlineStyle = "thick"
    slashEnv.StatsProDB.colors.crit = { r = 0.4, g = 0.5, b = 0.6 }
    slash("slash.reset_restores_defaults", slashEnv, "reset")
    eq("slash.reset_restores_defaults.visible", slashEnv.StatsProDB.isVisible, true)
    eq("slash.reset_restores_defaults.panel_background_alpha", slashEnv.StatsProDB.panelBackgroundAlpha, 0)
    eq("slash.reset_restores_defaults.text_outline_style", slashEnv.StatsProDB.textOutlineStyle, "outline")
    eq("slash.reset_restores_defaults.transient_font", slashEnv.StatsProDB.fontBeforeAutoSwitch, nil)
    eq("slash.reset_restores_defaults.legacy_locale", slashEnv.StatsProDB.useLocalizedLabels, nil)
    assertColor("slash.reset_restores_defaults.crit", slashEnv.StatsProDB.colors.crit, 1, 0, 0)
end

do
    local failures = test.collectRenderRoutingSmokeFailures()
    eq("routing.existing_invariants.count", #failures, 0)
end

do
    local critEnv, _, critTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            hideZeroOffensive = false,
            showCrit = true,
            showHaste = false,
            showMastery = false,
            showVersatility = false,
            showTertiary = false,
            showDefensive = false,
        },
        getCritChance = function() return nil end,
    })
    fireEvent("render.offensive_nil_percent_skips_crit.fire", critEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.offensive_nil_percent_skips_crit.no_error", ok, blocks)
    eq("render.offensive_nil_percent_skips_crit.no_row", blockDumpContains(blocks, "Crit:"), false)
end

do
    local critEnv, _, critTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            hideZeroOffensive = false,
            showCrit = true,
            showHaste = false,
            showMastery = false,
            showVersatility = false,
            showTertiary = false,
            showDefensive = false,
        },
        getCritChance = function() return "bad" end,
    })
    fireEvent("render.offensive_wrong_type_percent_skips_crit.fire", critEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.offensive_wrong_type_percent_skips_crit.no_error", ok, blocks)
    eq("render.offensive_wrong_type_percent_skips_crit.no_row", blockDumpContains(blocks, "Crit:"), false)
end

do
    local critEnv, _, critTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            showRating = true,
            showPercentage = false,
            showCrit = true,
            showHaste = false,
            showMastery = false,
            showVersatility = false,
            showTertiary = false,
            showDefensive = false,
        },
        getCritChance = function() return 12.5 end,
        getCombatRating = function() return nil end,
    })
    fireEvent("render.rating_nil_coerces_to_zero.fire", critEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.rating_nil_coerces_to_zero.no_error", ok, blocks)
    eq("render.rating_nil_coerces_to_zero.row", blockDumpContains(blocks, "Crit:"), true)
    eq("render.rating_nil_coerces_to_zero.zero_rating", blockDumpContains(blocks, "0|r"), true)
end

do
    local leechEnv, _, leechTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showTertiary = true,
            hideZeroTertiary = false,
            showLeech = true,
            showAvoidance = false,
            showSpeed = false,
            showDefensive = false,
        },
        getLifesteal = function() return nil end,
    })
    fireEvent("render.tertiary_nil_percent_skips_leech.fire", leechEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(leechTest.buildRenderBlocks)
    check("render.tertiary_nil_percent_skips_leech.no_error", ok, blocks)
    eq("render.tertiary_nil_percent_skips_leech.no_row", blockDumpContains(blocks, "Leech:"), false)
end

do
    local dodgeEnv, _, dodgeTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showDefensive = true,
            hideZeroDefensive = false,
            showDodge = true,
            showParry = false,
            showBlock = false,
            showArmor = false,
        },
        getDodgeChance = function() return nil end,
    })
    fireEvent("render.defensive_nil_percent_skips_dodge.fire", dodgeEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(dodgeTest.buildRenderBlocks)
    check("render.defensive_nil_percent_skips_dodge.no_error", ok, blocks)
    eq("render.defensive_nil_percent_skips_dodge.no_row", blockDumpContains(blocks, "Dodge:"), false)
end

do
    local versEnv, _, versTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            hideZeroOffensive = true,
            showCrit = false,
            showHaste = false,
            showMastery = false,
            showVersatility = true,
            showTertiary = false,
            showDefensive = false,
        },
        getCombatRatingBonus = function() return nil end,
        getVersatilityBonus = function() return nil end,
    })
    fireEvent("render.versatility_nil_sources_no_error.fire", versEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_nil_sources_no_error.no_error", ok, blocks)
    eq("render.versatility_nil_sources_no_error.no_row", blockDumpContains(blocks, "Vers:"), false)
end

do
    local ilvlEnv = loadStatsPro("enUS", {
        statsProDB = {
            displayMode = "sectioned",
            showOffensive = false,
            showItemLevel = true,
            showDurability = false,
            showRepairCost = false,
        },
        getAverageItemLevel = function() return 273, 271 end,
    })
    fireEvent("routing.item_level_uses_gear_header.fire", ilvlEnv, "PLAYER_ENTERING_WORLD")
    slash("routing.item_level_uses_gear_header.dump", ilvlEnv, "debug bucket")
    eq("routing.item_level_uses_gear_header.gear", printContains(ilvlEnv, "— Gear —"), true)
    eq("routing.item_level_uses_gear_header.no_item_level_header", printContains(ilvlEnv, "— Item Level —"), false)
    eq("routing.item_level_uses_gear_header.row", printContains(ilvlEnv, "iLvl:"), true)
end

do
    local blockEnv = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showDefensive = true,
            hideZeroDefensive = false,
            showDodge = false,
            showParry = false,
            showBlock = true,
            showArmor = false,
        },
        unitClassToken = "MONK",
        getBlockChance = function() return 7 end,
    })
    fireEvent("defensive.block_skips_non_block_class.fire", blockEnv, "PLAYER_ENTERING_WORLD")
    slash("defensive.block_skips_non_block_class.dump", blockEnv, "debug bucket")
    eq("defensive.block_skips_non_block_class.no_block_row", printContains(blockEnv, "Block:"), false)
end

do
    local blockEnv = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showDefensive = true,
            hideZeroDefensive = false,
            showDodge = false,
            showParry = false,
            showBlock = true,
            showArmor = false,
        },
        unitClassToken = "SHAMAN",
        getBlockChance = function() return 0 end,
    })
    fireEvent("defensive.block_renders_for_shaman_zero.fire", blockEnv, "PLAYER_ENTERING_WORLD")
    slash("defensive.block_renders_for_shaman_zero.dump", blockEnv, "debug bucket")
    eq("defensive.block_renders_for_shaman_zero.block_row", printContains(blockEnv, "Block:"), true)
end

do
    local staggerEnv = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showDefensive = true,
            hideZeroDefensive = false,
            showDodge = false,
            showParry = false,
            showBlock = false,
            showArmor = false,
            showStagger = true,
        },
        unitClassToken = "MONK",
        specIndex = 1,
        specID = 268,
        getStaggerPercentage = function() return 37.5, 37.5 end,
    })
    fireEvent("defensive.stagger_renders_for_brewmaster.fire", staggerEnv, "PLAYER_ENTERING_WORLD")
    slash("defensive.stagger_renders_for_brewmaster.dump", staggerEnv, "debug bucket")
    eq("defensive.stagger_renders_for_brewmaster.row", printContains(staggerEnv, "Stagger:"), true)
    eq("defensive.stagger_renders_for_brewmaster.value", printContains(staggerEnv, "37.5%"), true)
end

do
    local staggerEnv = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showDefensive = true,
            hideZeroDefensive = false,
            showDodge = false,
            showParry = false,
            showBlock = false,
            showArmor = false,
            showStagger = true,
        },
        unitClassToken = "MONK",
        specIndex = 1,
        specID = 269,
        getStaggerPercentage = function() return 37.5, 37.5 end,
    })
    fireEvent("defensive.stagger_skips_non_brewmaster.fire", staggerEnv, "PLAYER_ENTERING_WORLD")
    slash("defensive.stagger_skips_non_brewmaster.dump", staggerEnv, "debug bucket")
    eq("defensive.stagger_skips_non_brewmaster.no_row", printContains(staggerEnv, "Stagger:"), false)
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

    local itemLevelCases = {
        { "enUS", "iLvl" },
        { "ruRU", "УрП" },
        { "deDE", "GS" },
        { "frFR", "NivObj" },
        { "esES", "NvObj" },
        { "esMX", "NvObj" },
        { "itIT", "LivOg" },
        { "ptBR", "NvItem" },
        { "koKR", "템렙" },
        { "zhCN", "装等" },
        { "zhTW", "裝等" },
    }

    for _, case in ipairs(itemLevelCases) do
        local locale, expected = case[1], case[2]
        runCache(runMigrate({ forceLocale = locale }))
        eq("labels.item_level_" .. locale .. "_full", test.getStyledLabelText("ItemLevel", "full"), expected .. ":")
    end
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
    local cjkFontPath = "Interface\\AddOns\\SharedMedia\\Fonts\\NotoSansCJK-Regular.otf"
    local lsmEnv, lsmAddon, lsmTest = loadStatsPro("enUS", {
        lsmFonts = {
            { name = "Latin Decorative", path = "Interface\\AddOns\\SharedMedia\\Fonts\\Decorative.ttf" },
            { name = "Noto Sans CJK", path = cjkFontPath },
        },
    })
    eq("fonts.lsm_pattern_font_supports_hans", lsmTest.fontSupports(cjkFontPath, "Hans"), true)
    eq("fonts.lsm_find_compatible_font_scans_lsm", lsmTest.findCompatibleFont("Fonts\\FRIZQT__.TTF", "Hans"), cjkFontPath)

    lsmTest.migrateDB()
    lsmEnv.StatsProDB.forceLocale = "auto"
    lsmEnv.StatsProDB.font = "Fonts\\FRIZQT__.TTF"
    lsmTest.cacheSettings()
    local ok, err = pcall(function() lsmAddon:OpenConfigMenu() end)
    check("fonts.lsm_picker_open_constructs_config", ok, err)
    runScript("fonts.lsm_picker_open", lsmEnv.StatsProFontDropdownButton, "OnClick", lsmEnv.StatsProFontDropdownButton)
    eq("fonts.lsm_picker_includes_registered_name", countFrameField(lsmEnv, "fontName", "Noto Sans CJK"), 1)
    local lsmFontButton = findFrame("fonts.lsm_picker_registered_button", lsmEnv, function(frame)
        return frame.fontName == "Noto Sans CJK"
    end)
    eq("fonts.lsm_picker_button_carries_path", lsmFontButton.fontPath, cjkFontPath)
    callScript("fonts.lsm_picker_click_commits_path", lsmFontButton, "OnClick")
    eq("fonts.lsm_picker_click_writes_db_font", lsmEnv.StatsProDB.font, cjkFontPath)

    local autoEnv = loadStatsPro("enUS", {
        statsProDB = { forceLocale = "zhCN", font = "Fonts\\FRIZQT__.TTF" },
        lsmFonts = {
            { name = "Noto Sans CJK", path = cjkFontPath },
        },
    })
    fireEvent("fonts.lsm_locale_auto_switch.fire", autoEnv, "PLAYER_ENTERING_WORLD")
    eq("fonts.lsm_locale_auto_switch.font", autoEnv.StatsProDB.font, cjkFontPath)
end

do
    runMigrate({ fontSize = "15.4" })
    local formatted = test.formatRepairCost(12345)
    local call = env.__lastCoinCall()
    eq("repair.coin_string_uses_normalized_font_size.copper", call.copper, 12345)
    eq("repair.coin_string_uses_normalized_font_size.font", call.fontSize, 15)
    eq("repair.coin_string_uses_normalized_font_size.return", formatted, "coin:12345:15")
end

do
    local tooltipCalls, surfaceCalls = {}, 0
    local costs = { [1] = 100, [2] = 200, [4] = 999, [18] = 999 }
    local _, _, repairTest = loadStatsPro("enUS", {
        statsProDB = {
            showDurability = true,
            showRepairCost = true,
            useWorstDurability = false,
        },
        getInventoryItemDurability = function(slot)
            if slot == 1 then return 50, 100 end
            if slot == 2 then return 25, 100 end
            if slot == 4 or slot == 18 then return 1, 100 end
            if slot == 19 then return 0, 0 end
            return nil, nil
        end,
        getTooltipInventoryItem = function(_, slot)
            tooltipCalls[#tooltipCalls + 1] = slot
            return { slot = slot }
        end,
        surfaceTooltipArgs = function(data)
            surfaceCalls = surfaceCalls + 1
            data.repairCost = costs[data.slot]
        end,
    })
    repairTest.cacheSettings()
    exists("repair.scan_refresh_bridge", repairTest.refreshDurabilityCache)
    repairTest.refreshDurabilityCache()
    local state = repairTest.durabilityState()
    near("repair.scan_avg_percent", state.durabilityValue, 37.5)
    eq("repair.scan_cost_sums_damaged_slots", state.repairCost, 300)
    eq("repair.scan_skips_shirt_and_ranged.calls", table.concat(tooltipCalls, ","), "1,2")
    eq("repair.scan_surfaces_tooltip_args", surfaceCalls, 2)
    eq("repair.scan_no_retry_when_complete", state.retryScheduled, false)
end

do
    local secretRepairCost = setmetatable({}, {
        __tostring = function() error("secret repair cost inspected", 2) end,
    })
    local tooltipDataBySlot = { [1] = { repairCost = 300 } }
    local repairEnv, _, repairTest = loadStatsPro("enUS", {
        statsProDB = {
            showDurability = true,
            showRepairCost = true,
            useWorstDurability = true,
        },
        issecretvalue = function(value) return value == secretRepairCost end,
        getInventoryItemDurability = function(slot)
            if slot == 1 then return 50, 100 end
            if slot == 2 then return 80, 100 end
            if slot == 3 then return 90, 100 end
            return nil, nil
        end,
        getTooltipInventoryItem = function(_, slot)
            if slot == 2 then return { repairCost = secretRepairCost } end
            return tooltipDataBySlot[slot]
        end,
    })
    repairTest.cacheSettings()
    local ok, err = pcall(repairTest.refreshDurabilityCache)
    check("repair.pending_secret_cost_no_error", ok, err)
    local state = repairTest.durabilityState()
    near("repair.pending_worst_percent", state.durabilityValue, 50)
    eq("repair.pending_keeps_partial_known_cost", state.repairCost, 300)
    eq("repair.pending_schedules_retry", state.retryScheduled, true)
    flushTimers("repair.pending_retry_timer", repairEnv, 3, 1)
    eq("repair.pending_retry_marks_dirty", repairTest.durabilityState().dirty, true)
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
        "StatsProSplitItemLevelCheck",
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
        "StatsProStaggerCheck",
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
        "StatsProTextOutlineDropdown",
        "StatsProPanelBackgroundSlider",
        "StatsProLanguageDropdown",
    }
    for _, name in ipairs(appearanceControls) do
        exists("config.appearance_controls_exist." .. name, env[name])
    end

    runDropdownInit("config.dropdown_initializers.display_mode", env.StatsProDisplayModeDropdown)
    runDropdownInit("config.dropdown_initializers.label_style", env.StatsProLabelStyleDropdown)
    runDropdownInit("config.dropdown_initializers.text_outline", env.StatsProTextOutlineDropdown)
    runDropdownInit("config.dropdown_initializers.language", env.StatsProLanguageDropdown)

    do
        local defaultFont = test.copyDefaults().font
        env.DropDownList1Button1.value = "ruRU"
        env.DropDownList1Button2.value = "enUS"
        env.UIDROPDOWNMENU_OPEN_MENU = env.StatsProLanguageDropdown
        env.DropDownList1:Hide()
        env.DropDownList1:Show()

        local ruEnter = exists("config.language_hover_restore.ru_hook",
            env.DropDownList1Button1.hooks.OnEnter and env.DropDownList1Button1.hooks.OnEnter[1])
        local enEnter = exists("config.language_hover_restore.en_hook",
            env.DropDownList1Button2.hooks.OnEnter and env.DropDownList1Button2.hooks.OnEnter[1])

        ok, err = pcall(ruEnter, env.DropDownList1Button1)
        check("config.language_hover_restore.preview_ru", ok, err)
        local afterRuPreview = test.panelFontState()
        check("config.language_hover_restore.ru_swaps_font",
            afterRuPreview.mainLabelFont ~= defaultFont,
            "ruRU hover did not exercise fallback-font preview")

        test.setPanelAppliedStyleForSmoke(defaultFont, 14)
        ok, err = pcall(enEnter, env.DropDownList1Button2)
        check("config.language_hover_restore.preview_en", ok, err)
        local afterEnPreview = test.panelFontState()
        eq("config.language_hover_restore.forces_main_font", afterEnPreview.mainLabelFont, defaultFont)
        eq("config.language_hover_restore.forces_side_font", afterEnPreview.sideLabelFont, defaultFont)

        env.DropDownList1:Hide()
        env.UIDROPDOWNMENU_OPEN_MENU = nil
    end

    selectDropdownValue("config.dropdown_display_mode_split_writes_db", env.StatsProDisplayModeDropdown, "split")
    eq("config.dropdown_display_mode_split_writes_db.value", env.StatsProDB.displayMode, "split")
    eq("config.dropdown_display_mode_split_writes_db.split_check_enabled",
        env.StatsProSplitOffensiveCheck:IsEnabled(), true)

    selectDropdownValue("config.dropdown_label_style_hidden_writes_db", env.StatsProLabelStyleDropdown, "hidden")
    eq("config.dropdown_label_style_hidden_writes_db.value", env.StatsProDB.labelStyle, "hidden")

    selectDropdownValue("config.dropdown_text_outline_none_writes_db", env.StatsProTextOutlineDropdown, "none")
    eq("config.dropdown_text_outline_none_writes_db.value", env.StatsProDB.textOutlineStyle, "none")
    do
        local visualState = test.panelVisualState()
        eq("config.dropdown_text_outline_none_writes_db.cache", visualState.textOutlineStyle, "none")
        eq("config.dropdown_text_outline_none_writes_db.main_label_flags", visualState.mainLabelFlags, nil)
        eq("config.dropdown_text_outline_none_writes_db.side_repair_label_flags", visualState.sideRepairLabelFlags, nil)
    end

    selectDropdownValue("config.dropdown_text_outline_thick_writes_db", env.StatsProTextOutlineDropdown, "thick")
    eq("config.dropdown_text_outline_thick_writes_db.value", env.StatsProDB.textOutlineStyle, "thick")
    do
        local visualState = test.panelVisualState()
        eq("config.dropdown_text_outline_thick_writes_db.cache", visualState.textOutlineStyle, "thick")
        eq("config.dropdown_text_outline_thick_writes_db.main_label_flags", visualState.mainLabelFlags, "THICKOUTLINE")
        eq("config.dropdown_text_outline_thick_writes_db.main_rating_flags", visualState.mainRatingFlags, "THICKOUTLINE")
        eq("config.dropdown_text_outline_thick_writes_db.main_value_flags", visualState.mainValueFlags, "THICKOUTLINE")
        eq("config.dropdown_text_outline_thick_writes_db.main_repair_flags", visualState.mainRepairFlags, "THICKOUTLINE")
        eq("config.dropdown_text_outline_thick_writes_db.main_repair_label_flags", visualState.mainRepairLabelFlags, "THICKOUTLINE")
        eq("config.dropdown_text_outline_thick_writes_db.side_label_flags", visualState.sideLabelFlags, "THICKOUTLINE")
        eq("config.dropdown_text_outline_thick_writes_db.side_rating_flags", visualState.sideRatingFlags, "THICKOUTLINE")
        eq("config.dropdown_text_outline_thick_writes_db.side_value_flags", visualState.sideValueFlags, "THICKOUTLINE")
        eq("config.dropdown_text_outline_thick_writes_db.side_repair_flags", visualState.sideRepairFlags, "THICKOUTLINE")
        eq("config.dropdown_text_outline_thick_writes_db.side_repair_label_flags", visualState.sideRepairLabelFlags, "THICKOUTLINE")
    end

    selectDropdownValue("config.dropdown_language_ruRU_commits_locale", env.StatsProLanguageDropdown, "ruRU")
    eq("config.dropdown_language_ruRU_commits_locale.value", env.StatsProDB.forceLocale, "ruRU")

    clickCheckbox("config.checkbox_visible_updates_db", env.StatsProVisibleCheck, false)
    eq("config.checkbox_visible_updates_db.value", env.StatsProDB.isVisible, false)
    clickCheckbox("config.checkbox_tertiary_master_enables_dependents", env.StatsProTertiaryCheck, true)
    eq("config.checkbox_tertiary_master_enables_dependents.leech", env.StatsProLeechCheck:IsEnabled(), true)
    clickCheckbox("config.checkbox_tertiary_master_disables_dependents", env.StatsProTertiaryCheck, false)
    eq("config.checkbox_tertiary_master_disables_dependents.leech", env.StatsProLeechCheck:IsEnabled(), false)
    clickCheckbox("config.checkbox_defensive_master_enables_dependents", env.StatsProDefensiveCheck, true)
    eq("config.checkbox_defensive_master_enables_dependents.stagger", env.StatsProStaggerCheck:IsEnabled(), true)
    clickCheckbox("config.checkbox_defensive_master_disables_dependents", env.StatsProDefensiveCheck, false)
    eq("config.checkbox_defensive_master_disables_dependents.stagger", env.StatsProStaggerCheck:IsEnabled(), false)
    clickCheckbox("config.checkbox_repair_cost_updates_db", env.StatsProRepairCostCheck, true)
    eq("config.checkbox_repair_cost_updates_db.value", env.StatsProDB.showRepairCost, true)

    local updateBefore = test.cachedUpdateInterval()
    changeSlider("config.slider_refresh_deferred.first", env.StatsProRefreshSlider, 0.2)
    changeSlider("config.slider_refresh_deferred.second", env.StatsProRefreshSlider, 0.8)
    near("config.slider_refresh_deferred.cache_before_timer", test.cachedUpdateInterval(), updateBefore)
    flushTimers("config.slider_refresh_deferred.flush", env, 0.05, 2)
    near("config.slider_refresh_deferred.cache_after_timer", test.cachedUpdateInterval(), 0.8)

    changeSlider("config.slider_text_alpha_immediate", env.StatsProTextAlphaSlider, 55)
    eq("config.slider_text_alpha_immediate.db", env.StatsProDB.textAlpha, 55)
    near("config.slider_text_alpha_immediate.cache", test.cachedTextAlpha(), 0.55)

    changeSlider("config.slider_panel_background_immediate", env.StatsProPanelBackgroundSlider, 45)
    eq("config.slider_panel_background_immediate.db", env.StatsProDB.panelBackgroundAlpha, 45)
    near("config.slider_panel_background_immediate.cache", test.cachedPanelBackgroundAlpha(), 0.45)
    do
        local visualState = test.panelVisualState()
        near("config.slider_panel_background_immediate.main_alpha", visualState.mainBackgroundTextureAlpha, 0.45)
        near("config.slider_panel_background_immediate.side_alpha", visualState.sideBackgroundTextureAlpha, 0.45)
    end

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

    local defaultFont = test.copyDefaults().font
    local previewFont = "Interface\\AddOns\\StatsPro\\Media\\PreviewOnly.ttf"
    test.applyTextStyleToAllPanels(previewFont, 14)
    test.setPanelAppliedStyleForSmoke(defaultFont, 14)
    test.applyTextStyleToAllPanels(defaultFont, 14, true)
    local fontState = test.panelFontState()
    eq("config.font_picker_hover_restore_forces_main_font", fontState.mainLabelFont, defaultFont)
    eq("config.font_picker_hover_restore_forces_side_font", fontState.sideLabelFont, defaultFont)

    local critSwatch = findFrame("config.color_picker.crit_swatch", env, function(frame)
        local color = frame.backdropColor
        return type(frame.scripts.OnClick) == "function"
            and color and color.r == 1 and color.g == 0 and color.b == 0
    end)
    callScript("config.color_picker.open", critSwatch, "OnClick")
    local colorOptions = exists("config.color_picker.options", env.ColorPickerFrame.colorPickerOptions)
    env.__setColorPickerRGB(0.2, 0.3, 0.4)
    ok, err = pcall(colorOptions.swatchFunc)
    check("config.color_picker.select", ok, err)
    ok, err = pcall(env.__acceptColorPicker)
    check("config.color_picker.select_commit", ok, err)
    assertColor("config.color_picker.select_db", env.StatsProDB.colors.crit, 0.2, 0.3, 0.4)
    ok, err = pcall(env.StatsProCloseColorPicker)
    check("config.color_picker.accept_clears_owned_session", ok, err)
    assertColor("config.color_picker.accept_preserves_commit", env.StatsProDB.colors.crit, 0.2, 0.3, 0.4)

    callScript("config.color_picker.reopen_for_cancel", critSwatch, "OnClick")
    env.__setColorPickerRGB(0.6, 0.7, 0.8)
    ok, err = pcall(env.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.preview_before_cancel", ok, err)
    env.__cancelColorPicker()
    assertColor("config.color_picker.cancel_restores_snapshot", env.StatsProDB.colors.crit, 0.2, 0.3, 0.4)

    env.StatsProDB.colors.crit = nil
    callScript("config.color_picker.default_cancel_open", critSwatch, "OnClick")
    env.__setColorPickerRGB(0.7, 0.8, 0.9)
    ok, err = pcall(env.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.default_preview", ok, err)
    env.__cancelColorPicker()
    eq("config.color_picker.default_cancel_preserves_nil", env.StatsProDB.colors.crit, nil)

    callScript("config.color_picker.reset_closes_picker.open", critSwatch, "OnClick")
    slash("config.reset_closes_color_picker", env, "reset")
    eq("config.reset_closes_color_picker.hidden", env.ColorPickerFrame:IsShown(), false)
    assertColor("config.reset_closes_color_picker.default_color", env.StatsProDB.colors.crit, 1, 0, 0)
end

do
    local colorEnv = loadStatsPro("enUS", {
        statsProDB = { colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } } },
    })
    fireEvent("config.color_picker.config_hide.fire", colorEnv, "PLAYER_ENTERING_WORLD")
    slash("config.color_picker.config_hide.open_config", colorEnv, "")
    local critSwatch = findFrame("config.color_picker.config_hide.crit_swatch", colorEnv, function(frame)
        local color = frame.backdropColor
        return type(frame.scripts.OnClick) == "function"
            and color and color.r == 0.2 and color.g == 0.3 and color.b == 0.4
    end)
    callScript("config.color_picker.config_hide.open_picker", critSwatch, "OnClick")
    colorEnv.__setColorPickerRGB(0.6, 0.7, 0.8)
    local ok, err = pcall(colorEnv.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.config_hide.preview", ok, err)
    colorEnv.StatsProConfigFrame:Hide()
    eq("config.color_picker.config_hide_closes_owned_picker.hidden", colorEnv.ColorPickerFrame:IsShown(), false)
    assertColor("config.color_picker.config_hide_cancels_preview.crit", colorEnv.StatsProDB.colors.crit, 0.2, 0.3, 0.4)
end

do
    local colorEnv = loadStatsPro("enUS")
    fireEvent("config.color_picker.switch_swatch.fire", colorEnv, "PLAYER_ENTERING_WORLD")
    slash("config.color_picker.switch_swatch.open_config", colorEnv, "")
    local critSwatch = findFrame("config.color_picker.switch_swatch.crit_swatch", colorEnv, function(frame)
        local color = frame.backdropColor
        return type(frame.scripts.OnClick) == "function"
            and color and color.r == 1 and color.g == 0 and color.b == 0
    end)
    local hasteSwatch = findFrame("config.color_picker.switch_swatch.haste_swatch", colorEnv, function(frame)
        local color = frame.backdropColor
        return type(frame.scripts.OnClick) == "function"
            and color and color.r == 0 and color.g == 0.5 and color.b == 1
    end)
    colorEnv.StatsProDB.colors.crit = nil
    callScript("config.color_picker.switch_swatch.open_crit", critSwatch, "OnClick")
    colorEnv.__setColorPickerRGB(0.2, 0.3, 0.4)
    local ok, err = pcall(colorEnv.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.switch_swatch.preview_crit", ok, err)
    callScript("config.color_picker.switch_swatch.open_haste", hasteSwatch, "OnClick")
    eq("config.color_picker.switch_swatch_cancels_previous_preview.crit", colorEnv.StatsProDB.colors.crit, nil)
    eq("config.color_picker.switch_swatch_cancels_previous_preview.shown", colorEnv.ColorPickerFrame:IsShown(), true)
end

do
    local foreignEnv = loadStatsPro("enUS")
    fireEvent("config.color_picker.foreign.fire", foreignEnv, "PLAYER_ENTERING_WORLD")
    slash("config.color_picker.foreign.open_config", foreignEnv, "")
    local canceled = false
    foreignEnv.ColorPickerFrame:SetupColorPickerAndShow({ cancelFunc = function() canceled = true end })
    foreignEnv.StatsProConfigFrame:Hide()
    eq("config.color_picker.config_hide_preserves_foreign_picker.shown", foreignEnv.ColorPickerFrame:IsShown(), true)
    eq("config.color_picker.config_hide_preserves_foreign_picker.cancel", canceled, false)

    slash("config.color_picker.reset_preserves_foreign_picker", foreignEnv, "reset")
    eq("config.color_picker.reset_preserves_foreign_picker.shown", foreignEnv.ColorPickerFrame:IsShown(), true)
    eq("config.color_picker.reset_preserves_foreign_picker.cancel", canceled, false)
end

do
    local staleEnv = loadStatsPro("enUS")
    fireEvent("config.color_picker.stale.fire", staleEnv, "PLAYER_ENTERING_WORLD")
    slash("config.color_picker.stale.open_config", staleEnv, "")
    local critSwatch = findFrame("config.color_picker.stale.crit_swatch", staleEnv, function(frame)
        local color = frame.backdropColor
        return type(frame.scripts.OnClick) == "function"
            and color and color.r == 1 and color.g == 0 and color.b == 0
    end)
    callScript("config.color_picker.stale.open_crit", critSwatch, "OnClick")
    local oldOptions = staleEnv.ColorPickerFrame.colorPickerOptions
    slash("config.color_picker.stale.reset", staleEnv, "reset")
    staleEnv.__setColorPickerRGB(0.2, 0.3, 0.4)
    local ok, err = pcall(oldOptions.swatchFunc)
    check("config.color_picker.stale_callbacks_noop_after_reset.call", ok, err)
    assertColor("config.color_picker.stale_callbacks_noop_after_reset.crit", staleEnv.StatsProDB.colors.crit, 1, 0, 0)
end

do
    local secret = setmetatable({}, {
        __tostring = function() error("secret tostring inspected", 2) end,
    })
    local secretChecks = 0
    local secretEnv, _, secretTest = loadStatsPro("enUS", {
        issecretvalue = function(value)
            if value == secret then
                secretChecks = secretChecks + 1
                return true
            end
            return false
        end,
    })
    exists("debug.bucket_secret_sanitizer.hook", secretTest.stripDumpEscapes)
    local ok, result = pcall(secretTest.stripDumpEscapes, secret)
    check("debug.bucket_secret_sanitizer_no_string_ops", ok, result)
    eq("debug.bucket_secret_sanitizer_placeholder", result, "<secret>")
    ok, result = pcall(secretTest.isCleanFiniteNumber, secret)
    check("numeric.secret_clean_guard_no_compare", ok, result)
    eq("numeric.secret_clean_guard_returns_false", result, false)
    eq("numeric.secret_clean_guard_checks_secret_first", secretChecks, 2)
    eq("debug.bucket_secret_sanitizer_env_loaded", secretEnv ~= nil, true)
end

print(string.format("StatsPro smoke: PASS (%d assertions)", assertionCount))
