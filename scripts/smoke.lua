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

local STATSPRO_PRINT_PREFIX = "|cff00ff7f[StatsPro]|r "

local function lastPrint(env)
    return env.__prints[#env.__prints]
end

local function clearPrints(env)
    env.__prints = {}
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

local function makeFrame(name, setFontResult)
    local frame = {
        name = name,
        shown = true,
        width = 100,
        height = 20,
        frameLevel = 1,
        frameStrata = "MEDIUM",
        points = {},
        scripts = {},
        hooks = {},
        text = "",
        fontSize = 12,
        enabled = true,
        verticalScroll = 0,
        setFontResult = setFontResult,
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
        if self.setFontResult and self.setFontResult(self, font, size, flags) ~= true then
            return false
        end
        self.font, self.fontSize, self.fontFlags = font, size, flags
        return true
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
    function frame:SetFrameStrata(strata) self.frameStrata = strata end
    function frame:GetFrameStrata() return self.frameStrata end
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
        self.highlightTexture = self.highlightTexture or makeFrame(nil, self.setFontResult)
    end
    function frame:GetHighlightTexture()
        self.highlightTexture = self.highlightTexture or makeFrame(nil, self.setFontResult)
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
    function frame:SetMaxLines(value) self.maxLines = value end
    function frame:SetNumeric() end
    function frame:SetTextInsets() end
    function frame:SetWordWrap(value) self.wordWrap = value end
    function frame:GetStringWidth()
        if self.statsProWidthOverride ~= nil then return self.statsProWidthOverride end
        return #(self.text or "") * ((self.fontSize or 12) * 0.5)
    end
    function frame:GetStringHeight()
        if self.statsProHeightOverride ~= nil then return self.statsProHeightOverride end
        local text = self.text or ""
        local _, lines = text:gsub("\n", "\n")
        return (lines + 1) * (self.fontSize or 12) * (self.statsProStringHeightMultiplier or 1)
    end
    function frame:CreateFontString()
        return makeFrame(nil, self.setFontResult)
    end
    function frame:CreateTexture()
        return makeFrame(nil, self.setFontResult)
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
        rawget = opts.rawget or rawget,
        rawset = rawset,
        select = select,
        setmetatable = setmetatable,
        string = string,
        table = table,
        tonumber = opts.tonumber or tonumber,
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
    env.__staticPopupShows = 0
    env.__lastStaticPopup = nil
    env.__reloadUICalls = 0
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
    env.StatsProArchonTargets = opts.statsProArchonTargets
    env.SwiftStatsDB = opts.swiftStatsDB
    env.SwiftStatsLocalDB = opts.swiftStatsLocalDB
    env.SlashCmdList = {}
    env.UISpecialFrames = {}
    env.StaticPopupDialogs = {}
    env.CANCEL = "Cancel"
    env.StaticPopup_Show = function(key)
        local definition = env.StaticPopupDialogs[key]
        if type(definition) ~= "table" then error("missing static popup " .. tostring(key), 2) end
        env.__staticPopupShows = env.__staticPopupShows + 1
        env.__lastStaticPopup = { key = key, definition = definition }
        return env.__lastStaticPopup
    end
    env.__acceptStaticPopup = function()
        local popup = env.__lastStaticPopup
        env.__lastStaticPopup = nil
        if popup and type(popup.definition.OnAccept) == "function" then
            popup.definition.OnAccept()
        end
    end
    env.__cancelStaticPopup = function()
        local popup = env.__lastStaticPopup
        env.__lastStaticPopup = nil
        if popup and type(popup.definition.OnCancel) == "function" then
            popup.definition.OnCancel()
        end
    end
    env.ReloadUI = opts.reloadUI or function()
        env.__reloadUICalls = env.__reloadUICalls + 1
    end
    env.UIParent = makeFrame("UIParent", opts.setFontResult)
    env.UIParent:SetSize(1920, 1080)
    env.GameTooltip = makeFrame("GameTooltip", opts.setFontResult)
    env.GameTooltip.shown = false
    env.GameTooltip.lines = {}
    function env.GameTooltip:SetOwner(anchor, point)
        self.owner = anchor
        self.ownerPoint = point
        self.lines = {}
    end
    function env.GameTooltip:AddLine(text)
        self.lines[#self.lines + 1] = { left = text }
    end
    function env.GameTooltip:AddDoubleLine(left, right)
        self.lines[#self.lines + 1] = { left = left, right = right }
    end
    env.STANDARD_TEXT_FONT = opts.standardTextFont or "Fonts\\FRIZQT__.TTF"
    local addonMetadataVersion = opts.addonMetadataVersion or "9.8.7"
    env.C_AddOns = {
        GetAddOnMetadata = function(_, field)
            if field == "Version" then return addonMetadataVersion end
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
    env.SettingsPanel = makeFrame("SettingsPanel", opts.setFontResult)
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
                if mediaType == "font" then return opts.lsmGlobalFontPath or paths[name] end
                return nil
            end,
            HashTable = function(_, mediaType)
                if mediaType == "font" then return paths end
                return {}
            end,
        }
    end
    env.LibStub = function(name)
        if name == "LibSharedMedia-3.0" then return lsm end
        return nil
    end
    env.issecretvalue = opts.issecretvalue or function() return false end
    env.issecrettable = opts.issecrettable
    env.CopyTable = deepCopy
    env.tinsert = table.insert
    env.tremove = table.remove
    env.wipe = wipeTable
    env.tContains = contains
    env.GetLocale = function() return currentLocale end
    env.GetAddOnMetadata = env.C_AddOns.GetAddOnMetadata
    env.InCombatLockdown = opts.inCombatLockdown or function() return false end
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
    env.DropDownList1 = makeFrame("DropDownList1", opts.setFontResult)
    for i = 1, 8 do
        env["DropDownList1Button" .. i] = makeFrame("DropDownList1Button" .. i, opts.setFontResult)
    end
    env.ColorPickerFrame = makeFrame("ColorPickerFrame", opts.setFontResult)
    env.ColorPickerFrame.shown = false
    env.ColorPickerFrame.Footer = {
        OkayButton = makeFrame("ColorPickerFrameOkayButton", opts.setFontResult),
        CancelButton = makeFrame("ColorPickerFrameCancelButton", opts.setFontResult),
    }
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
        self.swatchFunc = self.colorPickerOptions.swatchFunc
        self.cancelFunc = self.colorPickerOptions.cancelFunc
        self.extraInfo = self.colorPickerOptions.extraInfo
        self.previousValues = {
            r = self.colorPickerOptions.r,
            g = self.colorPickerOptions.g,
            b = self.colorPickerOptions.b,
            a = self.colorPickerOptions.opacity,
        }
        self.colorRGB = { r = opts and opts.r or 1, g = opts and opts.g or 1, b = opts and opts.b or 1 }
        if type(self.colorPickerOptions.swatchFunc) == "function" then self.colorPickerOptions.swatchFunc() end
        self:Show()
    end
    function env.ColorPickerFrame:GetExtraInfo()
        return self.extraInfo
    end
    function env.__acceptColorPicker()
        local picker = env.ColorPickerFrame
        runFrameHandlers(picker.Footer.OkayButton, "PreClick")
        if type(picker.swatchFunc) == "function" then picker.swatchFunc() end
        picker.colorPickerCancelActive = false
        picker:Hide()
        runFrameHandlers(picker.Footer.OkayButton, "PostClick")
        picker.colorPickerOptions = nil
    end
    function env.__cancelColorPicker()
        local picker = env.ColorPickerFrame
        runFrameHandlers(picker.Footer.CancelButton, "PreClick")
        if picker.shown and picker.colorPickerCancelActive and type(picker.cancelFunc) == "function" then
            picker.cancelFunc(picker.previousValues)
        end
        picker.colorPickerCancelActive = false
        picker:Hide()
        picker.colorPickerOptions = nil
    end
    env.OpenColorPicker = function() end
    env.hooksecurefunc = function(target, methodName, hook)
        local original = target and target[methodName]
        if type(original) ~= "function" or type(hook) ~= "function" then return end
        target[methodName] = function(...)
            local results = { original(...) }
            hook(...)
            return unpack(results)
        end
    end
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
        local frame = makeFrame(name, opts.setFontResult)
        env.__frames[#env.__frames + 1] = frame
        if name then
            env[name] = frame
            env[name .. "Text"] = env[name .. "Text"] or makeFrame(name .. "Text", opts.setFontResult)
            env[name .. "Low"] = env[name .. "Low"] or makeFrame(name .. "Low", opts.setFontResult)
            env[name .. "High"] = env[name .. "High"] or makeFrame(name .. "High", opts.setFontResult)
            env[name .. "Button"] = env[name .. "Button"] or makeFrame(name .. "Button", opts.setFontResult)
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
    env.GetCombatRatingBonusForCombatRatingValue = opts.getCombatRatingBonusForCombatRatingValue
    env.GetDodgeChance = opts.getDodgeChance or zero
    env.GetParryChance = opts.getParryChance or zero
    env.GetBlockChance = opts.getBlockChance or zero
    env.GetLifesteal = opts.getLifesteal or zero
    env.GetAvoidance = opts.getAvoidance or zero
    env.GetSpeed = opts.getSpeed or zero
    env.GetUnitSpeed = opts.getUnitSpeed or function() return 0, 0, 0, 0 end
    env.IsSwimming = opts.isSwimming or function() return false end
    env.IsFlying = opts.isFlying or function() return false end
    env.IsFalling = opts.isFalling or function() return false end
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
    if type(opts.getArmorEffectiveness) == "function" then
        env.C_PaperDollInfo.GetArmorEffectiveness = opts.getArmorEffectiveness
    end
    if opts.paperDollFrameGetArmorReduction ~= false then
        env.PaperDollFrame_GetArmorReduction = opts.paperDollFrameGetArmorReduction or zero
    end
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

local function loadArchonValidatorModule()
    local previous = _G.__STATSPRO_ARCHON_TARGETS_MODULE
    _G.__STATSPRO_ARCHON_TARGETS_MODULE = true
    local chunk, loadErr = loadfile("scripts/check-archon-targets.lua")
    if not chunk then
        _G.__STATSPRO_ARCHON_TARGETS_MODULE = previous
        error(loadErr, 0)
    end
    local ok, moduleOrErr = pcall(chunk)
    _G.__STATSPRO_ARCHON_TARGETS_MODULE = previous
    if not ok then error(moduleOrErr, 0) end
    return moduleOrErr
end

local archonManifest = loadArchonValidatorModule()

local function makeArchonV2Fixture(capturedAt)
    return deepCopy(archonManifest.makeValidFixture(capturedAt or "2026-05-15"))
end

local function setArchonFixtureTargets(fixture, profileKey, classToken, specKey, targets, order)
    local profile = fixture.snapshots[profileKey]
    local specData = profile and profile.specs and profile.specs[classToken] and profile.specs[classToken][specKey]
    if not specData then
        error(string.format("missing Archon fixture spec %s/%s/%s", tostring(profileKey), tostring(classToken), tostring(specKey)), 2)
    end
    specData.targets = deepCopy(targets)
    specData.order = deepCopy(order or { "crit", "haste", "mastery", "versatility" })
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

do
    local archonFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(archonFixture, "mythicPlus", "MAGE", "frost",
        { crit = 1007, haste = 560, mastery = 823, versatility = 97 })
    archonFixture.snapshots.mythicPlus.specs.MAGE.fire = nil
    local archonEnv, _, archonTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        statsProArchonTargets = archonFixture,
    })
    local snapshot = archonTest.getArchonTargetSnapshot("MAGE", "frost")
    eq("archon.snapshot.source", snapshot.sourceUrl, "https://www.archon.gg/wow/builds/frost/mage/mythic-plus/overview/high-keys/all-dungeons/this-week")
    local meta = archonTest.buildArchonTargetMeta("mastery", 700, archonEnv.CR_MASTERY)
    eq("archon.meta.target", meta.target, 823)
    eq("archon.meta.current", meta.current, 700)
    eq("archon.meta.delta", meta.delta, -123)
    eq("archon.meta.rating_cr", meta.ratingCR, archonEnv.CR_MASTERY)
    eq("archon.meta.captured_at", meta.capturedAt, "2026-05-15")
    eq("archon.meta.missing_snapshot", archonTest.getArchonTargetSnapshot("MAGE", "fire"), nil)
    eq("archon.meta.hidden_without_root", archonEnv.StatsProArchonTargets.schemaVersion, 2)

    local dualFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(dualFixture, "mythicPlus", "MAGE", "frost",
        { crit = 1007, haste = 560, mastery = 823, versatility = 97 })
    dualFixture.snapshots.raid.capturedAt = "2026-05-16"
    setArchonFixtureTargets(dualFixture, "raid", "MAGE", "frost",
        { crit = 1044, haste = 551, mastery = 812, versatility = 88 })
    local dualEnv, _, dualTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        statsProDB = {
            targetSnapshot = "raid",
        },
        statsProArchonTargets = dualFixture,
    })
    local okDual, errDual = pcall(dualEnv.__fireEvent, "PLAYER_ENTERING_WORLD")
    check("archon.v2_raid_selected.fire", okDual, errDual)
    local raidSnapshot = dualTest.getArchonTargetSnapshot("MAGE", "frost", "raid")
    eq("archon.v2.raid_snapshot_source", raidSnapshot.sourceUrl, "https://www.archon.gg/wow/builds/frost/mage/raid/overview/mythic/all-bosses")
    local mplusSnapshot = dualTest.getArchonTargetSnapshot("MAGE", "frost", "mythicPlus")
    eq("archon.v2.mplus_snapshot_still_available", mplusSnapshot.targets.mastery, 823)
    local raidMeta = dualTest.buildArchonTargetMeta("mastery", 700, dualEnv.CR_MASTERY)
    eq("archon.v2.selected_raid_target", raidMeta.target, 812)
    eq("archon.v2.selected_raid_label", raidMeta.snapshotLabel, "Raid Mythic All Bosses")
    eq("archon.v2.selected_raid_title", raidMeta.snapshotTitle, "Raid Target")
    eq("archon.v2.selected_raid_captured_at", raidMeta.capturedAt, "2026-05-16")
    dualTest.renderMainPanelForSmoke("Mastery:", "700", "20.0%", 1, nil, nil, { raidMeta })
    dualTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    eq("archon.v2.raid_tooltip_title", dualEnv.GameTooltip.lines[1].left, "StatsPro Raid Target")
    eq("archon.v2.raid_tooltip_snapshot_label", dualEnv.GameTooltip.lines[5].right, "Raid Mythic All Bosses, 16-May-26")

    local corruptPrefEnv, _, corruptPrefTest = loadStatsPro("enUS", {
        statsProDB = {
            targetSnapshot = "arena",
        },
    })
    local okCorruptPref, errCorruptPref = pcall(corruptPrefEnv.__fireEvent, "PLAYER_ENTERING_WORLD")
    check("archon.corrupt_target_snapshot_pref.fire", okCorruptPref, errCorruptPref)
    eq("archon.corrupt_target_snapshot_pref.cache_default", corruptPrefTest.cachedTargetSnapshot(), "mythicPlus")

    local v1RaidPrefEnv, _, v1RaidPrefTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        statsProDB = {
            targetSnapshot = "raid",
        },
        statsProArchonTargets = {
            schemaVersion = 1,
            capturedAt = "2026-05-15",
            specs = {
                MAGE = {
                    frost = {
                        sourceUrl = "https://www.archon.gg/wow/builds/frost/mage/mythic-plus/overview/high-keys/all-dungeons/this-week",
                        targets = { mastery = 823 },
                    },
                },
            },
        },
    })
    local okV1RaidPref, errV1RaidPref = pcall(v1RaidPrefEnv.__fireEvent, "PLAYER_ENTERING_WORLD")
    check("archon.v1_with_raid_pref_falls_back.fire", okV1RaidPref, errV1RaidPref)
    local v1FallbackMeta = v1RaidPrefTest.buildArchonTargetMeta("mastery", 700, v1RaidPrefEnv.CR_MASTERY)
    eq("archon.v1_with_raid_pref_falls_back.target", v1FallbackMeta.target, 823)
    eq("archon.v1_with_raid_pref_falls_back.key", v1FallbackMeta.snapshotKey, "mythicPlus")

    local v2MissingRaidFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(v2MissingRaidFixture, "mythicPlus", "MAGE", "frost",
        { crit = 100, haste = 200, mastery = 823, versatility = 400 })
    v2MissingRaidFixture.snapshots.raid = nil
    local v2MissingRaidEnv, _, v2MissingRaidTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        statsProDB = {
            targetSnapshot = "raid",
        },
        statsProArchonTargets = v2MissingRaidFixture,
    })
    local okV2MissingRaid, errV2MissingRaid = pcall(v2MissingRaidEnv.__fireEvent, "PLAYER_ENTERING_WORLD")
    check("archon.v2_missing_raid_profile_falls_back.fire", okV2MissingRaid, errV2MissingRaid)
    local v2FallbackMeta = v2MissingRaidTest.buildArchonTargetMeta("mastery", 700, v2MissingRaidEnv.CR_MASTERY)
    eq("archon.v2_missing_raid_profile_falls_back.target", v2FallbackMeta.target, 823)
    eq("archon.v2_missing_raid_profile_falls_back.key", v2FallbackMeta.snapshotKey, "mythicPlus")

    local v2RaidMissingSpecFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(v2RaidMissingSpecFixture, "mythicPlus", "MAGE", "frost",
        { crit = 100, haste = 200, mastery = 823, versatility = 400 })
    v2RaidMissingSpecFixture.snapshots.raid.specs.MAGE.frost = nil
    local v2RaidMissingSpecEnv, _, v2RaidMissingSpecTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        statsProDB = {
            targetSnapshot = "raid",
        },
        statsProArchonTargets = v2RaidMissingSpecFixture,
    })
    local okV2RaidMissingSpec, errV2RaidMissingSpec = pcall(v2RaidMissingSpecEnv.__fireEvent, "PLAYER_ENTERING_WORLD")
    check("archon.v2_raid_profile_missing_spec_no_mplus_fallback.fire", okV2RaidMissingSpec, errV2RaidMissingSpec)
    eq("archon.v2_raid_profile_missing_spec_no_mplus_fallback.meta", v2RaidMissingSpecTest.buildArchonTargetMeta("mastery", 700, v2RaidMissingSpecEnv.CR_MASTERY), nil)

    for index, spec in ipairs(archonManifest.specs) do
        local parityFixture = makeArchonV2Fixture("2026-05-15")
        local expectedTarget = 1000 + index
        setArchonFixtureTargets(parityFixture, "mythicPlus", spec.classToken, spec.specKey,
            { crit = 100, haste = 200, mastery = expectedTarget, versatility = 400 })
        local parityEnv, _, parityTest = loadStatsPro("enUS", {
            unitClassToken = spec.classToken,
            specIndex = 1,
            specID = spec.specID,
            statsProArchonTargets = parityFixture,
        })
        local parityMeta = parityTest.buildArchonTargetMeta("mastery", 900, parityEnv.CR_MASTERY)
        eq("archon.spec_manifest_runtime_resolves." .. spec.classToken .. "." .. spec.specKey, parityMeta and parityMeta.target, expectedTarget)
    end

    local wrongMappingFixture = makeArchonV2Fixture("2026-05-15")
    wrongMappingFixture.snapshots.mythicPlus.specs.MAGE.frost = nil
    local _, _, wrongMappingTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        statsProArchonTargets = wrongMappingFixture,
    })
    eq("archon.spec_manifest_runtime_wrong_mapping_returns_nil", wrongMappingTest.buildArchonTargetMeta("mastery", 900), nil)

    local devourerFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(devourerFixture, "mythicPlus", "DEMONHUNTER", "devourer",
        { crit = 259, haste = 1036, mastery = 1187, versatility = 58 })
    local devourerArchonEnv, _, devourerArchonTest = loadStatsPro("enUS", {
        unitClassToken = "DEMONHUNTER",
        specIndex = 1,
        specID = 1480,
        statsProArchonTargets = devourerFixture,
    })
    local devourerMeta = devourerArchonTest.buildArchonTargetMeta("mastery", 1000, devourerArchonEnv.CR_MASTERY)
    eq("archon.devourer.spec_id_maps", devourerMeta.target, 1187)
    eq("archon.devourer.delta", devourerMeta.delta, -187)
    eq("archon.devourer.snapshot_key", devourerMeta.snapshotKey, "mythicPlus")

    local badTargetFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(badTargetFixture, "mythicPlus", "MAGE", "frost",
        { crit = 100, haste = 200, mastery = math.huge, versatility = 400 })
    local _, _, badTargetArchonTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        statsProArchonTargets = badTargetFixture,
    })
    eq("archon.meta.nonfinite_target_returns_nil", badTargetArchonTest.buildArchonTargetMeta("mastery", 1000), nil)

    local secretChecks = 0
    local _, _, secretArchonTest = loadStatsPro("enUS", {
        issecretvalue = function(value)
            if value == -1 then
                secretChecks = secretChecks + 1
                return true
            end
            return false
        end,
    })
    eq("archon.meta.secret_guard_returns_nil", secretArchonTest.buildArchonTargetMeta("mastery", -1), nil)
    eq("archon.meta.secret_guard_before_compare", secretChecks, 1)
end

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
    eq("panel.frame_strata.main", env.StatsProFrame:GetFrameStrata(), "BACKGROUND")
    eq("panel.frame_strata.side", env.StatsProDefensiveFrame:GetFrameStrata(), "BACKGROUND")
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
    local scenarios = {
        { name = "full_dual", style = "full", label = "Crit:\nMastery:", rating = "700 |\n500 |", value = "12.0%\n20.0%", showRating = true, showPercentage = true, labelW = 91, coldW = 228, expectedW = 207 },
        { name = "short_dual", style = "short", label = "C:\nM:", rating = "700 |\n500 |", value = "12.0%\n20.0%", showRating = true, showPercentage = true, labelW = 35, coldW = 172, expectedW = 151 },
        { name = "hidden_dual", style = "hidden", label = "", rating = "700 |\n500 |", value = "12.0%\n20.0%", showRating = true, showPercentage = true, coldW = 114, expectedW = 114 },
        { name = "full_single", style = "full", label = "Crit:\nMastery:", rating = "700\n500", value = "", showRating = true, showPercentage = false, labelW = 91, coldW = 170, expectedW = 156 },
        { name = "short_single", style = "short", label = "C:\nM:", rating = "12.0%\n20.0%", value = "", showRating = false, showPercentage = true, labelW = 35, coldW = 114, expectedW = 100 },
        { name = "hidden_single", style = "hidden", label = "", rating = "12.0%\n20.0%", value = "", showRating = false, showPercentage = true, coldW = 80, expectedW = 80 },
    }

    local function pointX(points)
        return points and points[1] and points[1][4] or nil
    end

    local function positiveNumber(name, value)
        check(name, type(value) == "number" and value > 0, value)
    end

    for _, scenario in ipairs(scenarios) do
        local secretWidth, secretHeight = {}, {}
        local scenarioEnv, _, scenarioTest = loadStatsPro("enUS", {
            statsProDB = {
                labelStyle = scenario.style,
                fontSize = 14,
                showRating = scenario.showRating,
                showPercentage = scenario.showPercentage,
            },
            issecretvalue = function(value)
                return value == secretWidth or value == secretHeight
            end,
        })
        scenarioTest.cacheSettings()

        if scenario.style ~= "hidden" then
            scenarioTest.setPanelMeasurementOverride("main", "label", secretWidth, secretHeight)
        end
        scenarioTest.setPanelMeasurementOverride("main", "rating", secretWidth, secretHeight)
        scenarioTest.setPanelMeasurementOverride("main", "value", secretWidth, secretHeight)

        local ok, err = pcall(scenarioTest.renderMainPanelForSmoke,
            scenario.label, scenario.rating, scenario.value, 2)
        check("panel.secret_cold." .. scenario.name .. ".render", ok, err)
        local cold = scenarioTest.panelVisualState()
        local coldRatingX = pointX(cold.mainRatingPoints)
        local coldValueX = pointX(cold.mainValuePoints)

        positiveNumber("panel.secret_cold." .. scenario.name .. ".rating_width", cold.mainRenderedRatingW)
        eq("panel.secret_cold." .. scenario.name .. ".rating_cache_stays_clean", cold.mainCachedRatingW, nil)
        eq("panel.secret_cold." .. scenario.name .. ".rating_height_cache_stays_clean", cold.mainCachedRatingH, nil)
        eq("panel.secret_cold." .. scenario.name .. ".line_height", cold.mainLastLineH, 14)
        eq("panel.secret_cold." .. scenario.name .. ".frame_height", cold.mainFrameHeight, 28)
        eq("panel.secret_cold." .. scenario.name .. ".frame_width", cold.mainFrameWidth, scenario.coldW)
        if scenario.style == "hidden" then
            eq("panel.secret_cold." .. scenario.name .. ".label_width_ignored", cold.mainCachedLabelW, nil)
            eq("panel.secret_cold." .. scenario.name .. ".rendered_label_width", cold.mainRenderedLabelW, 0)
        else
            positiveNumber("panel.secret_cold." .. scenario.name .. ".label_width", cold.mainRenderedLabelW)
            eq("panel.secret_cold." .. scenario.name .. ".label_cache_stays_clean", cold.mainCachedLabelW, nil)
            eq("panel.secret_cold." .. scenario.name .. ".label_height_cache_stays_clean", cold.mainCachedLabelH, nil)
        end
        if scenario.value ~= "" then
            positiveNumber("panel.secret_cold." .. scenario.name .. ".value_width", cold.mainRenderedValueW)
            eq("panel.secret_cold." .. scenario.name .. ".value_cache_stays_clean", cold.mainCachedValueW, nil)
            eq("panel.secret_cold." .. scenario.name .. ".value_height_cache_stays_clean", cold.mainCachedValueH, nil)
            check("panel.secret_cold." .. scenario.name .. ".dual_anchor_separation",
                type(coldRatingX) == "number" and type(coldValueX) == "number" and coldRatingX < coldValueX,
                tostring(coldRatingX) .. " / " .. tostring(coldValueX))
            eq("panel.secret_cold." .. scenario.name .. ".value_anchor", coldValueX, 0)
            if type(cold.mainRenderedValueW) == "number" then
                eq("panel.secret_cold." .. scenario.name .. ".rating_anchor",
                    coldRatingX, -(cold.mainRenderedValueW + 2))
            end
        else
            eq("panel.secret_cold." .. scenario.name .. ".inactive_value_cache_stays_clean", cold.mainCachedValueW, nil)
            eq("panel.secret_cold." .. scenario.name .. ".no_rendered_value_width", cold.mainRenderedValueW, 0)
            eq("panel.secret_cold." .. scenario.name .. ".single_rating_anchor", coldRatingX, 0)
            eq("panel.secret_cold." .. scenario.name .. ".single_value_anchor", coldValueX, 0)
        end

        if scenario.style ~= "hidden" then
            scenarioTest.setPanelMeasurementOverride("main", "label", scenario.labelW, 42)
        end
        scenarioTest.setPanelMeasurementOverride("main", "rating", 63, 44)
        scenarioTest.setPanelMeasurementOverride("main", "value", scenario.value ~= "" and 49 or 0,
            scenario.value ~= "" and 40 or 0)
        scenarioTest.renderMainPanelForSmoke(scenario.label, scenario.rating, scenario.value, 2)
        local recovered = scenarioTest.panelVisualState()
        local recoveredRatingX = pointX(recovered.mainRatingPoints)
        local recoveredValueX = pointX(recovered.mainValuePoints)

        eq("panel.secret_recovery." .. scenario.name .. ".rating_width", recovered.mainCachedRatingW, 63)
        eq("panel.secret_recovery." .. scenario.name .. ".rating_height", recovered.mainCachedRatingH, 44)
        eq("panel.secret_recovery." .. scenario.name .. ".value_width",
            recovered.mainCachedValueW, scenario.value ~= "" and 49 or 0)
        eq("panel.secret_recovery." .. scenario.name .. ".frame_width", recovered.mainFrameWidth, scenario.expectedW)
        if scenario.style == "hidden" then
            eq("panel.secret_recovery." .. scenario.name .. ".line_height", recovered.mainLastLineH, 22)
            eq("panel.secret_recovery." .. scenario.name .. ".frame_height", recovered.mainFrameHeight, 44)
        else
            eq("panel.secret_recovery." .. scenario.name .. ".label_width", recovered.mainCachedLabelW, scenario.labelW)
            eq("panel.secret_recovery." .. scenario.name .. ".label_height", recovered.mainCachedLabelH, 42)
            eq("panel.secret_recovery." .. scenario.name .. ".line_height", recovered.mainLastLineH, 21)
            eq("panel.secret_recovery." .. scenario.name .. ".frame_height", recovered.mainFrameHeight, 42)
        end
        if scenario.value ~= "" then
            eq("panel.secret_recovery." .. scenario.name .. ".rating_anchor", recoveredRatingX, -51)
            eq("panel.secret_recovery." .. scenario.name .. ".value_anchor", recoveredValueX, 0)
        else
            eq("panel.secret_recovery." .. scenario.name .. ".rating_anchor", recoveredRatingX, 0)
            eq("panel.secret_recovery." .. scenario.name .. ".value_anchor", recoveredValueX, 0)
        end
        eq("panel.secret_recovery." .. scenario.name .. ".env_loaded", scenarioEnv ~= nil, true)
    end
end

do
    local secretWidth, secretHeight = {}, {}
    local resizeEnv, _, resizeTest = loadStatsPro("enUS", {
        statsProDB = {
            labelStyle = "full",
            fontSize = 14,
            showRating = true,
            showPercentage = true,
        },
        issecretvalue = function(value)
            return value == secretWidth or value == secretHeight
        end,
    })
    resizeTest.cacheSettings()
    resizeTest.renderMainPanelForSmoke("Crit:", "700 |", "12.0%", 1)
    local applied = resizeTest.applyTextStyleToAllPanels(resizeTest.copyDefaults().font, 20, true)
    eq("panel.secret_resize.style_applied", applied, true)
    for _, column in ipairs({ "label", "rating", "value" }) do
        resizeTest.setPanelMeasurementOverride("main", column, secretWidth, secretHeight)
    end
    resizeTest.renderMainPanelForSmoke("Crit:", "700 |", "12.0%", 1)
    local cold = resizeTest.panelVisualState()
    eq("panel.secret_resize.cold_frame_width", cold.mainFrameWidth, 324)
    eq("panel.secret_resize.cold_line_height", cold.mainLastLineH, 20)
    eq("panel.secret_resize.cold_frame_height", cold.mainFrameHeight, 20)
    eq("panel.secret_resize.clean_width_cache_preserved", cold.mainCachedLabelW, 35)
    eq("panel.secret_resize.height_cache_invalidated", cold.mainCachedLabelH, nil)

    resizeTest.setPanelMeasurementOverride("main", "label", 70, 24)
    resizeTest.setPanelMeasurementOverride("main", "rating", 50, 22)
    resizeTest.setPanelMeasurementOverride("main", "value", 40, 20)
    resizeTest.renderMainPanelForSmoke("Crit:", "700 |", "12.0%", 1)
    local recovered = resizeTest.panelVisualState()
    eq("panel.secret_resize.recovery_frame_width", recovered.mainFrameWidth, 164)
    eq("panel.secret_resize.recovery_line_height", recovered.mainLastLineH, 24)
    eq("panel.secret_resize.recovery_frame_height", recovered.mainFrameHeight, 24)
    eq("panel.secret_resize.recovery_label_cache", recovered.mainCachedLabelW, 70)
    eq("panel.secret_resize.env_loaded", resizeEnv ~= nil, true)
end

do
    local secretWidth, secretHeight = {}, {}
    local repairEnv, _, repairTest = loadStatsPro("enUS", {
        statsProDB = {
            labelStyle = "full",
            fontSize = 14,
            showRating = true,
            showPercentage = true,
        },
        issecretvalue = function(value)
            return value == secretWidth or value == secretHeight
        end,
    })
    repairTest.cacheSettings()
    repairTest.setPanelMeasurementOverride("main", "repair", secretWidth, secretHeight)
    repairTest.renderMainPanelForSmoke("C:", "700", "12.0%", 1, "coin", "Repair:")
    local cold = repairTest.panelVisualState()
    eq("panel.secret_repair.cold_render_width", cold.mainRenderedRepairW, 112)
    eq("panel.secret_repair.cold_cache_stays_clean", cold.mainCachedRepairW, nil)
    eq("panel.secret_repair.cold_frame_width", cold.mainFrameWidth, 128)
    eq("panel.secret_repair.cold_rating_anchor", cold.mainRatingPoints[1][4], -91)
    eq("panel.secret_repair.cold_value_anchor", cold.mainValuePoints[1][4], -54)
    eq("panel.secret_repair.cold_frame_height", cold.mainFrameHeight, 29)

    repairTest.setPanelMeasurementOverride("main", "repair", 28, 14)
    repairTest.renderMainPanelForSmoke("C:", "700", "12.0%", 1, "coin", "Repair:")
    local recovered = repairTest.panelVisualState()
    eq("panel.secret_repair.recovery_render_width", recovered.mainRenderedRepairW, 28)
    eq("panel.secret_repair.recovery_cache", recovered.mainCachedRepairW, 28)
    eq("panel.secret_repair.recovery_frame_width", recovered.mainFrameWidth, 80)
    eq("panel.secret_repair.recovery_rating_anchor", recovered.mainRatingPoints[1][4], -37)
    eq("panel.secret_repair.recovery_value_anchor", recovered.mainValuePoints[1][4], 0)

    repairTest.renderMainPanelForSmoke("C:", "700", "12.0%", 1)
    local disabled = repairTest.panelVisualState()
    eq("panel.secret_repair.disabled_render_width", disabled.mainRenderedRepairW, 0)
    eq("panel.secret_repair.disabled_cache_reset", disabled.mainCachedRepairW, 0)
    eq("panel.secret_repair.disabled_coin_hidden", disabled.mainRepairShown, false)
    eq("panel.secret_repair.disabled_frame_width", disabled.mainFrameWidth, 80)

    repairTest.setPanelMeasurementOverride("main", "repair", secretWidth, secretHeight)
    repairTest.setPanelMeasurementOverride("main", "repairLabel", secretWidth, secretHeight)
    repairTest.renderMainPanelForSmoke("", "", "", 0, "coin", "Repair:")
    local repairOnly = repairTest.panelVisualState()
    eq("panel.secret_repair.only_render_width", repairOnly.mainRenderedRepairW, 112)
    eq("panel.secret_repair.only_label_width", repairOnly.mainRepairLabelWidth, 80)
    eq("panel.secret_repair.only_frame_width", repairOnly.mainFrameWidth, 194)
    eq("panel.secret_repair.only_frame_height", repairOnly.mainFrameHeight, 14)
    eq("panel.secret_repair.only_label_shown", repairOnly.mainRepairLabelShown, true)

    repairEnv.StatsProDB.labelStyle = "hidden"
    repairTest.cacheSettings()
    repairTest.renderMainPanelForSmoke("", "", "", 0, "coin", "")
    local hiddenLabel = repairTest.panelVisualState()
    eq("panel.secret_repair.hidden_label_width", hiddenLabel.mainRepairLabelWidth, 0)
    eq("panel.secret_repair.hidden_label_frame_width", hiddenLabel.mainFrameWidth, 112)
    eq("panel.secret_repair.hidden_label_hidden", hiddenLabel.mainRepairLabelShown, false)

    repairEnv.StatsProDB.labelStyle = "full"
    repairTest.cacheSettings()
    repairTest.setPanelMeasurementOverride("main", "repair", 28, 14)
    repairTest.setPanelMeasurementOverride("main", "repairLabel", 49, 14)
    repairTest.renderMainPanelForSmoke("", "", "", 0, "coin", "Repair:")
    local repairOnlyRecovered = repairTest.panelVisualState()
    eq("panel.secret_repair.only_recovery_coin_cache", repairOnlyRecovered.mainCachedRepairW, 28)
    eq("panel.secret_repair.only_recovery_label_cache", repairOnlyRecovered.mainCachedRepairLabelW, 49)
    eq("panel.secret_repair.only_recovery_frame_width", repairOnlyRecovered.mainFrameWidth, 80)
    eq("panel.secret_repair.env_loaded", repairEnv ~= nil, true)
end

do
    local secretWidth, secretHeight = {}, {}
    local splitEnv, splitAddon, splitTest = loadStatsPro("enUS", {
        statsProDB = {
            displayMode = "split",
            labelStyle = "full",
            fontSize = 14,
            showMainStat = false,
            showStamina = false,
            showOffensive = true,
            showCrit = true,
            showHaste = false,
            showMastery = false,
            showVersatility = false,
            showTertiary = true,
            showLeech = true,
            showAvoidance = false,
            showSpeed = false,
            showDefensive = false,
            showItemLevel = false,
            showDurability = false,
            showRepairCost = false,
            showRating = true,
            showPercentage = true,
            hideZeroOffensive = false,
            hideZeroTertiary = false,
            splitOffensive = false,
            splitTertiary = true,
        },
        getCritChance = function() return 12 end,
        getLifesteal = function() return 5 end,
        getCombatRating = function() return 700 end,
        issecretvalue = function(value)
            return value == secretWidth or value == secretHeight
        end,
    })
    for _, panelName in ipairs({ "main", "side" }) do
        for _, column in ipairs({ "label", "rating", "value" }) do
            splitTest.setPanelMeasurementOverride(panelName, column, secretWidth, secretHeight)
        end
    end

    local okFire, errFire = pcall(splitEnv.__fireEvent, "PLAYER_ENTERING_WORLD")
    check("panel.secret_split.cold_fire", okFire, errFire)
    local cold = splitTest.panelVisualState()
    eq("panel.secret_split.cold_main_shown", cold.mainShown, true)
    eq("panel.secret_split.cold_side_shown", cold.sideShown, true)
    check("panel.secret_split.cold_main_routes_crit", cold.mainLabelText:find("Crit", 1, true) ~= nil, cold.mainLabelText)
    check("panel.secret_split.cold_side_routes_leech", cold.sideLabelText:find("Leech", 1, true) ~= nil, cold.sideLabelText)
    check("panel.secret_split.cold_main_widths",
        type(cold.mainRenderedRatingW) == "number" and cold.mainRenderedRatingW > 0
            and type(cold.mainRenderedValueW) == "number" and cold.mainRenderedValueW > 0,
        tostring(cold.mainRenderedRatingW) .. " / " .. tostring(cold.mainRenderedValueW))
    check("panel.secret_split.cold_side_widths",
        type(cold.sideRenderedRatingW) == "number" and cold.sideRenderedRatingW > 0
            and type(cold.sideRenderedValueW) == "number" and cold.sideRenderedValueW > 0,
        tostring(cold.sideRenderedRatingW) .. " / " .. tostring(cold.sideRenderedValueW))
    local coldMainRatingX = cold.mainRatingPoints and cold.mainRatingPoints[1] and cold.mainRatingPoints[1][4]
    local coldSideRatingX = cold.sideRatingPoints and cold.sideRatingPoints[1] and cold.sideRatingPoints[1][4]
    check("panel.secret_split.cold_main_anchor", type(coldMainRatingX) == "number" and coldMainRatingX < 0, coldMainRatingX)
    check("panel.secret_split.cold_side_anchor", type(coldSideRatingX) == "number" and coldSideRatingX < 0, coldSideRatingX)

    splitTest.setPanelMeasurementOverride("main", "label", 91, 14)
    splitTest.setPanelMeasurementOverride("main", "rating", 63, 14)
    splitTest.setPanelMeasurementOverride("main", "value", 49, 14)
    splitTest.setPanelMeasurementOverride("side", "label", 70, 18)
    splitTest.setPanelMeasurementOverride("side", "rating", 56, 18)
    splitTest.setPanelMeasurementOverride("side", "value", 42, 18)
    splitAddon:RunUpdateStatsSafe()
    local recovered = splitTest.panelVisualState()
    eq("panel.secret_split.recovery_main_width", recovered.mainFrameWidth, 207)
    eq("panel.secret_split.recovery_side_width", recovered.sideFrameWidth, 172)
    eq("panel.secret_split.recovery_main_height", recovered.mainFrameHeight, 14)
    eq("panel.secret_split.recovery_side_height", recovered.sideFrameHeight, 18)
    eq("panel.secret_split.recovery_main_rating_width", recovered.mainCachedRatingW, 63)
    eq("panel.secret_split.recovery_side_rating_width", recovered.sideCachedRatingW, 56)
    eq("panel.secret_split.recovery_main_anchor", recovered.mainRatingPoints[1][4], -51)
    eq("panel.secret_split.recovery_side_anchor", recovered.sideRatingPoints[1][4], -44)
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

do
    test.renderMainPanelForSmoke("Crit:\nMastery:", "921\n812", "29.6%\n30.0%", 2, nil, nil, {
        false,
        { statKey = "mastery", target = 1043, current = 812, delta = -231, capturedAt = "2026-05-15" },
    })
    local tooltipState = test.mainPanelTooltipState()
    eq("tooltip.overlay_count", tooltipState.overlayCount, 2)
    eq("tooltip.first_row_hidden", tooltipState.firstShown, false)
    eq("tooltip.second_row_shown", tooltipState.secondShown, true)
    eq("tooltip.target_row_dense_alignment", tooltipState.lastTargetRows[2].statKey, "mastery")
end

do
    local hiddenEnv, _, hiddenTest = loadStatsPro("enUS", {
        statsProDB = {
            labelStyle = "hidden",
            fontSize = 14,
        },
    })
    hiddenTest.cacheSettings()
    hiddenTest.setMainPanelStringHeightMultiplier("rating", 1.5)
    hiddenTest.renderMainPanelForSmoke("", "903 |\n199 |", "29.6%\n9.7%", 2, "438 coin", "Repair:", {
        { statKey = "crit" },
        { statKey = "haste" },
    })
    local visualState = hiddenTest.panelVisualState()
    near("panel.hidden_labels_uses_rating_height.line_h", visualState.mainLastLineH, 21)
    eq("panel.hidden_labels_uses_rating_height.frame_height", visualState.mainFrameHeight, 64)
    local repairPoint = exists("panel.hidden_labels_uses_rating_height.repair_point", visualState.mainRepairPoints and visualState.mainRepairPoints[1])
    eq("panel.hidden_labels_uses_rating_height.repair_y", repairPoint[5], -43)
    eq("panel.hidden_labels_uses_rating_height.overlay_height", visualState.mainFirstOverlayHeight, 21)
    local secondOverlayPoint = exists("panel.hidden_labels_uses_rating_height.second_overlay_point",
        visualState.mainSecondOverlayPoints and visualState.mainSecondOverlayPoints[1])
    eq("panel.hidden_labels_uses_rating_height.second_overlay_y", secondOverlayPoint[5], -21)
    eq("panel.hidden_labels_uses_rating_height.env_loaded", hiddenEnv ~= nil, true)
end

do
    local tooltipEnv, _, tooltipTest = loadStatsPro("enUS", {
        getCombatRatingBonusForCombatRatingValue = function(_, value)
            return value / 70
        end,
    })
    tooltipTest.renderMainPanelForSmoke("Mastery:", "812", "30.0%", 1, nil, nil, {
        { statKey = "crit", ratingCR = tooltipEnv.CR_CRIT_MELEE, target = 1043, current = 812, currentPct = 30.0, delta = -231, capturedAt = "2026-05-15" },
    })
    tooltipTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    eq("tooltip.on_enter_shows", tooltipEnv.GameTooltip:IsShown(), true)
    eq("tooltip.on_enter_title", tooltipEnv.GameTooltip.lines[1].left, "StatsPro M+ Target")
    eq("tooltip.on_enter_target", tooltipEnv.GameTooltip.lines[2].right, "1043 (~33.3%)")
    eq("tooltip.on_enter_target_label", tooltipEnv.GameTooltip.lines[2].left, "Target:")
    eq("tooltip.on_enter_current_label", tooltipEnv.GameTooltip.lines[3].left, "Current:")
    eq("tooltip.on_enter_current_value", tooltipEnv.GameTooltip.lines[3].right, "812 (~30.0%)")
    eq("tooltip.on_enter_missing", tooltipEnv.GameTooltip.lines[4].left, "Missing:")
    eq("tooltip.on_enter_missing_value", tooltipEnv.GameTooltip.lines[4].right, "231 (~+3.3%)")
    eq("tooltip.on_enter_snapshot_label", tooltipEnv.GameTooltip.lines[5].left, "Snapshot:")
    eq("tooltip.on_enter_snapshot_date", tooltipEnv.GameTooltip.lines[5].right, "M+ High Keys, 15-May-26")
    tooltipTest.fireMainPanelTooltipOverlayForSmoke(1, "OnLeave")
    eq("tooltip.on_leave_hides", tooltipEnv.GameTooltip:IsShown(), false)
    tooltipTest.fireMainPanelTooltipOverlayForSmoke(1, "OnMouseUp", "RightButton")
    exists("tooltip.right_click_forwards_settings", tooltipEnv.StatsProConfigFrame)
    tooltipTest.fireMainPanelTooltipOverlayForSmoke(1, "OnDragStart")
    eq("tooltip.drag_forwards_parent_flag", tooltipEnv.StatsProFrame.wasDragging, true)
    tooltipTest.fireMainPanelTooltipOverlayForSmoke(1, "OnDragStop")
    local okFlush, flushed = pcall(tooltipEnv.__flushTimers, 0.1)
    check("tooltip.drag_guard_timer", okFlush, flushed)
    eq("tooltip.drag_guard_timer.count", flushed, 1)
    eq("tooltip.drag_guard_clears", tooltipEnv.StatsProFrame.wasDragging, false)
end

do
    local localizedTooltipEnv, _, localizedTooltipTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        statsProDB = {
            forceLocale = "ruRU",
        },
        getCombatRatingBonusForCombatRatingValue = function(_, value)
            return value / 70
        end,
        statsProArchonTargets = {
            schemaVersion = 2,
            source = "archon",
            snapshots = {
                mythicPlus = {
                    label = "M+ High Keys",
                    title = "M+ Target",
                    capturedAt = "2026-05-15",
                    specs = {
                        MAGE = {
                            frost = {
                                targets = { crit = 1043 },
                            },
                        },
                    },
                },
            },
        },
    })
    local okLocalizedTooltip, errLocalizedTooltip = pcall(localizedTooltipEnv.__fireEvent, "PLAYER_ENTERING_WORLD")
    check("tooltip.localized_ruRU.fire", okLocalizedTooltip, errLocalizedTooltip)
    local localizedMeta = localizedTooltipTest.buildArchonTargetMeta("crit", 812, localizedTooltipEnv.CR_CRIT_MELEE, 30.0)
    localizedTooltipTest.renderMainPanelForSmoke("Крит:", "812", "30.0%", 1, nil, nil, { localizedMeta })
    localizedTooltipTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    eq("tooltip.localized_ruRU_title", localizedTooltipEnv.GameTooltip.lines[1].left, "StatsPro Цель M+")
    eq("tooltip.localized_ruRU_target_label", localizedTooltipEnv.GameTooltip.lines[2].left, "Цель:")
    eq("tooltip.localized_ruRU_current_label", localizedTooltipEnv.GameTooltip.lines[3].left, "Сейчас:")
    eq("tooltip.localized_ruRU_missing_label", localizedTooltipEnv.GameTooltip.lines[4].left, "Не хватает:")
    eq("tooltip.localized_ruRU_snapshot_label", localizedTooltipEnv.GameTooltip.lines[5].left, "Снимок:")
    eq("tooltip.localized_ruRU_snapshot_value", localizedTooltipEnv.GameTooltip.lines[5].right, "M+ высокие ключи, 15-май-26")
end

do
    local masteryEnv, _, masteryTest = loadStatsPro("enUS", {
        getCombatRatingBonusForCombatRatingValue = function(_, value)
            return value / 100
        end,
        getMasteryEffect = function()
            return 0, 2
        end,
    })
    masteryTest.renderMainPanelForSmoke("Mastery:", "800", "16.0%", 1, nil, nil, {
        { statKey = "mastery", ratingCR = masteryEnv.CR_MASTERY, target = 1000, current = 800, currentPct = 16.0, delta = -200, capturedAt = "2026-05-15" },
    })
    masteryTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    eq("tooltip.mastery_target_effect_pct", masteryEnv.GameTooltip.lines[2].right, "1000 (~20.0%)")
    eq("tooltip.mastery_current_effect_pct", masteryEnv.GameTooltip.lines[3].right, "800 (~16.0%)")
    eq("tooltip.mastery_missing_effect_pct", masteryEnv.GameTooltip.lines[4].right, "200 (~+4.0%)")
end

do
    local overEnv, _, overTest = loadStatsPro("enUS", {
        getCombatRatingBonusForCombatRatingValue = function(_, value)
            return value / 100
        end,
    })
    overTest.renderMainPanelForSmoke("Crit:", "1200", "17.0%", 1, nil, nil, {
        { statKey = "crit", ratingCR = overEnv.CR_CRIT_MELEE, target = 1000, current = 1200, currentPct = 17.0, delta = 200, capturedAt = "2027-02-29" },
    })
    overTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    eq("tooltip.over_target_pct", overEnv.GameTooltip.lines[2].right, "1000 (~15.0%)")
    eq("tooltip.over_current_pct", overEnv.GameTooltip.lines[3].right, "1200 (~17.0%)")
    eq("tooltip.over_value_pct", overEnv.GameTooltip.lines[4].right, "+200 (~+2.0%)")
    eq("tooltip.invalid_snapshot_date_fallback", overEnv.GameTooltip.lines[5].right, "M+ High Keys, 2027-02-29")
end

do
    local masteryLiveEnv, _, masteryLiveTest = loadStatsPro("enUS", {
        getCombatRatingBonusForCombatRatingValue = function(_, value)
            return value / 50
        end,
        getMasteryEffect = function()
            return 0, 1
        end,
    })
    masteryLiveTest.renderMainPanelForSmoke("Mastery:", "515", "22.4%", 1, nil, nil, {
        { statKey = "mastery", colorKey = "mastery", ratingCR = masteryLiveEnv.CR_MASTERY, target = 350, current = 515, currentPct = 22.4, delta = 165, capturedAt = "2026-05-15" },
    })
    masteryLiveTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    eq("tooltip.mastery_live_like_target_uses_projected_total_pct", masteryLiveEnv.GameTooltip.lines[2].right, "350 (~19.1%)")
    eq("tooltip.mastery_live_like_current_uses_panel_pct", masteryLiveEnv.GameTooltip.lines[3].right, "515 (~22.4%)")
    eq("tooltip.mastery_live_like_over_uses_rating_delta_pct", masteryLiveEnv.GameTooltip.lines[4].right, "+165 (~+3.3%)")
end

do
    local fallbackEnv, _, fallbackTest = loadStatsPro("enUS", {
        getCombatRatingBonusForCombatRatingValue = function()
            error("rating bonus unavailable")
        end,
    })
    fallbackTest.renderMainPanelForSmoke("Crit:", "812", "30.0%", 1, nil, nil, {
        { statKey = "crit", ratingCR = fallbackEnv.CR_CRIT_MELEE, target = 1043, current = 812, currentPct = 30.0, delta = -231, capturedAt = "2026-05-15" },
    })
    fallbackTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    eq("tooltip.rating_bonus_fallback_target", fallbackEnv.GameTooltip.lines[2].right, "1043")
    eq("tooltip.rating_bonus_fallback_current", fallbackEnv.GameTooltip.lines[3].right, "812 (~30.0%)")
    eq("tooltip.rating_bonus_fallback_missing", fallbackEnv.GameTooltip.lines[4].right, "231")
end

do
    local matchedEnv, _, matchedTest = loadStatsPro("enUS", {
        getCombatRatingBonusForCombatRatingValue = function(_, value)
            return value / 100
        end,
    })
    matchedTest.renderMainPanelForSmoke("Crit:", "1000", "20.0%", 1, nil, nil, {
        { statKey = "crit", ratingCR = matchedEnv.CR_CRIT_MELEE, target = 1000, current = 1000, currentPct = 20.0, delta = 0, capturedAt = "2026-05-15" },
    })
    matchedTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    eq("tooltip.matched_label", matchedEnv.GameTooltip.lines[4].left, "Matched:")
    eq("tooltip.matched_value_pct", matchedEnv.GameTooltip.lines[4].right, "0 (~+0.0%)")
end

do
    local zeroSignEnv, _, zeroSignTest = loadStatsPro("enUS", {
        getCombatRatingBonusForCombatRatingValue = function(_, value)
            return value == 999 and 1.00004 or 1
        end,
    })
    zeroSignTest.renderMainPanelForSmoke("Crit:", "999", "20.0%", 1, nil, nil, {
        { statKey = "crit", ratingCR = zeroSignEnv.CR_CRIT_MELEE, target = 1000, current = 999, currentPct = 20.0, delta = -1, capturedAt = "2026-05-15" },
    })
    zeroSignTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    eq("tooltip.signed_zero_bonus_uses_positive_zero", zeroSignEnv.GameTooltip.lines[4].right, "1 (~+0.0%)")
end

do
    local secretBonusEnv, _, secretBonusTest = loadStatsPro("enUS", {
        issecretvalue = function(value)
            return value == -999
        end,
        getCombatRatingBonusForCombatRatingValue = function()
            return -999
        end,
    })
    secretBonusTest.renderMainPanelForSmoke("Crit:", "812", "30.0%", 1, nil, nil, {
        { statKey = "crit", ratingCR = secretBonusEnv.CR_CRIT_MELEE, target = 1043, current = 812, currentPct = 30.0, delta = -231, capturedAt = "2026-05-15" },
    })
    secretBonusTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    eq("tooltip.secret_rating_bonus_fallback_target", secretBonusEnv.GameTooltip.lines[2].right, "1043")
    eq("tooltip.secret_rating_bonus_fallback_current", secretBonusEnv.GameTooltip.lines[3].right, "812 (~30.0%)")
    eq("tooltip.secret_rating_bonus_fallback_missing", secretBonusEnv.GameTooltip.lines[4].right, "231")
end

do
    local meta = { statKey = "mastery", target = 1043, current = 812, delta = -231 }
    local main = test.routeRenderBlocks({
        {
            splitKey = "splitCharacter",
            sectionKey = "Character",
            labels = { "Stamina:" },
            ratings = { "100" },
            values = { "" },
            repairStr = "",
        },
        {
            splitKey = "splitOffensive",
            sectionKey = "Offensive",
            labels = { "Mastery:" },
            ratings = { "812" },
            values = { "30.0%" },
            targetRows = { meta },
            repairStr = "",
        },
    }, "sectioned", nil, "full")
    eq("tooltip.route_header_character", main.targetRows[1], false)
    eq("tooltip.route_character_row", main.targetRows[2], false)
    eq("tooltip.route_header_offensive", main.targetRows[3], false)
    eq("tooltip.route_offensive_row", main.targetRows[4], meta)
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

local function checkedDropdownValue(name, entries)
    local checkedValue
    local checkedCount = 0
    for _, entry in ipairs(entries or {}) do
        if entry.checked then
            checkedCount = checkedCount + 1
            checkedValue = entry.value
        end
    end
    eq(name .. ".checked_count", checkedCount, 1)
    return checkedValue
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

do
    local versionEnv, versionAddon, versionTest = loadStatsPro("enUS", {
        addonMetadataVersion = "9.8.7",
    })
    local currentRelease = versionTest.currentRelease()
    eq("version.source_metadata_is_numeric",
        versionEnv.C_AddOns.GetAddOnMetadata("StatsPro", "Version"), "9.8.7")
    eq("version.source_checkout_is_dev",
        versionTest.addonVersion(), "9.8.7-dev")
    eq("version.packaged_tag_strips_prefix",
        versionAddon.ResolveAddonVersion("v2.3.4", "9.8.7", currentRelease), "2.3.4")
    eq("version.packaged_branch_preserves_suffix",
        versionAddon.ResolveAddonVersion("v2.3.4-12-gabcdef0", "9.8.7", currentRelease),
        "2.3.4-12-gabcdef0")
    eq("version.unsubstituted_token_is_dev",
        versionAddon.ResolveAddonVersion("@project-version@", "@project-version@", currentRelease),
        currentRelease .. "-dev")
    eq("version.malformed_token_uses_numeric_metadata",
        versionAddon.ResolveAddonVersion("2.3.4", "9.8.7", currentRelease),
        "9.8.7-dev")
    eq("version.missing_metadata_uses_release_fallback",
        versionAddon.ResolveAddonVersion("@project-version@", nil, currentRelease),
        currentRelease .. "-dev")
    fireEvent("version.source_checkout_debug.fire", versionEnv, "PLAYER_ENTERING_WORLD")
    clearPrints(versionEnv)
    slash("version.source_checkout_debug.dump", versionEnv, "debug")
    eq("version.source_checkout_debug.has_dev_suffix",
        printContains(versionEnv, "debug v9.8.7-dev  dbVer"), true)
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

local function findBlockBySplitKey(name, blocks, splitKey)
    for _, block in ipairs(blocks or {}) do
        if block.splitKey == splitKey then return block end
    end
    fail(name, "missing block " .. tostring(splitKey))
end

local function findTargetMeta(blocks, statKey)
    for _, block in ipairs(blocks or {}) do
        for _, meta in ipairs(block.targetRows or {}) do
            if type(meta) == "table" and meta.statKey == statKey then return meta end
        end
    end
    return nil
end

do
    local coloredEnv, _, coloredTest = loadStatsPro("enUS", {
        statsProDB = {
            matchValueColorToStat = true,
            colors = {
                mastery = { r = 0, g = 1, b = 0 },
            },
        },
        getCombatRatingBonusForCombatRatingValue = function(_, value)
            return value / 50
        end,
        getMasteryEffect = function()
            return 0, 1
        end,
    })
    fireEvent("tooltip.match_color_cache.fire", coloredEnv, "PLAYER_ENTERING_WORLD")
    coloredTest.renderMainPanelForSmoke("Mastery:", "515", "22.4%", 1, nil, nil, {
        { statKey = "mastery", colorKey = "mastery", ratingCR = coloredEnv.CR_MASTERY, target = 350, current = 515, currentPct = 22.4, delta = 165, capturedAt = "2026-05-15" },
    })
    coloredTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    eq("tooltip.match_color_target_value_stays_neutral", coloredEnv.GameTooltip.lines[2].right, "350 (~19.1%)")
    eq("tooltip.match_color_current_value", coloredEnv.GameTooltip.lines[3].right, "|cff00ff00" .. "515 (~22.4%)" .. "|r")
    eq("tooltip.match_color_over_value_uses_status_color", coloredEnv.GameTooltip.lines[4].right, "+165 (~+3.3%)")
    eq("tooltip.match_color_snapshot_plain", coloredEnv.GameTooltip.lines[5].right, "M+ High Keys, 15-May-26")

    coloredTest.renderMainPanelForSmoke("Mastery:", "200", "16.0%", 1, nil, nil, {
        { statKey = "mastery", colorKey = "mastery", ratingCR = coloredEnv.CR_MASTERY, target = 350, current = 200, currentPct = 16.0, delta = -150, capturedAt = "2026-05-15" },
    })
    coloredTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    eq("tooltip.match_color_missing_value_uses_status_color", coloredEnv.GameTooltip.lines[4].right, "150 (~+3.0%)")
end

do
    local debugRatingEnv = loadStatsPro("enUS", {
        getCombatRating = function(cr)
            return cr == 1 and 700 or 350
        end,
        getCombatRatingBonus = function(cr)
            return cr == 1 and 10 or 5
        end,
        getCombatRatingBonusForCombatRatingValue = function(_, value)
            return value / 70
        end,
        getMasteryEffect = function()
            return 0, 2
        end,
    })
    slash("debug.rating_conversion.dump", debugRatingEnv, "debug rating")
    eq("debug.rating_conversion.crit", printContains(debugRatingEnv, "debug rating crit: rating=700 live=10.00 converted=10.00 delta=0.00"), true)
    eq("debug.rating_conversion.mastery", printContains(debugRatingEnv, "debug rating mastery: rating=350 live=5.00 converted=5.00 delta=0.00 effective=10.00 coefficient=2.00"), true)
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
    local futureVersion = test.currentDBVersion() + 1
    local db = runMigrate({ dbVersion = futureVersion, futureOnly = "keep" })
    eq("db.future_version_noop.version", db.dbVersion, futureVersion)
    eq("db.future_version_noop.future_field", db.futureOnly, "keep")
    eq("db.future_version_noop.no_force_locale_backfill", db.forceLocale, nil)
    eq("db.future_version_noop.no_colors_backfill", db.colors, nil)
    eq("db.future_version_noop.no_font_backfill", db.font, nil)
end

do
    local futureVersion = test.currentDBVersion() + 1
    local db = { dbVersion = futureVersion }
    runCache(db)
    eq("db.future_sparse_cache_no_backfill.version", db.dbVersion, futureVersion)
    eq("db.future_sparse_cache_no_backfill.force_locale", db.forceLocale, nil)
    eq("db.future_sparse_cache_no_backfill.colors", db.colors, nil)
    eq("db.future_sparse_cache_no_backfill.display_mode", db.displayMode, nil)
    eq("db.future_sparse_cache_no_backfill.label", test.getStyledLabelText("ItemLevel", "full"), "iLvl:")
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
    clearPrints(posEnv)
    slash("position.debug_malformed_savedvars_no_error.dump", posEnv, "debug")
    eq("position.debug_malformed_savedvars_no_error.main",
        printContains(posEnv, "main: CENTER/CENTER  +0/+0"), true)
    eq("position.debug_malformed_savedvars_no_error.side",
        printContains(posEnv, "side: CENTER/CENTER  +0/-100"), true)
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
        dbVersion = 999,
        minimapPos = 90,
        updateNoticeShown = true,
        privatePayload = { shouldNotCopy = true },
        colors = {
            crit = { r = 0.2, g = 0.3, b = 0.4 },
            unknown = { r = 0.9, g = 0.8, b = 0.7 },
        },
    }
    local localSource = { fontSize = 12 }
    local legacyEnv, _, legacyTest = loadStatsPro("enUS", {
        statsProDB = {},
        swiftStatsDB = legacySource,
        swiftStatsLocalDB = localSource,
    })
    fireEvent("lifecycle.pew_legacy_priority.fire", legacyEnv, "PLAYER_ENTERING_WORLD")
    eq("lifecycle.pew_legacy_priority.font_size", legacyEnv.StatsProDB.fontSize, 17)
    assertColor("lifecycle.pew_legacy_priority.color_copied", legacyEnv.StatsProDB.colors.crit, 0.2, 0.3, 0.4)
    eq("lifecycle.pew_legacy_priority.foreign_version_ignored",
        legacyEnv.StatsProDB.dbVersion, legacyTest.currentDBVersion())
    eq("lifecycle.pew_legacy_priority.minimap_ignored", legacyEnv.StatsProDB.minimapPos, nil)
    eq("lifecycle.pew_legacy_priority.runtime_flag_ignored", legacyEnv.StatsProDB.updateNoticeShown, nil)
    eq("lifecycle.pew_legacy_priority.unknown_ignored", legacyEnv.StatsProDB.privatePayload, nil)
    eq("lifecycle.pew_legacy_priority.unknown_color_ignored", legacyEnv.StatsProDB.colors.unknown, nil)
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
    local futureVersion = test.currentDBVersion() + 1
    local legacyEnv = loadStatsPro("enUS", {
        statsProDB = {},
        swiftStatsDB = {
            dbVersion = futureVersion,
            fontSize = 17,
            useLocalizedLabels = false,
            showStrength = true,
            colors = { primary = { r = 0.2, g = 0.3, b = 0.4 } },
        },
    })
    fireEvent("lifecycle.pew_swiftstats_foreign_db_version_ignored.fire", legacyEnv, "PLAYER_ENTERING_WORLD")
    eq("lifecycle.pew_swiftstats_foreign_db_version_ignored.version",
        legacyEnv.StatsProDB.dbVersion, test.currentDBVersion())
    eq("lifecycle.pew_swiftstats_foreign_db_version_ignored.font_size",
        legacyEnv.StatsProDB.fontSize, 17)
    eq("lifecycle.pew_swiftstats_foreign_db_version_ignored.non_upstream_locale_ignored",
        legacyEnv.StatsProDB.forceLocale, "auto")
    eq("lifecycle.pew_swiftstats_foreign_db_version_ignored.main_stat",
        legacyEnv.StatsProDB.showMainStat, true)
    assertColor("lifecycle.pew_swiftstats_foreign_db_version_ignored.main_color",
        legacyEnv.StatsProDB.colors.mainStat, 0.2, 0.3, 0.4)
    eq("lifecycle.pew_swiftstats_foreign_db_version_ignored.primary_removed",
        legacyEnv.StatsProDB.colors.primary, nil)

    local localEnv = loadStatsPro("enUS", {
        statsProDB = {},
        swiftStatsLocalDB = {
            dbVersion = futureVersion,
            fontSize = 18,
            showDurability = true,
        },
    })
    fireEvent("lifecycle.pew_swiftstatslocal_future_db_version_backfills_defaults.fire", localEnv, "PLAYER_ENTERING_WORLD")
    eq("lifecycle.pew_swiftstatslocal_future_db_version_refused.version",
        localEnv.StatsProDB.dbVersion, test.currentDBVersion())
    eq("lifecycle.pew_swiftstatslocal_future_db_version_refused.font_size",
        localEnv.StatsProDB.fontSize, 14)
    eq("lifecycle.pew_swiftstatslocal_future_db_version_refused.repair_default",
        localEnv.StatsProDB.showRepairCost, false)
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
    local existingEnv = loadStatsPro("enUS", {
        statsProDB = { fontSize = 22 },
        swiftStatsDB = { fontSize = 17 },
    })
    fireEvent("legacy_import.existing_db_pew.fire", existingEnv, "PLAYER_ENTERING_WORLD")
    eq("legacy_import.existing_db_pew.no_unprompted_overwrite", existingEnv.StatsProDB.fontSize, 22)
    eq("legacy_import.existing_db_pew.no_popup", existingEnv.__staticPopupShows, 0)
end

do
    local fallbackEnv = loadStatsPro("enUS", {
        statsProDB = {},
        swiftStatsDB = { updateNoticeShown = true, minimapPos = 45 },
        swiftStatsLocalDB = { dbVersion = test.currentDBVersion(), fontSize = 18 },
    })
    fireEvent("legacy_import.ignored_public_falls_back_local.fire", fallbackEnv, "PLAYER_ENTERING_WORLD")
    eq("legacy_import.ignored_public_falls_back_local.font_size", fallbackEnv.StatsProDB.fontSize, 18)
end

do
    local invalidEnv = loadStatsPro("enUS", {
        statsProDB = {},
        swiftStatsDB = {
            fontSize = 18,
            point = "TOPLEFT",
            relativePoint = "TOPLEFT",
            xOfs = 4001,
            yOfs = -25,
            colors = { crit = { r = 2, g = 0.3, b = 0.4 } },
        },
    })
    fireEvent("legacy_import.invalid_groups.pew", invalidEnv, "PLAYER_ENTERING_WORLD")
    eq("legacy_import.invalid_groups.supported_scalar_imported", invalidEnv.StatsProDB.fontSize, 18)
    eq("legacy_import.invalid_groups.position_rejected_atomically", invalidEnv.StatsProDB.point, "CENTER")
    eq("legacy_import.invalid_groups.position_x_default", invalidEnv.StatsProDB.xOfs, 0)
    assertColor("legacy_import.invalid_groups.color_rejected", invalidEnv.StatsProDB.colors.crit, 1, 0, 0)
end

do
    local missingEnv = loadStatsPro("enUS")
    fireEvent("legacy_import.missing_source.pew", missingEnv, "PLAYER_ENTERING_WORLD")
    local beforeFontSize = missingEnv.StatsProDB.fontSize
    clearPrints(missingEnv)
    slash("legacy_import.missing_source.request", missingEnv, "import")
    eq("legacy_import.missing_source.no_popup", missingEnv.__staticPopupShows, 0)
    eq("legacy_import.missing_source.no_mutation", missingEnv.StatsProDB.fontSize, beforeFontSize)
    eq("legacy_import.missing_source.guidance",
        printContains(missingEnv, "Enable SwiftStats for one login"), true)

    missingEnv.SwiftStatsDB = { updateNoticeShown = true, minimapPos = 45 }
    clearPrints(missingEnv)
    slash("legacy_import.no_supported_fields.request", missingEnv, "import")
    eq("legacy_import.no_supported_fields.no_popup", missingEnv.__staticPopupShows, 0)
    eq("legacy_import.no_supported_fields.message",
        printContains(missingEnv, "no supported settings"), true)
end

do
    local secretValue = {}
    local secretEnv = loadStatsPro("enUS", {
        statsProDB = { fontSize = 20 },
        swiftStatsDB = {
            fontSize = secretValue,
            isVisible = secretValue,
            colors = { crit = { r = secretValue, g = 0.2, b = 0.3 } },
        },
        issecretvalue = function(value) return value == secretValue end,
    })
    fireEvent("legacy_import.secret_source.pew", secretEnv, "PLAYER_ENTERING_WORLD")
    clearPrints(secretEnv)
    slash("legacy_import.secret_source.request", secretEnv, "import")
    eq("legacy_import.secret_source.no_popup", secretEnv.__staticPopupShows, 0)
    eq("legacy_import.secret_source.no_mutation", secretEnv.StatsProDB.fontSize, 20)
    eq("legacy_import.secret_source.unsupported_message",
        printContains(secretEnv, "no supported settings"), true)
end

do
    local secretRoot = {}
    local secretRootEnv = loadStatsPro("enUS", {
        statsProDB = { fontSize = 20 },
        swiftStatsDB = secretRoot,
        issecrettable = function(value) return value == secretRoot end,
    })
    fireEvent("legacy_import.secret_root.pew", secretRootEnv, "PLAYER_ENTERING_WORLD")
    clearPrints(secretRootEnv)
    slash("legacy_import.secret_root.request", secretRootEnv, "import")
    eq("legacy_import.secret_root.no_popup", secretRootEnv.__staticPopupShows, 0)
    eq("legacy_import.secret_root.no_mutation", secretRootEnv.StatsProDB.fontSize, 20)
end

do
    local inaccessibleRoot = {}
    local baseRawGet = rawget
    local inaccessibleEnv = loadStatsPro("enUS", {
        statsProDB = { fontSize = 20 },
        swiftStatsDB = inaccessibleRoot,
        rawget = function(source, key)
            if source == inaccessibleRoot then error("inaccessible legacy table") end
            return baseRawGet(source, key)
        end,
    })
    fireEvent("legacy_import.inaccessible_root.pew", inaccessibleEnv, "PLAYER_ENTERING_WORLD")
    clearPrints(inaccessibleEnv)
    slash("legacy_import.inaccessible_root.request", inaccessibleEnv, "import")
    eq("legacy_import.inaccessible_root.no_popup", inaccessibleEnv.__staticPopupShows, 0)
    eq("legacy_import.inaccessible_root.no_mutation", inaccessibleEnv.StatsProDB.fontSize, 20)
end

do
    local secretColors = { crit = { r = 0.2, g = 0.3, b = 0.4 } }
    local nestedSecretEnv = loadStatsPro("enUS", {
        statsProDB = { fontSize = 20 },
        swiftStatsDB = { fontSize = 18, colors = secretColors },
        issecrettable = function(value) return value == secretColors end,
    })
    fireEvent("legacy_import.secret_nested_table.pew", nestedSecretEnv, "PLAYER_ENTERING_WORLD")
    slash("legacy_import.secret_nested_table.request", nestedSecretEnv, "import")
    nestedSecretEnv.__acceptStaticPopup()
    eq("legacy_import.secret_nested_table.scalar_imported", nestedSecretEnv.StatsProDB.fontSize, 18)
    assertColor("legacy_import.secret_nested_table.color_rejected",
        nestedSecretEnv.StatsProDB.colors.crit, 1, 0, 0)
end

do
    local source = {
        point = "TOPLEFT",
        relativePoint = "TOPLEFT",
        xOfs = 123,
        yOfs = -234,
        fontSize = 19,
        showStrength = true,
        fontBeforeAutoSwitch = "Fonts\\ARIALN.TTF",
        minimapPos = 120,
        unknown = "drop me",
        colors = {
            primary = { r = 0.2, g = 0.3, b = 0.4 },
            crit = { r = 0.4, g = 0.5, b = 0.6 },
            evil = { r = 1, g = 0, b = 1 },
        },
    }
    source.unknownCycle = {}
    source.unknownCycle.self = source.unknownCycle
    setmetatable(source, { __index = function() error("legacy source __index must not run") end })
    local lateEnv = loadStatsPro("enUS", { statsProDB = {} })
    fireEvent("legacy_import.late.pew_without_source", lateEnv, "PLAYER_ENTERING_WORLD")
    eq("legacy_import.late.defaults_initialized", lateEnv.StatsProDB.fontSize, 14)
    lateEnv.SwiftStatsDB = source
    fireEvent("legacy_import.late.second_pew", lateEnv, "PLAYER_ENTERING_WORLD")
    eq("legacy_import.late.second_pew_no_auto_overwrite", lateEnv.StatsProDB.fontSize, 14)

    slash("legacy_import.late.request_cancel", lateEnv, "import")
    eq("legacy_import.late.popup_shown", lateEnv.__staticPopupShows, 1)
    eq("legacy_import.late.request_no_mutation", lateEnv.StatsProDB.fontSize, 14)
    lateEnv.__cancelStaticPopup()
    eq("legacy_import.late.cancel_no_mutation", lateEnv.StatsProDB.fontSize, 14)
    eq("legacy_import.late.cancel_no_reload", lateEnv.__reloadUICalls, 0)

    slash("legacy_import.late.request_accept", lateEnv, "import")
    eq("legacy_import.late.second_popup_shown", lateEnv.__staticPopupShows, 2)
    source.fontSize = 8
    source.xOfs = 999
    source.colors.primary.r = 0.9
    lateEnv.__acceptStaticPopup()
    eq("legacy_import.late.accept_reload", lateEnv.__reloadUICalls, 1)
    eq("legacy_import.late.accept_snapshot_font_size", lateEnv.StatsProDB.fontSize, 19)
    eq("legacy_import.late.accept_snapshot_x", lateEnv.StatsProDB.xOfs, 123)
    eq("legacy_import.late.accept_primary_toggle_migrated", lateEnv.StatsProDB.showMainStat, true)
    assertColor("legacy_import.late.accept_primary_color_migrated",
        lateEnv.StatsProDB.colors.mainStat, 0.2, 0.3, 0.4)
    assertColor("legacy_import.late.accept_crit_color", lateEnv.StatsProDB.colors.crit, 0.4, 0.5, 0.6)
    eq("legacy_import.late.accept_unknown_ignored", lateEnv.StatsProDB.unknown, nil)
    eq("legacy_import.late.accept_minimap_ignored", lateEnv.StatsProDB.minimapPos, nil)
    eq("legacy_import.late.accept_transient_ignored", lateEnv.StatsProDB.fontBeforeAutoSwitch, nil)
    eq("legacy_import.late.accept_unknown_color_ignored", lateEnv.StatsProDB.colors.evil, nil)
    eq("legacy_import.late.accept_current_version", lateEnv.StatsProDB.dbVersion, test.currentDBVersion())
    local loadedPoint = lateEnv.StatsProFrame.points[1]
    eq("legacy_import.late.accept_position_loaded.point", loadedPoint[1], "TOPLEFT")
    eq("legacy_import.late.accept_position_loaded.x", loadedPoint[4], 123)
    fireEvent("legacy_import.late.logout_preserves_imported_position", lateEnv, "PLAYER_LOGOUT")
    eq("legacy_import.late.logout_position_x", lateEnv.StatsProDB.xOfs, 123)
end

do
    local futureDestination = test.currentDBVersion() + 1
    local futureEnv = loadStatsPro("enUS", {
        statsProDB = { dbVersion = futureDestination, fontSize = 23 },
        swiftStatsDB = { fontSize = 17 },
    })
    fireEvent("legacy_import.future_destination.pew", futureEnv, "PLAYER_ENTERING_WORLD")
    clearPrints(futureEnv)
    slash("legacy_import.future_destination.request", futureEnv, "import")
    eq("legacy_import.future_destination.no_popup", futureEnv.__staticPopupShows, 0)
    eq("legacy_import.future_destination.no_mutation", futureEnv.StatsProDB.fontSize, 23)
    eq("legacy_import.future_destination.message", printContains(futureEnv, "newer schema"), true)
end

do
    local secretVersion = {}
    local secretTonumberCalls = 0
    local function guardedTonumber(value)
        if value == secretVersion then
            secretTonumberCalls = secretTonumberCalls + 1
            error("secret dbVersion reached tonumber")
        end
        return tonumber(value)
    end
    local localVersionEnv = loadStatsPro("enUS", {
        statsProDB = { fontSize = 20 },
        swiftStatsLocalDB = { dbVersion = secretVersion, fontSize = 17 },
        issecretvalue = function(value) return value == secretVersion end,
        tonumber = guardedTonumber,
    })
    fireEvent("legacy_import.secret_local_version.pew", localVersionEnv, "PLAYER_ENTERING_WORLD")
    clearPrints(localVersionEnv)
    slash("legacy_import.secret_local_version.request", localVersionEnv, "import")
    eq("legacy_import.secret_local_version.no_popup", localVersionEnv.__staticPopupShows, 0)
    eq("legacy_import.secret_local_version.no_mutation", localVersionEnv.StatsProDB.fontSize, 20)
    eq("legacy_import.secret_local_version.no_tonumber", secretTonumberCalls, 0)
    eq("legacy_import.secret_local_version.message", printContains(localVersionEnv, "newer schema"), true)

    secretTonumberCalls = 0
    local secretDestinationEnv = loadStatsPro("enUS", {
        statsProDB = { dbVersion = secretVersion, fontSize = 23 },
        swiftStatsDB = { fontSize = 17 },
        issecretvalue = function(value) return value == secretVersion end,
        tonumber = guardedTonumber,
    })
    fireEvent("legacy_import.secret_destination.pew", secretDestinationEnv, "PLAYER_ENTERING_WORLD")
    clearPrints(secretDestinationEnv)
    slash("legacy_import.secret_destination.request", secretDestinationEnv, "import")
    eq("legacy_import.secret_destination.no_popup", secretDestinationEnv.__staticPopupShows, 0)
    eq("legacy_import.secret_destination.no_mutation", secretDestinationEnv.StatsProDB.fontSize, 23)
    eq("legacy_import.secret_destination.no_tonumber", secretTonumberCalls, 0)
    eq("legacy_import.secret_destination.message", printContains(secretDestinationEnv, "newer schema"), true)

    secretTonumberCalls = 0
    local acceptEnv = loadStatsPro("enUS", {
        statsProDB = { fontSize = 23 },
        swiftStatsDB = { fontSize = 17 },
        issecretvalue = function(value) return value == secretVersion end,
        tonumber = guardedTonumber,
    })
    fireEvent("legacy_import.secret_destination_accept.pew", acceptEnv, "PLAYER_ENTERING_WORLD")
    slash("legacy_import.secret_destination_accept.request", acceptEnv, "import")
    acceptEnv.StatsProDB.dbVersion = secretVersion
    clearPrints(acceptEnv)
    acceptEnv.__acceptStaticPopup()
    eq("legacy_import.secret_destination_accept.no_reload", acceptEnv.__reloadUICalls, 0)
    eq("legacy_import.secret_destination_accept.no_mutation", acceptEnv.StatsProDB.fontSize, 23)
    eq("legacy_import.secret_destination_accept.no_tonumber", secretTonumberCalls, 0)
    eq("legacy_import.secret_destination_accept.message", printContains(acceptEnv, "newer schema"), true)
end

do
    local reloadCalls = 0
    local reloadFailureEnv = loadStatsPro("enUS", {
        statsProDB = {
            point = "BOTTOM",
            relativePoint = "BOTTOM",
            xOfs = 45,
            yOfs = 67,
            fontSize = 20,
        },
        swiftStatsDB = { fontSize = 17 },
        reloadUI = function()
            reloadCalls = reloadCalls + 1
            error("ReloadUI unavailable")
        end,
    })
    fireEvent("legacy_import.reload_failure.pew", reloadFailureEnv, "PLAYER_ENTERING_WORLD")
    slash("legacy_import.reload_failure.request", reloadFailureEnv, "import")
    clearPrints(reloadFailureEnv)
    reloadFailureEnv.__acceptStaticPopup()
    eq("legacy_import.reload_failure.attempted_once", reloadCalls, 1)
    eq("legacy_import.reload_failure.db_restored", reloadFailureEnv.StatsProDB.fontSize, 20)
    eq("legacy_import.reload_failure.position_restored",
        reloadFailureEnv.StatsProFrame.points[1][1], "BOTTOM")
    eq("legacy_import.reload_failure.failure_message",
        printContains(reloadFailureEnv, "current StatsPro settings were preserved"), true)
    eq("legacy_import.reload_failure.no_success_message",
        printContains(reloadFailureEnv, "settings imported"), false)
end

do
    local combatEnv = loadStatsPro("enUS", {
        statsProDB = {},
        swiftStatsDB = { fontSize = 17 },
        inCombatLockdown = function() return true end,
    })
    fireEvent("legacy_import.combat.pew", combatEnv, "PLAYER_ENTERING_WORLD")
    clearPrints(combatEnv)
    slash("legacy_import.combat.request", combatEnv, "import")
    eq("legacy_import.combat.no_popup", combatEnv.__staticPopupShows, 0)
    eq("legacy_import.combat.message", printContains(combatEnv, "unavailable during combat"), true)
end

do
    local secretCrit = {}
    local pewEnv = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            showRating = false,
            showPercentage = true,
            hideZeroOffensive = false,
            showCrit = true,
            showHaste = false,
            showMastery = false,
            showVersatility = false,
            showTertiary = false,
            showDefensive = false,
        },
        getCritChance = function() return secretCrit end,
        getRangedCritChance = function() return nil end,
        getSpellCritChance = function() return nil end,
        issecretvalue = function(value) return value == secretCrit end,
    })
    local ok, err = pcall(pewEnv.__fireEvent, "PLAYER_ENTERING_WORLD")
    check("lifecycle.pew_initial_update_error_is_counted.no_bubble", ok, err)
    clearPrints(pewEnv)
    slash("lifecycle.pew_initial_update_error_is_counted.debug_perf", pewEnv, "debug perf")
    eq("lifecycle.pew_initial_update_error_is_counted.debug_reports_error",
        printContains(pewEnv, "updateErrors=1"), true)
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
    local combatClickEnv = loadStatsPro("enUS", {
        inCombatLockdown = function() return true end,
    })
    fireEvent("lifecycle.right_click_combat.fire", combatClickEnv, "PLAYER_ENTERING_WORLD")
    callScript("lifecycle.right_click_combat.main_panel", combatClickEnv.StatsProFrame, "OnMouseUp", "RightButton")
    eq("lifecycle.right_click_combat.config_not_opened", combatClickEnv.StatsProConfigFrame, nil)

    local combatTooltipEnv, _, combatTooltipTest = loadStatsPro("enUS", {
        inCombatLockdown = function() return true end,
        getCombatRatingBonusForCombatRatingValue = function(_, value)
            return value / 70
        end,
    })
    combatTooltipTest.renderMainPanelForSmoke("Mastery:", "812", "30.0%", 1, nil, nil, {
        { statKey = "crit", ratingCR = combatTooltipEnv.CR_CRIT_MELEE, target = 1043, current = 812, currentPct = 30.0, delta = -231, capturedAt = "2026-05-15" },
    })
    combatTooltipTest.fireMainPanelTooltipOverlayForSmoke(1, "OnMouseUp", "RightButton")
    eq("lifecycle.right_click_combat.tooltip_config_not_opened", combatTooltipEnv.StatsProConfigFrame, nil)
end

do
    local slashEnv = loadStatsPro("enUS")
    fireEvent("slash.pew", slashEnv, "PLAYER_ENTERING_WORLD")
    slash("slash.default_opens_config", slashEnv, "")
    exists("slash.default_opens_config.frame", slashEnv.StatsProConfigFrame)
    clearPrints(slashEnv)
    slash("slash.hide", slashEnv, "hide")
    eq("slash.hide.visible", slashEnv.StatsProDB.isVisible, false)
    eq("slash.hide.checkbox_synced", slashEnv.StatsProVisibleCheck:GetChecked(), false)
    eq("slash.hide.print", lastPrint(slashEnv), STATSPRO_PRINT_PREFIX .. "Stats panel hidden")
    clearPrints(slashEnv)
    slash("slash.show", slashEnv, "show")
    eq("slash.show.visible", slashEnv.StatsProDB.isVisible, true)
    eq("slash.show.print", lastPrint(slashEnv), STATSPRO_PRINT_PREFIX .. "Stats panel shown")
    clearPrints(slashEnv)
    slash("slash.toggle", slashEnv, "toggle")
    eq("slash.toggle.visible", slashEnv.StatsProDB.isVisible, false)
    eq("slash.toggle.print", lastPrint(slashEnv), STATSPRO_PRINT_PREFIX .. "Stats panel hidden")
    clearPrints(slashEnv)
    slash("slash.help", slashEnv, "help")
    eq("slash.help.print", lastPrint(slashEnv), STATSPRO_PRINT_PREFIX .. "Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /statspro import, /ss debug, /ss help")
    slashEnv.StatsProDB.fontBeforeAutoSwitch = "Fonts\\ARIALN.TTF"
    slashEnv.StatsProDB.useLocalizedLabels = false
    slashEnv.StatsProDB.panelBackgroundAlpha = 55
    slashEnv.StatsProDB.textOutlineStyle = "thick"
    slashEnv.StatsProDB.targetSnapshot = "raid"
    slashEnv.StatsProDB.colors.crit = { r = 0.4, g = 0.5, b = 0.6 }
    clearPrints(slashEnv)
    slash("slash.reset_restores_defaults", slashEnv, "reset")
    eq("slash.reset_restores_defaults.visible", slashEnv.StatsProDB.isVisible, true)
    eq("slash.reset_restores_defaults.panel_background_alpha", slashEnv.StatsProDB.panelBackgroundAlpha, 0)
    eq("slash.reset_restores_defaults.text_outline_style", slashEnv.StatsProDB.textOutlineStyle, "outline")
    eq("slash.reset_restores_defaults.target_snapshot", slashEnv.StatsProDB.targetSnapshot, "mythicPlus")
    eq("slash.reset_restores_defaults.transient_font", slashEnv.StatsProDB.fontBeforeAutoSwitch, nil)
    eq("slash.reset_restores_defaults.legacy_locale", slashEnv.StatsProDB.useLocalizedLabels, nil)
    eq("slash.reset_restores_defaults.print", lastPrint(slashEnv), STATSPRO_PRINT_PREFIX .. "Settings reset to defaults")
    assertColor("slash.reset_restores_defaults.crit", slashEnv.StatsProDB.colors.crit, 1, 0, 0)
end

do
    local slashEnv = loadStatsPro("enUS", {
        statsProDB = {
            forceLocale = "ruRU",
        },
    })
    fireEvent("slash.localized_ruRU.pew", slashEnv, "PLAYER_ENTERING_WORLD")
    clearPrints(slashEnv)
    slash("slash.localized_ruRU.hide", slashEnv, "hide")
    eq("slash.localized_ruRU.hide.print", lastPrint(slashEnv), STATSPRO_PRINT_PREFIX .. "Панель статов скрыта")
    clearPrints(slashEnv)
    slash("slash.localized_ruRU.show", slashEnv, "show")
    eq("slash.localized_ruRU.show.print", lastPrint(slashEnv), STATSPRO_PRINT_PREFIX .. "Панель статов показана")
    clearPrints(slashEnv)
    slash("slash.localized_ruRU.toggle", slashEnv, "toggle")
    eq("slash.localized_ruRU.toggle.print", lastPrint(slashEnv), STATSPRO_PRINT_PREFIX .. "Панель статов скрыта")
    clearPrints(slashEnv)
    slash("slash.localized_ruRU.help", slashEnv, "help")
    eq("slash.localized_ruRU.help.print", lastPrint(slashEnv), STATSPRO_PRINT_PREFIX .. "Команды: /ss или /statspro (настройки), /ss show, /ss hide, /ss toggle, /ss reset, /statspro import, /ss debug, /ss help")
    clearPrints(slashEnv)
    slash("slash.localized_ruRU.debug", slashEnv, "debug")
    eq("slash.localized_ruRU.debug_english", printContains(slashEnv, "debug v"), true)
    clearPrints(slashEnv)
    slash("slash.localized_ruRU.debug_perf", slashEnv, "debug perf")
    eq("slash.localized_ruRU.debug_perf_english", printContains(slashEnv, "debug perf:"), true)
    clearPrints(slashEnv)
    slash("slash.localized_ruRU.debug_rating", slashEnv, "debug rating")
    eq("slash.localized_ruRU.debug_rating_english", printContains(slashEnv, "debug rating"), true)
    clearPrints(slashEnv)
    slash("slash.localized_ruRU.debug_live", slashEnv, "debug live")
    eq("slash.localized_ruRU.debug_live_english", printContains(slashEnv, "debug live"), true)
    clearPrints(slashEnv)
    slash("slash.localized_ruRU.debug_bucket", slashEnv, "debug bucket")
    eq("slash.localized_ruRU.debug_bucket_english", printContains(slashEnv, "bucket:"), true)
    clearPrints(slashEnv)
    slash("slash.localized_ruRU.debug_routing", slashEnv, "debug routing")
    eq("slash.localized_ruRU.debug_routing_english", printContains(slashEnv, "debug routing:"), true)
    clearPrints(slashEnv)
    slash("slash.localized_ruRU.debug_labelstyle", slashEnv, "debug labelstyle")
    eq("slash.localized_ruRU.debug_labelstyle_english", printContains(slashEnv, "debug labelstyle:"), true)
    slashEnv.StatsProDB.forceLocale = "ruRU"
    slashEnv.StatsProDB.fontBeforeAutoSwitch = "Fonts\\ARIALN.TTF"
    slashEnv.StatsProDB.useLocalizedLabels = false
    clearPrints(slashEnv)
    slash("slash.localized_ruRU.reset", slashEnv, "reset")
    eq("slash.localized_ruRU.reset.force_locale", slashEnv.StatsProDB.forceLocale, "auto")
    eq("slash.localized_ruRU.reset.print", lastPrint(slashEnv), STATSPRO_PRINT_PREFIX .. "Настройки сброшены по умолчанию")
end

do
    local failures = test.collectRenderRoutingSmokeFailures()
    eq("routing.existing_invariants.count", #failures, 0)
end

do
    eq("selector.best_crit_exposed_on_addon", type(addon.GetBestCritChance), "function")
end

do
    local _, critAddon = loadStatsPro("enUS", {
        getCritChance = function() return 10 end,
        getRangedCritChance = function() return 15 end,
        getSpellCritChance = function() return 20 end,
    })
    local ok, value = pcall(critAddon.GetBestCritChance)
    check("selector.best_crit_uses_best_clean_source.no_error", ok, value)
    eq("selector.best_crit_uses_best_clean_source.value", value, 20)
end

do
    local bareSpellCalls = 0
    local _, critAddon = loadStatsPro("enUS", {
        getCritChance = function() return nil end,
        getRangedCritChance = function() return nil end,
        getSpellCritChance = function(school)
            if school == 2 then return nil end
            bareSpellCalls = bareSpellCalls + 1
            return 23.4
        end,
    })
    local ok, value = pcall(critAddon.GetBestCritChance)
    check("selector.best_crit_spell2_falls_back_to_unscoped_spell.no_error", ok, value)
    eq("selector.best_crit_spell2_falls_back_to_unscoped_spell.value", value, 23.4)
    eq("selector.best_crit_spell2_falls_back_to_unscoped_spell.calls", bareSpellCalls, 1)
end

do
    local _, critAddon = loadStatsPro("enUS", {
        getCritChance = function() return "bad" end,
        getRangedCritChance = function() return 17 end,
        getSpellCritChance = function() return nil end,
    })
    local ok, value = pcall(critAddon.GetBestCritChance)
    check("selector.best_crit_ignores_malformed_sources.no_error", ok, value)
    eq("selector.best_crit_ignores_malformed_sources.value", value, 17)
end

do
    local _, critAddon = loadStatsPro("enUS", {
        getCritChance = function() return nil end,
        getRangedCritChance = function() return "bad" end,
        getSpellCritChance = function() return nil end,
    })
    local ok, value = pcall(critAddon.GetBestCritChance)
    check("selector.best_crit_returns_nil_when_no_renderable_source.no_error", ok, value)
    eq("selector.best_crit_returns_nil_when_no_renderable_source.value", value, nil)
end

do
    local secretCrit = {}
    local _, critAddon = loadStatsPro("enUS", {
        getCritChance = function() return secretCrit end,
        getRangedCritChance = function() return 12 end,
        getSpellCritChance = function() return nil end,
        issecretvalue = function(value) return value == secretCrit end,
    })
    local ok, value = pcall(critAddon.GetBestCritChance)
    check("selector.best_crit_prefers_clean_value_over_secret.no_error", ok, value)
    eq("selector.best_crit_prefers_clean_value_over_secret.value", value, 12)
end

do
    local secretSpellCrit = 24.2
    local spell2Calls = 0
    local bareSpellCalls = 0
    local _, critAddon = loadStatsPro("enUS", {
        getCritChance = function() return 11 end,
        getRangedCritChance = function() return 18 end,
        getSpellCritChance = function(school)
            if school == 2 then
                spell2Calls = spell2Calls + 1
                return secretSpellCrit
            end
            bareSpellCalls = bareSpellCalls + 1
            error("bare spell fallback should not run after secret spell2")
        end,
        issecretvalue = function(value) return value == secretSpellCrit end,
    })
    local ok, value = pcall(critAddon.GetBestCritChance)
    check("selector.best_crit_secret_spell2_uses_clean_fallback.no_error", ok, value)
    eq("selector.best_crit_secret_spell2_uses_clean_fallback.spell2_seen", spell2Calls, 1)
    eq("selector.best_crit_secret_spell2_uses_clean_fallback.value", value, 18)
    eq("selector.best_crit_secret_spell2_uses_clean_fallback.no_bare_spell_call", bareSpellCalls, 0)
end

do
    local secretSpellCrit = 24.2
    local spell2Calls = 0
    local bareSpellCalls = 0
    local _, critAddon = loadStatsPro("enUS", {
        getCritChance = function() return nil end,
        getRangedCritChance = function() return nil end,
        getSpellCritChance = function(school)
            if school == 2 then
                spell2Calls = spell2Calls + 1
                return secretSpellCrit
            end
            bareSpellCalls = bareSpellCalls + 1
            return secretSpellCrit
        end,
        issecretvalue = function(value) return value == secretSpellCrit end,
    })
    local ok, value = pcall(critAddon.GetBestCritChance)
    check("selector.best_crit_secret_spell2_returns_secret.no_error", ok, value)
    eq("selector.best_crit_secret_spell2_returns_secret.spell2_seen", spell2Calls, 1)
    eq("selector.best_crit_secret_spell2_returns_secret.value", value, secretSpellCrit)
    eq("selector.best_crit_secret_spell2_returns_secret.no_bare_spell_call", bareSpellCalls, 0)
end

do
    local secretCrit = {}
    local _, critAddon = loadStatsPro("enUS", {
        getCritChance = function() return nil end,
        getRangedCritChance = function() return secretCrit end,
        getSpellCritChance = function() return nil end,
        issecretvalue = function(value) return value == secretCrit end,
    })
    local ok, value = pcall(critAddon.GetBestCritChance)
    check("selector.best_crit_returns_secret_when_only_secret_source_exists.no_error", ok, value)
    eq("selector.best_crit_returns_secret_when_only_secret_source_exists.value", value, secretCrit)
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
        getRangedCritChance = function() return nil end,
        getSpellCritChance = function() return nil end,
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
        getRangedCritChance = function() return "bad" end,
        getSpellCritChance = function() return "bad" end,
    })
    fireEvent("render.offensive_wrong_type_percent_skips_crit.fire", critEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.offensive_wrong_type_percent_skips_crit.no_error", ok, blocks)
    eq("render.offensive_wrong_type_percent_skips_crit.no_row", blockDumpContains(blocks, "Crit:"), false)
end

do
    local hasteEnv, _, hasteTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            hideZeroOffensive = false,
            showCrit = false,
            showHaste = true,
            showMastery = false,
            showVersatility = false,
            showTertiary = false,
            showDefensive = false,
        },
        getHaste = function() error("haste API unavailable") end,
    })
    fireEvent("render.offensive_api_error_skips_haste.fire", hasteEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(hasteTest.buildRenderBlocks)
    check("render.offensive_api_error_skips_haste.no_error", ok, blocks)
    eq("render.offensive_api_error_skips_haste.no_fake_zero_row", blockDumpContains(blocks, "Haste:"), false)
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
        getCritChance = function() error("crit API unavailable") end,
        getRangedCritChance = function() return nil end,
        getSpellCritChance = function() return nil end,
    })
    fireEvent("render.offensive_api_error_skips_crit.fire", critEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.offensive_api_error_skips_crit.no_error", ok, blocks)
    eq("render.offensive_api_error_skips_crit.no_fake_zero_row", blockDumpContains(blocks, "Crit:"), false)
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
        getCritChance = function() return 10 end,
        getRangedCritChance = function() return 15 end,
        getSpellCritChance = function() return 20 end,
    })
    fireEvent("render.crit_uses_best_clean_source.fire", critEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.crit_uses_best_clean_source.no_error", ok, blocks)
    eq("render.crit_uses_best_clean_source.row", blockDumpContains(blocks, "Crit:"), true)
    eq("render.crit_uses_best_clean_source.spell_value", blockDumpContains(blocks, "20.0%"), true)
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
        getRangedCritChance = function() return nil end,
        getSpellCritChance = function() return 23.4 end,
    })
    fireEvent("render.crit_falls_back_to_spell_source.fire", critEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.crit_falls_back_to_spell_source.no_error", ok, blocks)
    eq("render.crit_falls_back_to_spell_source.row", blockDumpContains(blocks, "Crit:"), true)
    eq("render.crit_falls_back_to_spell_source.spell_value", blockDumpContains(blocks, "23.4%"), true)
end

do
    local secretSpellCrit = 24.2
    local spell2Calls = 0
    local bareSpellCalls = 0
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
        getCritChance = function() return 11.1 end,
        getRangedCritChance = function() return 18.6 end,
        getSpellCritChance = function(school)
            if school == 2 then
                spell2Calls = spell2Calls + 1
                return secretSpellCrit
            end
            bareSpellCalls = bareSpellCalls + 1
            error("bare spell fallback should not run after secret spell2")
        end,
        issecretvalue = function(value) return value == secretSpellCrit end,
    })
    fireEvent("render.crit_spell_secret_uses_best_clean_fallback.fire", critEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.crit_spell_secret_uses_best_clean_fallback.no_error", ok, blocks)
    eq("render.crit_spell_secret_uses_best_clean_fallback.spell2_seen", spell2Calls > 0, true)
    eq("render.crit_spell_secret_uses_best_clean_fallback.no_bare_spell_call", bareSpellCalls, 0)
    eq("render.crit_spell_secret_uses_best_clean_fallback.row", blockDumpContains(blocks, "Crit:"), true)
    eq("render.crit_spell_secret_uses_best_clean_fallback.clean_fallback_value", blockDumpContains(blocks, "18.6%"), true)
end

do
    local secretSpellCrit = 24.2
    local spell2Calls = 0
    local bareSpellCalls = 0
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
        getRangedCritChance = function() return nil end,
        getSpellCritChance = function(school)
            if school == 2 then
                spell2Calls = spell2Calls + 1
                return secretSpellCrit
            end
            bareSpellCalls = bareSpellCalls + 1
            return secretSpellCrit
        end,
        issecretvalue = function(value) return value == secretSpellCrit end,
    })
    fireEvent("render.crit_spell_secret_only_keeps_row.fire", critEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.crit_spell_secret_only_keeps_row.no_error", ok, blocks)
    eq("render.crit_spell_secret_only_keeps_row.spell2_seen", spell2Calls > 0, true)
    eq("render.crit_spell_secret_only_keeps_row.no_bare_spell_call", bareSpellCalls, 0)
    eq("render.crit_spell_secret_only_keeps_row.row", blockDumpContains(blocks, "Crit:"), true)
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
    local critEnv, _, critTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            showRating = true,
            showPercentage = false,
            hideZeroOffensive = true,
            showCrit = true,
            showHaste = false,
            showMastery = false,
            showVersatility = false,
            showTertiary = false,
            showDefensive = false,
        },
        getCritChance = function() return nil end,
        getRangedCritChance = function() return nil end,
        getSpellCritChance = function() return nil end,
        getCombatRating = function() return 812 end,
    })
    fireEvent("render.offensive_rating_only_nil_percent_uses_clean_rating.fire", critEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.offensive_rating_only_nil_percent_uses_clean_rating.no_error", ok, blocks)
    eq("render.offensive_rating_only_nil_percent_uses_clean_rating.row", blockDumpContains(blocks, "Crit:"), true)
    eq("render.offensive_rating_only_nil_percent_uses_clean_rating.rating", blockDumpContains(blocks, "812"), true)
end

do
    local hasteEnv, _, hasteTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            showRating = true,
            showPercentage = false,
            hideZeroOffensive = true,
            showCrit = false,
            showHaste = true,
            showMastery = false,
            showVersatility = false,
            showTertiary = false,
            showDefensive = false,
        },
        getHaste = function() error("haste API unavailable") end,
        getCombatRating = function() return 733 end,
    })
    fireEvent("render.offensive_rating_only_error_percent_uses_clean_rating.fire", hasteEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(hasteTest.buildRenderBlocks)
    check("render.offensive_rating_only_error_percent_uses_clean_rating.no_error", ok, blocks)
    eq("render.offensive_rating_only_error_percent_uses_clean_rating.row", blockDumpContains(blocks, "Haste:"), true)
    eq("render.offensive_rating_only_error_percent_uses_clean_rating.rating", blockDumpContains(blocks, "733"), true)
end

do
    local critEnv, _, critTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            showRating = true,
            showPercentage = false,
            hideZeroOffensive = false,
            showCrit = true,
            showHaste = false,
            showMastery = false,
            showVersatility = false,
            showTertiary = false,
            showDefensive = false,
        },
        getCritChance = function() return nil end,
        getRangedCritChance = function() return nil end,
        getSpellCritChance = function() return nil end,
        getCombatRating = function() return nil end,
    })
    fireEvent("render.offensive_rating_only_nil_rating_stays_hidden.fire", critEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.offensive_rating_only_nil_rating_stays_hidden.no_error", ok, blocks)
    eq("render.offensive_rating_only_nil_rating_stays_hidden.no_row", blockDumpContains(blocks, "Crit:"), false)
end

do
    local percentValue
    local ratingValue = 812
    local secretRating = 777
    local critEnv, _, critTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            showRating = true,
            showPercentage = false,
            hideZeroOffensive = true,
            showCrit = true,
            showHaste = false,
            showMastery = false,
            showVersatility = false,
            showTertiary = false,
            showDefensive = false,
        },
        getCritChance = function() return percentValue end,
        getRangedCritChance = function() return nil end,
        getSpellCritChance = function() return nil end,
        getCombatRating = function() return ratingValue end,
        issecretvalue = function(value) return value == secretRating end,
    })
    fireEvent("render.offensive_rating_only_refreshes_rating_visibility_cache.fire", critEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.offensive_rating_only_refreshes_rating_visibility_cache.positive_no_error", ok, blocks)
    eq("render.offensive_rating_only_refreshes_rating_visibility_cache.positive_row", blockDumpContains(blocks, "Crit:"), true)
    percentValue = 12.5
    ratingValue = 0
    ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.offensive_rating_only_refreshes_rating_visibility_cache.zero_no_error", ok, blocks)
    eq("render.offensive_rating_only_refreshes_rating_visibility_cache.percent_keeps_row", blockDumpContains(blocks, "Crit:"), true)
    percentValue = nil
    ratingValue = secretRating
    ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.offensive_rating_only_refreshes_rating_visibility_cache.secret_no_error", ok, blocks)
    eq("render.offensive_rating_only_refreshes_rating_visibility_cache.secret_no_row", blockDumpContains(blocks, "Crit:"), false)
end

do
    local targetFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(targetFixture, "mythicPlus", "MAGE", "frost",
        { crit = 1000, haste = 200, mastery = 300, versatility = 400 })
    local critEnv, _, critTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        statsProDB = {
            showOffensive = true,
            showRating = true,
            showPercentage = false,
            hideZeroOffensive = true,
            showCrit = true,
            showHaste = false,
            showMastery = false,
            showVersatility = false,
            showTertiary = false,
            showDefensive = false,
        },
        statsProArchonTargets = targetFixture,
        getCritChance = function() return nil end,
        getRangedCritChance = function() return nil end,
        getSpellCritChance = function() return nil end,
        getCombatRating = function() return 812 end,
    })
    fireEvent("render.offensive_rating_only_builds_target_meta_without_pct.fire", critEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.offensive_rating_only_builds_target_meta_without_pct.no_error", ok, blocks)
    local meta = findTargetMeta(blocks, "crit")
    check("render.offensive_rating_only_builds_target_meta_without_pct.meta", type(meta) == "table", meta)
    if type(meta) == "table" then
        eq("render.offensive_rating_only_builds_target_meta_without_pct.current", meta.current, 812)
        eq("render.offensive_rating_only_builds_target_meta_without_pct.current_pct", meta.currentPct, nil)
        eq("render.offensive_rating_only_builds_target_meta_without_pct.target", meta.target, 1000)
    end
end

do
    local targetFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(targetFixture, "mythicPlus", "MAGE", "frost",
        { crit = 1000, haste = 200, mastery = 300, versatility = 400 })
    local critEnv, _, critTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        statsProDB = {
            showOffensive = true,
            showRating = true,
            showPercentage = true,
            hideZeroOffensive = true,
            showCrit = true,
            showHaste = false,
            showMastery = false,
            showVersatility = false,
            showTertiary = false,
            showDefensive = false,
        },
        statsProArchonTargets = targetFixture,
        getCritChance = function() return nil end,
        getRangedCritChance = function() return nil end,
        getSpellCritChance = function() return nil end,
        getCombatRating = function() return 812 end,
    })
    fireEvent("render.offensive_dual_nil_percent_uses_clean_rating_and_meta.fire", critEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.offensive_dual_nil_percent_uses_clean_rating_and_meta.no_error", ok, blocks)
    local offensive = blocks[2]
    eq("render.offensive_dual_nil_percent_uses_clean_rating_and_meta.block", offensive.splitKey, "splitOffensive")
    eq("render.offensive_dual_nil_percent_uses_clean_rating_and_meta.row_count", #(offensive.labels or {}), 1)
    eq("render.offensive_dual_nil_percent_uses_clean_rating_and_meta.label",
        offensive.labels[1]:find("Crit:", 1, true) ~= nil, true)
    eq("render.offensive_dual_nil_percent_uses_clean_rating_and_meta.rating",
        offensive.ratings[1]:find("812", 1, true) ~= nil, true)
    eq("render.offensive_dual_nil_percent_uses_clean_rating_and_meta.no_fake_percent",
        offensive.values[1], "")
    local meta = offensive.targetRows[1]
    check("render.offensive_dual_nil_percent_uses_clean_rating_and_meta.meta", type(meta) == "table", meta)
    eq("render.offensive_dual_nil_percent_uses_clean_rating_and_meta.current", meta.current, 812)
    eq("render.offensive_dual_nil_percent_uses_clean_rating_and_meta.current_pct", meta.currentPct, nil)
    eq("render.offensive_dual_nil_percent_uses_clean_rating_and_meta.target", meta.target, 1000)
end

do
    local hasteEnv, _, hasteTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            showRating = true,
            showPercentage = true,
            hideZeroOffensive = true,
            showCrit = false,
            showHaste = true,
            showMastery = false,
            showVersatility = false,
            showTertiary = false,
            showDefensive = false,
        },
        getHaste = function() error("haste API unavailable") end,
        getCombatRating = function() return 733 end,
    })
    fireEvent("render.offensive_dual_error_percent_uses_clean_rating.fire", hasteEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(hasteTest.buildRenderBlocks)
    check("render.offensive_dual_error_percent_uses_clean_rating.no_error", ok, blocks)
    local offensive = blocks[2]
    eq("render.offensive_dual_error_percent_uses_clean_rating.row_count", #(offensive.labels or {}), 1)
    eq("render.offensive_dual_error_percent_uses_clean_rating.label",
        offensive.labels[1]:find("Haste:", 1, true) ~= nil, true)
    eq("render.offensive_dual_error_percent_uses_clean_rating.rating",
        offensive.ratings[1]:find("733", 1, true) ~= nil, true)
    eq("render.offensive_dual_error_percent_uses_clean_rating.no_fake_percent",
        offensive.values[1], "")
    eq("render.offensive_dual_error_percent_uses_clean_rating.no_target_meta",
        offensive.targetRows[1], false)
end

do
    local secretCritPercent = 18.4
    local targetFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(targetFixture, "mythicPlus", "MAGE", "frost",
        { crit = 1000, haste = 200, mastery = 300, versatility = 400 })
    local critEnv, _, critTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        statsProDB = {
            showOffensive = true,
            showRating = true,
            showPercentage = true,
            hideZeroOffensive = true,
            showCrit = true,
            showHaste = false,
            showMastery = false,
            showVersatility = false,
            showTertiary = false,
            showDefensive = false,
        },
        statsProArchonTargets = targetFixture,
        getCritChance = function() return secretCritPercent end,
        getRangedCritChance = function() return nil end,
        getSpellCritChance = function() return nil end,
        getCombatRating = function() return 812 end,
        issecretvalue = function(value) return value == secretCritPercent end,
    })
    fireEvent("render.target_meta_secret_percent_uses_clean_rating_without_current_pct.fire", critEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.target_meta_secret_percent_uses_clean_rating_without_current_pct.no_error", ok, blocks)
    local offensive = blocks[2]
    eq("render.target_meta_secret_percent_uses_clean_rating_without_current_pct.row_count", #(offensive.labels or {}), 1)
    eq("render.target_meta_secret_percent_uses_clean_rating_without_current_pct.rating",
        offensive.ratings[1]:find("812", 1, true) ~= nil, true)
    local meta = offensive.targetRows[1]
    check("render.target_meta_secret_percent_uses_clean_rating_without_current_pct.meta", type(meta) == "table", meta)
    eq("render.target_meta_secret_percent_uses_clean_rating_without_current_pct.current", meta.current, 812)
    eq("render.target_meta_secret_percent_uses_clean_rating_without_current_pct.current_pct", meta.currentPct, nil)
    eq("render.target_meta_secret_percent_uses_clean_rating_without_current_pct.target", meta.target, 1000)
end

do
    local ratingCalls = 0
    local targetHoverFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(targetHoverFixture, "mythicPlus", "MAGE", "frost",
        { crit = 1000, haste = 200, mastery = 300, versatility = 400 })
    local critEnv, _, critTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        statsProDB = {
            showOffensive = true,
            showRating = false,
            showPercentage = true,
            showCrit = true,
            showHaste = false,
            showMastery = false,
            showVersatility = false,
            showTertiary = false,
            showDefensive = false,
        },
        statsProArchonTargets = targetHoverFixture,
        getCritChance = function() return 12.5 end,
        getCombatRating = function()
            ratingCalls = ratingCalls + 1
            error("rating API tainted")
        end,
    })
    fireEvent("render.target_hover_rating_error.fire", critEnv, "PLAYER_ENTERING_WORLD")
    ratingCalls = 0
    local ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.target_hover_rating_error.no_error", ok, blocks)
    eq("render.target_hover_rating_error.row_still_visible", blockDumpContains(blocks, "Crit:"), true)
    eq("render.target_hover_rating_error.no_false_current_zero_meta", blocks[2].targetRows[1], false)
    eq("render.target_hover_rating_error.no_second_percent_only_rating_read", ratingCalls, 1)
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
    local leechEnv, _, leechTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showTertiary = true,
            showRating = true,
            showPercentage = false,
            hideZeroTertiary = true,
            showLeech = true,
            showAvoidance = false,
            showSpeed = false,
            showDefensive = false,
        },
        getLifesteal = function() return nil end,
        getCombatRating = function() return 421 end,
    })
    fireEvent("render.tertiary_rating_only_nil_percent_uses_clean_rating.fire", leechEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(leechTest.buildRenderBlocks)
    check("render.tertiary_rating_only_nil_percent_uses_clean_rating.no_error", ok, blocks)
    eq("render.tertiary_rating_only_nil_percent_uses_clean_rating.row", blockDumpContains(blocks, "Leech:"), true)
    eq("render.tertiary_rating_only_nil_percent_uses_clean_rating.rating", blockDumpContains(blocks, "421"), true)
end

do
    local leechEnv, _, leechTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showTertiary = true,
            showRating = true,
            showPercentage = true,
            hideZeroTertiary = true,
            showLeech = true,
            showAvoidance = false,
            showSpeed = false,
            showDefensive = false,
        },
        getLifesteal = function() return nil end,
        getCombatRating = function() return 421 end,
    })
    fireEvent("render.tertiary_dual_nil_percent_uses_clean_rating.fire", leechEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(leechTest.buildRenderBlocks)
    check("render.tertiary_dual_nil_percent_uses_clean_rating.no_error", ok, blocks)
    local tertiary = blocks[3]
    eq("render.tertiary_dual_nil_percent_uses_clean_rating.block", tertiary.splitKey, "splitTertiary")
    eq("render.tertiary_dual_nil_percent_uses_clean_rating.row_count", #(tertiary.labels or {}), 1)
    eq("render.tertiary_dual_nil_percent_uses_clean_rating.label",
        tertiary.labels[1]:find("Leech:", 1, true) ~= nil, true)
    eq("render.tertiary_dual_nil_percent_uses_clean_rating.rating",
        tertiary.ratings[1]:find("421", 1, true) ~= nil, true)
    eq("render.tertiary_dual_nil_percent_uses_clean_rating.no_fake_percent",
        tertiary.values[1], "")
end

do
    local avoidanceEnv, _, avoidanceTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showTertiary = true,
            showRating = true,
            showPercentage = true,
            hideZeroTertiary = true,
            showLeech = false,
            showAvoidance = true,
            showSpeed = false,
            showDefensive = false,
        },
        getAvoidance = function() error("avoidance API unavailable") end,
        getCombatRating = function() return 318 end,
    })
    fireEvent("render.tertiary_dual_error_percent_uses_clean_rating.fire", avoidanceEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(avoidanceTest.buildRenderBlocks)
    check("render.tertiary_dual_error_percent_uses_clean_rating.no_error", ok, blocks)
    local tertiary = blocks[3]
    eq("render.tertiary_dual_error_percent_uses_clean_rating.row_count", #(tertiary.labels or {}), 1)
    eq("render.tertiary_dual_error_percent_uses_clean_rating.label",
        tertiary.labels[1]:find("Avoidance:", 1, true) ~= nil, true)
    eq("render.tertiary_dual_error_percent_uses_clean_rating.rating",
        tertiary.ratings[1]:find("318", 1, true) ~= nil, true)
    eq("render.tertiary_dual_error_percent_uses_clean_rating.no_fake_percent",
        tertiary.values[1], "")
end

do
    local leechEnv, _, leechTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showTertiary = true,
            showRating = true,
            showPercentage = false,
            hideZeroTertiary = false,
            showLeech = true,
            showAvoidance = false,
            showSpeed = false,
            showDefensive = false,
        },
        getLifesteal = function() return nil end,
        getCombatRating = function() return nil end,
    })
    fireEvent("render.tertiary_rating_only_nil_rating_stays_hidden.fire", leechEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(leechTest.buildRenderBlocks)
    check("render.tertiary_rating_only_nil_rating_stays_hidden.no_error", ok, blocks)
    eq("render.tertiary_rating_only_nil_rating_stays_hidden.no_row", blockDumpContains(blocks, "Leech:"), false)
end

do
    local leechValue = 0
    local secretMode = false
    local leechEnv, _, leechTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showTertiary = true,
            hideZeroTertiary = true,
            showLeech = true,
            showAvoidance = false,
            showSpeed = false,
            showDefensive = false,
        },
        getLifesteal = function() return leechValue end,
        issecretvalue = function(value) return secretMode and value == leechValue end,
    })
    fireEvent("render.hide_zero_secret_preserves_hidden_zero.fire", leechEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(leechTest.buildRenderBlocks)
    check("render.hide_zero_secret_preserves_hidden_zero.clean_no_error", ok, blocks)
    eq("render.hide_zero_secret_preserves_hidden_zero.clean_no_row", blockDumpContains(blocks, "Leech:"), false)
    secretMode = true
    ok, blocks = pcall(leechTest.buildRenderBlocks)
    check("render.hide_zero_secret_preserves_hidden_zero.secret_no_error", ok, blocks)
    eq("render.hide_zero_secret_preserves_hidden_zero.secret_no_row", blockDumpContains(blocks, "Leech:"), false)
end

do
    local leechValue = 4
    local secretMode = false
    local leechEnv, _, leechTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showTertiary = true,
            hideZeroTertiary = true,
            showLeech = true,
            showAvoidance = false,
            showSpeed = false,
            showDefensive = false,
        },
        getLifesteal = function() return leechValue end,
        issecretvalue = function(value) return secretMode and value == leechValue end,
    })
    fireEvent("render.hide_zero_secret_preserves_visible_nonzero.fire", leechEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(leechTest.buildRenderBlocks)
    check("render.hide_zero_secret_preserves_visible_nonzero.clean_no_error", ok, blocks)
    eq("render.hide_zero_secret_preserves_visible_nonzero.clean_row", blockDumpContains(blocks, "Leech:"), true)
    leechValue = 0
    secretMode = true
    ok, blocks = pcall(leechTest.buildRenderBlocks)
    check("render.hide_zero_secret_preserves_visible_nonzero.secret_no_error", ok, blocks)
    eq("render.hide_zero_secret_preserves_visible_nonzero.secret_row", blockDumpContains(blocks, "Leech:"), true)
end

do
    local secretCrit = {}
    local secretMode = false
    local updateEnv = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            showRating = false,
            showPercentage = true,
            showCrit = true,
            showHaste = false,
            showMastery = false,
            showVersatility = false,
            showTertiary = false,
            showDefensive = false,
        },
        getCritChance = function()
            if secretMode then return secretCrit end
            return 10
        end,
        getRangedCritChance = function() return nil end,
        getSpellCritChance = function() return nil end,
        issecretvalue = function(value) return value == secretCrit end,
    })
    fireEvent("render.update_ticker_survives_stat_error.fire", updateEnv, "PLAYER_ENTERING_WORLD")
    local ticker
    for _, frame in ipairs(updateEnv.__frames) do
        if frame.scripts and type(frame.scripts.OnUpdate) == "function" then
            ticker = frame
            break
        end
    end
    exists("render.update_ticker_survives_stat_error.ticker", ticker)
    secretMode = true
    local ok, err = pcall(ticker.scripts.OnUpdate, ticker, 999)
    check("render.update_ticker_survives_stat_error.no_bubble", ok, err)
    clearPrints(updateEnv)
    slash("render.update_ticker_survives_stat_error.debug_perf", updateEnv, "debug perf")
    eq("render.update_ticker_survives_stat_error.debug_reports_error", printContains(updateEnv, "updateErrors=1"), true)
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
    local armorEnv, _, armorTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showDefensive = true,
            hideZeroDefensive = false,
            showDodge = false,
            showParry = false,
            showBlock = false,
            showArmor = true,
            showStagger = false,
        },
        inCombatLockdown = function() return true end,
        unitArmor = function() error("cold combat should not call UnitArmor") end,
    })
    fireEvent("defensive.armor_cold_combat_stays_unknown.fire", armorEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(armorTest.buildRenderBlocks)
    check("defensive.armor_cold_combat_stays_unknown.no_error", ok, blocks)
    eq("defensive.armor_cold_combat_stays_unknown.no_fake_zero",
        blockDumpContains(blocks, "Armor:"), false)
end

do
    local secretReduction = {}
    local armorEnv, _, armorTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showDefensive = true,
            hideZeroDefensive = false,
            showDodge = false,
            showParry = false,
            showBlock = false,
            showArmor = true,
            showStagger = false,
        },
        unitArmor = function() return 0, 5000 end,
        unitEffectiveLevel = function() return 80 end,
        getArmorEffectiveness = function() return secretReduction end,
        paperDollFrameGetArmorReduction = function()
            error("documented armor API should be preferred")
        end,
        issecretvalue = function(value) return value == secretReduction end,
    })
    fireEvent("defensive.armor_cold_secret_reduction_stays_unknown.fire", armorEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(armorTest.buildRenderBlocks)
    check("defensive.armor_cold_secret_reduction_stays_unknown.no_error", ok, blocks)
    eq("defensive.armor_cold_secret_reduction_stays_unknown.no_fake_zero",
        blockDumpContains(blocks, "Armor:"), false)
end

do
    local armorEnv, _, armorTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showDefensive = true,
            hideZeroDefensive = false,
            showDodge = false,
            showParry = false,
            showBlock = false,
            showArmor = true,
            showStagger = false,
        },
        unitArmor = function() return 0, 5000 end,
        unitEffectiveLevel = function() return 80 end,
        getArmorEffectiveness = function(armor, attackerLevel)
            eq("defensive.armor_documented_effectiveness.args.armor", armor, 5000)
            eq("defensive.armor_documented_effectiveness.args.level", attackerLevel, 80)
            return 0.345
        end,
        paperDollFrameGetArmorReduction = false,
    })
    fireEvent("defensive.armor_documented_effectiveness_renders.fire", armorEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(armorTest.buildRenderBlocks)
    check("defensive.armor_documented_effectiveness_renders.no_error", ok, blocks)
    eq("defensive.armor_documented_effectiveness_renders.row", blockDumpContains(blocks, "Armor:"), true)
    eq("defensive.armor_documented_effectiveness_renders.value", blockDumpContains(blocks, "34.5%"), true)
end

do
    local armorEnv, _, armorTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showDefensive = true,
            hideZeroDefensive = false,
            showDodge = false,
            showParry = false,
            showBlock = false,
            showArmor = true,
            showStagger = false,
        },
        unitArmor = function() return 0, 5000 end,
        unitEffectiveLevel = function() return 80 end,
        paperDollFrameGetArmorReduction = function() return 1 end,
    })
    fireEvent("defensive.armor_fallback_percent_renders.fire", armorEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(armorTest.buildRenderBlocks)
    check("defensive.armor_fallback_percent_renders.no_error", ok, blocks)
    eq("defensive.armor_fallback_percent_renders.value", blockDumpContains(blocks, "1.0%"), true)
end

do
    local armorEnv, _, armorTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showDefensive = true,
            hideZeroDefensive = false,
            showDodge = false,
            showParry = false,
            showBlock = false,
            showArmor = true,
            showStagger = false,
        },
        unitArmor = function() return 0, 5000 end,
        unitEffectiveLevel = function() return 80 end,
        paperDollFrameGetArmorReduction = false,
    })
    fireEvent("defensive.armor_missing_providers_stays_unknown.fire", armorEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(armorTest.buildRenderBlocks)
    check("defensive.armor_missing_providers_stays_unknown.no_error", ok, blocks)
    eq("defensive.armor_missing_providers_stays_unknown.no_row",
        blockDumpContains(blocks, "Armor:"), false)
end

do
    local calls = { armor = 0, level = 0, documented = 0, fallback = 0 }
    local armorEnv, armorAddon, armorTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            showDefensive = false,
            showArmor = true,
        },
        unitArmor = function()
            calls.armor = calls.armor + 1
            return 0, 5000
        end,
        unitEffectiveLevel = function()
            calls.level = calls.level + 1
            return 80
        end,
        getArmorEffectiveness = function()
            calls.documented = calls.documented + 1
            return 0.25
        end,
        paperDollFrameGetArmorReduction = function()
            calls.fallback = calls.fallback + 1
            return 25
        end,
    })
    fireEvent("defensive.armor_master_off_skips_apis.fire", armorEnv, "PLAYER_ENTERING_WORLD")
    check("defensive.armor_master_off_skips_apis.second_update", armorAddon:RunUpdateStatsSafe())
    eq("defensive.armor_master_off_skips_apis.armor", calls.armor, 0)
    eq("defensive.armor_master_off_skips_apis.level", calls.level, 0)
    eq("defensive.armor_master_off_skips_apis.documented", calls.documented, 0)
    eq("defensive.armor_master_off_skips_apis.fallback", calls.fallback, 0)
    local ok, blocks = pcall(armorTest.buildRenderBlocks)
    check("defensive.armor_master_off_skips_apis.no_error", ok, blocks)
    eq("defensive.armor_master_off_skips_apis.no_row", blockDumpContains(blocks, "Armor:"), false)
    armorEnv.StatsProDB.showDefensive = true
    armorTest.cacheSettings()
    check("defensive.armor_master_reenable_refreshes.update", armorAddon:RunUpdateStatsSafe())
    eq("defensive.armor_master_reenable_refreshes.armor", calls.armor, 1)
    eq("defensive.armor_master_reenable_refreshes.level", calls.level, 1)
    eq("defensive.armor_master_reenable_refreshes.documented", calls.documented, 1)
    eq("defensive.armor_master_reenable_refreshes.fallback", calls.fallback, 0)
    blocks = armorTest.buildRenderBlocks()
    eq("defensive.armor_master_reenable_refreshes.value", blockDumpContains(blocks, "25.0%"), true)
end

do
    local armorEnv, _, armorTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showDefensive = true,
            hideZeroDefensive = false,
            showDodge = false,
            showParry = false,
            showBlock = false,
            showArmor = true,
            showStagger = false,
        },
        unitArmor = function() return 0, 5000 end,
        unitEffectiveLevel = function() return 80 end,
        paperDollFrameGetArmorReduction = function() return 150 end,
    })
    fireEvent("defensive.armor_large_reduction_clamps_to_100.fire", armorEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(armorTest.buildRenderBlocks)
    check("defensive.armor_large_reduction_clamps_to_100.no_error", ok, blocks)
    eq("defensive.armor_large_reduction_clamps_to_100.value", blockDumpContains(blocks, "100.0%"), true)
end

do
    local armorEnv, _, armorTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showDefensive = true,
            hideZeroDefensive = false,
            showDodge = false,
            showParry = false,
            showBlock = false,
            showArmor = true,
            showStagger = false,
        },
        unitArmor = function() return 0, 5000 end,
        unitEffectiveLevel = function() return 80 end,
        paperDollFrameGetArmorReduction = function() return -5 end,
    })
    fireEvent("defensive.armor_negative_reduction_clamps_to_zero.fire", armorEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(armorTest.buildRenderBlocks)
    check("defensive.armor_negative_reduction_clamps_to_zero.no_error", ok, blocks)
    eq("defensive.armor_negative_reduction_clamps_to_zero.value", blockDumpContains(blocks, "0.0%"), true)
end

do
    local secretArmor = {}
    local secretMode = false
    local armorEnv, _, armorTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showDefensive = true,
            hideZeroDefensive = false,
            showDodge = false,
            showParry = false,
            showBlock = false,
            showArmor = true,
            showStagger = false,
        },
        unitArmor = function()
            if secretMode then return 0, secretArmor end
            return 0, 5000
        end,
        unitEffectiveLevel = function() return 80 end,
        paperDollFrameGetArmorReduction = function()
            if secretMode then error("secret effective armor should stop before reduction") end
            return 25
        end,
        issecretvalue = function(value) return value == secretArmor end,
    })
    fireEvent("defensive.armor_secret_effective_preserves_last_clean.clean_fire", armorEnv, "PLAYER_ENTERING_WORLD")
    secretMode = true
    fireEvent("defensive.armor_secret_effective_preserves_last_clean.secret_fire", armorEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(armorTest.buildRenderBlocks)
    check("defensive.armor_secret_effective_preserves_last_clean.no_error", ok, blocks)
    eq("defensive.armor_secret_effective_preserves_last_clean.value", blockDumpContains(blocks, "25.0%"), true)
end

do
    local secretReduction = {}
    local reductionMode = "clean"
    local fallbackCalls = 0
    local armorEnv, _, armorTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showDefensive = true,
            hideZeroDefensive = false,
            showDodge = false,
            showParry = false,
            showBlock = false,
            showArmor = true,
            showStagger = false,
        },
        unitArmor = function() return 0, 5000 end,
        unitEffectiveLevel = function() return 80 end,
        getArmorEffectiveness = function()
            if reductionMode == "secret" then return secretReduction end
            if reductionMode == "error" then error("documented armor API failed") end
            return 0.25
        end,
        paperDollFrameGetArmorReduction = function()
            fallbackCalls = fallbackCalls + 1
            return 99
        end,
        issecretvalue = function(value) return value == secretReduction end,
    })
    fireEvent("defensive.armor_secret_reduction_preserves_last_clean.clean_fire", armorEnv, "PLAYER_ENTERING_WORLD")
    reductionMode = "secret"
    fireEvent("defensive.armor_secret_reduction_preserves_last_clean.secret_fire", armorEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(armorTest.buildRenderBlocks)
    check("defensive.armor_secret_reduction_preserves_last_clean.no_error", ok, blocks)
    eq("defensive.armor_secret_reduction_preserves_last_clean.value", blockDumpContains(blocks, "25.0%"), true)
    eq("defensive.armor_secret_reduction_skips_fallback", fallbackCalls, 0)
    reductionMode = "error"
    fireEvent("defensive.armor_error_reduction_preserves_last_clean.error_fire", armorEnv, "PLAYER_ENTERING_WORLD")
    ok, blocks = pcall(armorTest.buildRenderBlocks)
    check("defensive.armor_error_reduction_preserves_last_clean.no_error", ok, blocks)
    eq("defensive.armor_error_reduction_preserves_last_clean.value", blockDumpContains(blocks, "25.0%"), true)
    eq("defensive.armor_error_reduction_skips_fallback", fallbackCalls, 0)
end

do
    local badLevel = false
    local armorEnv, _, armorTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showDefensive = true,
            hideZeroDefensive = false,
            showDodge = false,
            showParry = false,
            showBlock = false,
            showArmor = true,
            showStagger = false,
        },
        unitArmor = function() return 0, 5000 end,
        unitEffectiveLevel = function()
            if badLevel then return "bad-level" end
            return 80
        end,
        paperDollFrameGetArmorReduction = function()
            if badLevel then error("bad level should stop before reduction") end
            return 25
        end,
    })
    fireEvent("defensive.armor_bad_level_preserves_last_clean.clean_fire", armorEnv, "PLAYER_ENTERING_WORLD")
    badLevel = true
    fireEvent("defensive.armor_bad_level_preserves_last_clean.bad_fire", armorEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(armorTest.buildRenderBlocks)
    check("defensive.armor_bad_level_preserves_last_clean.no_error", ok, blocks)
    eq("defensive.armor_bad_level_preserves_last_clean.value", blockDumpContains(blocks, "25.0%"), true)
end

do
    local inCombat = false
    local armorEnv, _, armorTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showDefensive = true,
            hideZeroDefensive = false,
            showDodge = false,
            showParry = false,
            showBlock = false,
            showArmor = true,
            showStagger = false,
        },
        inCombatLockdown = function() return inCombat end,
        unitArmor = function()
            if inCombat then error("combat should stop before UnitArmor") end
            return 0, 5000
        end,
        unitEffectiveLevel = function() return 80 end,
        paperDollFrameGetArmorReduction = function() return 25 end,
    })
    fireEvent("defensive.armor_in_combat_preserves_last_clean.clean_fire", armorEnv, "PLAYER_ENTERING_WORLD")
    inCombat = true
    fireEvent("defensive.armor_in_combat_preserves_last_clean.combat_fire", armorEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(armorTest.buildRenderBlocks)
    check("defensive.armor_in_combat_preserves_last_clean.no_error", ok, blocks)
    eq("defensive.armor_in_combat_preserves_last_clean.value", blockDumpContains(blocks, "25.0%"), true)
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
    local versEnv, _, versTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            hideZeroOffensive = false,
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
    fireEvent("render.versatility_cold_unknown_not_zero.fire", versEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_cold_unknown_not_zero.no_error", ok, blocks)
    eq("render.versatility_cold_unknown_not_zero.no_row", blockDumpContains(blocks, "Vers:"), false)
end

do
    local secretMode = false
    local secretVersRatingBonus = 14.7
    local versEnv, _, versTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            showRating = false,
            showPercentage = true,
            hideZeroOffensive = false,
            showCrit = false,
            showHaste = false,
            showMastery = false,
            showVersatility = true,
            showTertiary = false,
            showDefensive = false,
        },
        getCombatRatingBonus = function()
            if secretMode then return secretVersRatingBonus end
            return 10
        end,
        getVersatilityBonus = function()
            if secretMode then return 0 end
            return 2
        end,
        issecretvalue = function(value) return secretMode and value == secretVersRatingBonus end,
    })
    fireEvent("render.versatility_secret_bonus_uses_live_renderable.fire", versEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_secret_bonus_uses_live_renderable.clean_no_error", ok, blocks)
    eq("render.versatility_secret_bonus_uses_live_renderable.clean_total", blockDumpContains(blocks, "12.0%"), true)
    secretMode = true
    ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_secret_bonus_uses_live_renderable.secret_no_error", ok, blocks)
    eq("render.versatility_secret_bonus_uses_live_renderable.secret_live_value", blockDumpContains(blocks, "14.7%"), true)
end

do
    local ratingBonus = 10
    local flatBonus = 2
    local secretRating = false
    local secretFlat = false
    local targetFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(targetFixture, "mythicPlus", "MAGE", "frost",
        { crit = 100, haste = 200, mastery = 300, versatility = 1000 })
    local versEnv, _, versTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        statsProDB = {
            showOffensive = true,
            showRating = false,
            showPercentage = true,
            hideZeroOffensive = false,
            showCrit = false,
            showHaste = false,
            showMastery = false,
            showVersatility = true,
            showTertiary = false,
            showDefensive = false,
        },
        statsProArchonTargets = targetFixture,
        getCombatRatingBonus = function() return ratingBonus end,
        getVersatilityBonus = function() return flatBonus end,
        getCombatRating = function() return 700 end,
        issecretvalue = function(value)
            return (secretRating and value == ratingBonus) or (secretFlat and value == flatBonus)
        end,
    })
    fireEvent("render.versatility_partial_secret_preserves_last_full_total.fire", versEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_partial_secret_preserves_last_full_total.clean_no_error", ok, blocks)
    eq("render.versatility_partial_secret_preserves_last_full_total.clean_total",
        blockDumpContains(blocks, "12.0%"), true)
    eq("render.versatility_partial_secret_preserves_last_full_total.clean_cache",
        versTest.versatilityState().total, 12)
    eq("render.versatility_partial_secret_preserves_last_full_total.clean_meta_pct",
        blocks[2].targetRows[1].currentPct, 12)

    ratingBonus = 14.7
    flatBonus = 3.3
    secretRating = true
    ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_partial_secret_preserves_last_full_total.mixed_no_error", ok, blocks)
    eq("render.versatility_partial_secret_preserves_last_full_total.mixed_last_full",
        blockDumpContains(blocks, "12.0%"), true)
    eq("render.versatility_partial_secret_preserves_last_full_total.mixed_no_partial_rating",
        blockDumpContains(blocks, "14.7%"), false)
    eq("render.versatility_partial_secret_preserves_last_full_total.mixed_cache_unchanged",
        versTest.versatilityState().total, 12)
    eq("render.versatility_partial_secret_preserves_last_full_total.mixed_meta_pct_unknown",
        blocks[2].targetRows[1].currentPct, nil)

    secretFlat = true
    ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_partial_secret_preserves_last_full_total.both_secret_no_error", ok, blocks)
    eq("render.versatility_partial_secret_preserves_last_full_total.both_secret_last_full",
        blockDumpContains(blocks, "12.0%"), true)
    eq("render.versatility_partial_secret_preserves_last_full_total.both_secret_cache_unchanged",
        versTest.versatilityState().total, 12)

    secretRating = false
    ratingBonus = 10
    ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_partial_secret_preserves_last_full_total.flat_secret_no_error", ok, blocks)
    eq("render.versatility_partial_secret_preserves_last_full_total.flat_secret_last_full",
        blockDumpContains(blocks, "12.0%"), true)
    eq("render.versatility_partial_secret_preserves_last_full_total.flat_secret_no_partial",
        blockDumpContains(blocks, "3.3%"), false)
    eq("render.versatility_partial_secret_preserves_last_full_total.flat_secret_cache_unchanged",
        versTest.versatilityState().total, 12)

    secretFlat = false
    ratingBonus = 15
    flatBonus = 3
    ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_partial_secret_preserves_last_full_total.recovery_no_error", ok, blocks)
    eq("render.versatility_partial_secret_preserves_last_full_total.recovery_total",
        blockDumpContains(blocks, "18.0%"), true)
    eq("render.versatility_partial_secret_preserves_last_full_total.recovery_cache",
        versTest.versatilityState().total, 18)
end

do
    local secretRatingBonus = 14.7
    local versEnv, _, versTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            showRating = false,
            showPercentage = true,
            hideZeroOffensive = false,
            showCrit = false,
            showHaste = false,
            showMastery = false,
            showVersatility = true,
            showTertiary = false,
            showDefensive = false,
        },
        getCombatRatingBonus = function() return secretRatingBonus end,
        getVersatilityBonus = function() return 2 end,
        issecretvalue = function(value) return value == secretRatingBonus end,
    })
    fireEvent("render.versatility_cold_partial_secret_stays_unknown.fire", versEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_cold_partial_secret_stays_unknown.no_error", ok, blocks)
    eq("render.versatility_cold_partial_secret_stays_unknown.no_row", blockDumpContains(blocks, "Vers:"), false)
    eq("render.versatility_cold_partial_secret_stays_unknown.no_partial", blockDumpContains(blocks, "14.7%"), false)
    eq("render.versatility_cold_partial_secret_stays_unknown.cache", versTest.versatilityState().total, nil)
end

do
    local secretFlatBonus = 3.3
    local versEnv, _, versTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            showRating = false,
            showPercentage = true,
            hideZeroOffensive = false,
            showCrit = false,
            showHaste = false,
            showMastery = false,
            showVersatility = true,
            showTertiary = false,
            showDefensive = false,
        },
        getCombatRatingBonus = function() return 0 end,
        getVersatilityBonus = function() return secretFlatBonus end,
        issecretvalue = function(value) return value == secretFlatBonus end,
    })
    fireEvent("render.versatility_secret_flat_with_zero_rating_is_complete.fire", versEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_secret_flat_with_zero_rating_is_complete.no_error", ok, blocks)
    eq("render.versatility_secret_flat_with_zero_rating_is_complete.live_total",
        blockDumpContains(blocks, "3.3%"), true)
    eq("render.versatility_secret_flat_with_zero_rating_is_complete.clean_cache_unchanged",
        versTest.versatilityState().total, nil)
end

do
    local secretFlatBonus = 3.3
    local versEnv, _, versTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            showRating = false,
            showPercentage = true,
            hideZeroOffensive = false,
            showCrit = false,
            showHaste = false,
            showMastery = false,
            showVersatility = true,
            showTertiary = false,
            showDefensive = false,
        },
        getCombatRatingBonus = function() return 5 end,
        getVersatilityBonus = function() return secretFlatBonus end,
        issecretvalue = function(value) return value == secretFlatBonus end,
    })
    fireEvent("render.versatility_cold_secret_flat_with_nonzero_rating_unknown.fire", versEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_cold_secret_flat_with_nonzero_rating_unknown.no_error", ok, blocks)
    eq("render.versatility_cold_secret_flat_with_nonzero_rating_unknown.no_row",
        blockDumpContains(blocks, "Vers:"), false)
    eq("render.versatility_cold_secret_flat_with_nonzero_rating_unknown.no_partial",
        blockDumpContains(blocks, "3.3%"), false)
    eq("render.versatility_cold_secret_flat_with_nonzero_rating_unknown.cache",
        versTest.versatilityState().total, nil)
end

do
    local secretRatingBonus = 14.7
    local secretFlatBonus = 3.3
    local versEnv, _, versTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            showRating = false,
            showPercentage = true,
            hideZeroOffensive = false,
            showCrit = false,
            showHaste = false,
            showMastery = false,
            showVersatility = true,
            showTertiary = false,
            showDefensive = false,
        },
        getCombatRatingBonus = function() return secretRatingBonus end,
        getVersatilityBonus = function() return secretFlatBonus end,
        issecretvalue = function(value)
            return value == secretRatingBonus or value == secretFlatBonus
        end,
    })
    fireEvent("render.versatility_cold_both_secret_unknown.fire", versEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_cold_both_secret_unknown.no_error", ok, blocks)
    eq("render.versatility_cold_both_secret_unknown.no_row", blockDumpContains(blocks, "Vers:"), false)
    eq("render.versatility_cold_both_secret_unknown.no_rating_partial",
        blockDumpContains(blocks, "14.7%"), false)
    eq("render.versatility_cold_both_secret_unknown.no_flat_partial",
        blockDumpContains(blocks, "3.3%"), false)
    eq("render.versatility_cold_both_secret_unknown.cache", versTest.versatilityState().total, nil)
end

do
    local secretMode = false
    local ratingBonus = 0
    local flatBonus = 0
    local versEnv, _, versTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            showRating = false,
            showPercentage = true,
            hideZeroOffensive = true,
            showCrit = false,
            showHaste = false,
            showMastery = false,
            showVersatility = true,
            showTertiary = false,
            showDefensive = false,
        },
        getCombatRatingBonus = function() return ratingBonus end,
        getVersatilityBonus = function() return flatBonus end,
        issecretvalue = function(value)
            return secretMode and (value == ratingBonus or value == flatBonus)
        end,
    })
    fireEvent("render.versatility_hide_zero_secret_preserves_hidden.fire", versEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_hide_zero_secret_preserves_hidden.clean_no_error", ok, blocks)
    eq("render.versatility_hide_zero_secret_preserves_hidden.clean_no_row",
        blockDumpContains(blocks, "Vers:"), false)
    eq("render.versatility_hide_zero_secret_preserves_hidden.clean_cache", versTest.versatilityState().total, 0)
    ratingBonus = 14.7
    flatBonus = 3.3
    secretMode = true
    ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_hide_zero_secret_preserves_hidden.secret_no_error", ok, blocks)
    eq("render.versatility_hide_zero_secret_preserves_hidden.secret_no_row",
        blockDumpContains(blocks, "Vers:"), false)
    eq("render.versatility_hide_zero_secret_preserves_hidden.secret_cache", versTest.versatilityState().total, 0)
    eq("render.versatility_hide_zero_secret_preserves_hidden.visibility",
        versTest.versatilityState().percentVisible, false)
end

do
    local secretMode = false
    local ratingBonus = 10
    local flatBonus = 2
    local versEnv, _, versTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            showRating = false,
            showPercentage = true,
            hideZeroOffensive = true,
            showCrit = false,
            showHaste = false,
            showMastery = false,
            showVersatility = true,
            showTertiary = false,
            showDefensive = false,
        },
        getCombatRatingBonus = function() return ratingBonus end,
        getVersatilityBonus = function() return flatBonus end,
        issecretvalue = function(value)
            return secretMode and (value == ratingBonus or value == flatBonus)
        end,
    })
    fireEvent("render.versatility_hide_zero_secret_preserves_visible.fire", versEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_hide_zero_secret_preserves_visible.clean_no_error", ok, blocks)
    eq("render.versatility_hide_zero_secret_preserves_visible.clean_row",
        blockDumpContains(blocks, "12.0%"), true)
    ratingBonus = 14.7
    flatBonus = 3.3
    secretMode = true
    ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_hide_zero_secret_preserves_visible.secret_no_error", ok, blocks)
    eq("render.versatility_hide_zero_secret_preserves_visible.secret_last_full",
        blockDumpContains(blocks, "12.0%"), true)
    eq("render.versatility_hide_zero_secret_preserves_visible.secret_cache", versTest.versatilityState().total, 12)
    eq("render.versatility_hide_zero_secret_preserves_visible.visibility",
        versTest.versatilityState().percentVisible, true)
end

do
    local secretRatingBonus = 14.7
    local secretFlatBonus = 3.3
    local conversionCalls = 0
    local conversionMode = "normal"
    local targetFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(targetFixture, "mythicPlus", "MAGE", "frost",
        { crit = 100, haste = 200, mastery = 300, versatility = 1000 })
    local versEnv, _, versTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        statsProDB = {
            showOffensive = true,
            showRating = true,
            showPercentage = true,
            hideZeroOffensive = true,
            showCrit = false,
            showHaste = false,
            showMastery = false,
            showVersatility = true,
            showTertiary = false,
            showDefensive = false,
        },
        statsProArchonTargets = targetFixture,
        getCombatRatingBonus = function() return secretRatingBonus end,
        getVersatilityBonus = function() return secretFlatBonus end,
        getCombatRating = function() return 699 end,
        getCombatRatingBonusForCombatRatingValue = function(_, rating)
            conversionCalls = conversionCalls + 1
            if conversionMode == "missing-current" and rating == 700 then return nil end
            return rating / 100
        end,
        issecretvalue = function(value)
            return value == secretRatingBonus or value == secretFlatBonus
        end,
    })
    fireEvent("render.versatility_cold_secret_percent_keeps_clean_rating.fire", versEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_cold_secret_percent_keeps_clean_rating.no_error", ok, blocks)
    local offensive = blocks[2]
    eq("render.versatility_cold_secret_percent_keeps_clean_rating.row_count", #(offensive.labels or {}), 1)
    eq("render.versatility_cold_secret_percent_keeps_clean_rating.rating",
        offensive.ratings[1]:find("699", 1, true) ~= nil, true)
    eq("render.versatility_cold_secret_percent_keeps_clean_rating.no_partial_percent",
        offensive.values[1], "")
    local meta = offensive.targetRows[1]
    check("render.versatility_cold_secret_percent_keeps_clean_rating.meta", type(meta) == "table", meta)
    eq("render.versatility_cold_secret_percent_keeps_clean_rating.meta_current", meta.current, 699)
    eq("render.versatility_cold_secret_percent_keeps_clean_rating.meta_current_pct", meta.currentPct, nil)
    eq("render.versatility_cold_secret_percent_keeps_clean_rating.cache", versTest.versatilityState().total, nil)
    versTest.renderMainPanelForSmoke("Vers:", "699", "", 1, nil, nil, { meta })
    versTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    eq("render.versatility_cold_secret_percent_keeps_clean_rating.tooltip_target_raw",
        versEnv.GameTooltip.lines[2].right, "1000")
    eq("render.versatility_cold_secret_percent_keeps_clean_rating.tooltip_current_raw",
        versEnv.GameTooltip.lines[3].right, "699")
    eq("render.versatility_cold_secret_percent_keeps_clean_rating.tooltip_missing_raw",
        versEnv.GameTooltip.lines[4].right, "301")
    eq("render.versatility_cold_secret_percent_keeps_clean_rating.tooltip_skips_partial_conversion",
        conversionCalls, 0)

    local cleanMeta = {
        statKey = "versatility",
        colorKey = "versatility",
        ratingCR = versEnv.CR_VERSATILITY_DAMAGE_DONE,
        target = 1000,
        current = 700,
        currentPct = 12,
        delta = -300,
        capturedAt = "2026-05-15",
        snapshotKey = "mythicPlus",
    }
    versTest.renderMainPanelForSmoke("Vers:", "700", "12.0%", 1, nil, nil, { cleanMeta })
    versTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    eq("render.versatility_clean_percent_tooltip.target_projected_total",
        versEnv.GameTooltip.lines[2].right, "1000 (~15.0%)")
    eq("render.versatility_clean_percent_tooltip.current_complete_total",
        versEnv.GameTooltip.lines[3].right, "700 (~12.0%)")
    eq("render.versatility_clean_percent_tooltip.missing_rating_delta",
        versEnv.GameTooltip.lines[4].right, "300 (~+3.0%)")
    eq("render.versatility_clean_percent_tooltip.uses_rating_conversion", conversionCalls, 2)

    conversionMode = "missing-current"
    conversionCalls = 0
    versTest.renderMainPanelForSmoke("Vers:", "700", "12.0%", 1, nil, nil, { cleanMeta })
    versTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    eq("render.versatility_partial_conversion_tooltip.target_raw",
        versEnv.GameTooltip.lines[2].right, "1000")
    eq("render.versatility_partial_conversion_tooltip.current_complete_total",
        versEnv.GameTooltip.lines[3].right, "700 (~12.0%)")
    eq("render.versatility_partial_conversion_tooltip.missing_raw",
        versEnv.GameTooltip.lines[4].right, "300")
    eq("render.versatility_partial_conversion_tooltip.attempts_both_conversions", conversionCalls, 2)
end

do
    local secretVersRatingBonus = 14.7
    local secretVersRating = 888
    local secretVersFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(secretVersFixture, "mythicPlus", "MAGE", "frost",
        { crit = 100, haste = 200, mastery = 300, versatility = 1000 })
    local versEnv, _, versTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        statsProDB = {
            showOffensive = true,
            showRating = true,
            showPercentage = true,
            hideZeroOffensive = false,
            showCrit = false,
            showHaste = false,
            showMastery = false,
            showVersatility = true,
            showTertiary = false,
            showDefensive = false,
        },
        statsProArchonTargets = secretVersFixture,
        getCombatRatingBonus = function() return secretVersRatingBonus end,
        getVersatilityBonus = function() return 0 end,
        getCombatRating = function() return secretVersRating end,
        issecretvalue = function(value)
            return value == secretVersRatingBonus or value == secretVersRating
        end,
    })
    fireEvent("render.versatility_secret_rating_displays_without_meta.fire", versEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_secret_rating_displays_without_meta.no_error", ok, blocks)
    eq("render.versatility_secret_rating_displays_without_meta.row", blockDumpContains(blocks, "Vers:"), true)
    eq("render.versatility_secret_rating_displays_without_meta.rating", blockDumpContains(blocks, "888"), true)
    eq("render.versatility_secret_rating_displays_without_meta.percent", blockDumpContains(blocks, "14.7%"), true)
    eq("render.versatility_secret_rating_displays_without_meta.no_target_meta", blocks[2].targetRows[1], false)
end

do
    local versEnv, _, versTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            showRating = true,
            showPercentage = false,
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
        getCombatRating = function() return 699 end,
    })
    fireEvent("render.versatility_rating_only_nil_bonus_uses_clean_rating.fire", versEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_rating_only_nil_bonus_uses_clean_rating.no_error", ok, blocks)
    eq("render.versatility_rating_only_nil_bonus_uses_clean_rating.row", blockDumpContains(blocks, "Vers:"), true)
    eq("render.versatility_rating_only_nil_bonus_uses_clean_rating.rating", blockDumpContains(blocks, "699"), true)
end

do
    local targetFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(targetFixture, "mythicPlus", "MAGE", "frost",
        { crit = 100, haste = 200, mastery = 300, versatility = 1000 })
    local versEnv, _, versTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        statsProDB = {
            showOffensive = true,
            showRating = true,
            showPercentage = true,
            hideZeroOffensive = true,
            showCrit = false,
            showHaste = false,
            showMastery = false,
            showVersatility = true,
            showTertiary = false,
            showDefensive = false,
        },
        statsProArchonTargets = targetFixture,
        getCombatRatingBonus = function() return nil end,
        getVersatilityBonus = function() return nil end,
        getCombatRating = function() return 699 end,
    })
    fireEvent("render.versatility_dual_nil_bonus_uses_clean_rating_and_meta.fire", versEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(versTest.buildRenderBlocks)
    check("render.versatility_dual_nil_bonus_uses_clean_rating_and_meta.no_error", ok, blocks)
    local offensive = blocks[2]
    eq("render.versatility_dual_nil_bonus_uses_clean_rating_and_meta.row_count", #(offensive.labels or {}), 1)
    eq("render.versatility_dual_nil_bonus_uses_clean_rating_and_meta.label",
        offensive.labels[1]:find("Vers:", 1, true) ~= nil, true)
    eq("render.versatility_dual_nil_bonus_uses_clean_rating_and_meta.rating",
        offensive.ratings[1]:find("699", 1, true) ~= nil, true)
    eq("render.versatility_dual_nil_bonus_uses_clean_rating_and_meta.no_fake_percent",
        offensive.values[1], "")
    local meta = offensive.targetRows[1]
    check("render.versatility_dual_nil_bonus_uses_clean_rating_and_meta.meta", type(meta) == "table", meta)
    eq("render.versatility_dual_nil_bonus_uses_clean_rating_and_meta.current", meta.current, 699)
    eq("render.versatility_dual_nil_bonus_uses_clean_rating_and_meta.current_pct", meta.currentPct, nil)
    eq("render.versatility_dual_nil_bonus_uses_clean_rating_and_meta.target", meta.target, 1000)
end

do
    local secretSpeed = {}
    local speedEnv, _, speedTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showTertiary = true,
            showRating = false,
            showPercentage = true,
            hideZeroTertiary = false,
            showLeech = false,
            showAvoidance = false,
            showSpeed = true,
            showDefensive = false,
        },
        getUnitSpeed = function() return 0, secretSpeed, secretSpeed, secretSpeed end,
        issecretvalue = function(value) return value == secretSpeed end,
    })
    fireEvent("render.speed_cold_unknown_percent_only_no_row.fire", speedEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(speedTest.buildRenderBlocks)
    check("render.speed_cold_unknown_percent_only_no_row.no_error", ok, blocks)
    eq("render.speed_cold_unknown_percent_only_no_row.no_fake_zero",
        blockDumpContains(blocks, "Movement:"), false)
end

do
    local secretSpeed = {}
    local speedEnv, _, speedTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showTertiary = true,
            showRating = true,
            showPercentage = true,
            hideZeroTertiary = true,
            showLeech = false,
            showAvoidance = false,
            showSpeed = true,
            showDefensive = false,
        },
        getUnitSpeed = function() return 0, secretSpeed, secretSpeed, secretSpeed end,
        getCombatRating = function() return 377 end,
        issecretvalue = function(value) return value == secretSpeed end,
    })
    fireEvent("render.speed_cold_unknown_dual_rating_row_blank_value.fire", speedEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(speedTest.buildRenderBlocks)
    check("render.speed_cold_unknown_dual_rating_row_blank_value.no_error", ok, blocks)
    local tertiary = blocks[3]
    eq("render.speed_cold_unknown_dual_rating_row_blank_value.row_count", #(tertiary.labels or {}), 1)
    eq("render.speed_cold_unknown_dual_rating_row_blank_value.rating",
        tertiary.ratings[1]:find("377", 1, true) ~= nil, true)
    eq("render.speed_cold_unknown_dual_rating_row_blank_value.blank_value", tertiary.values[1], "")
end

do
    local speedEnv, _, speedTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showTertiary = true,
            showRating = true,
            showPercentage = false,
            hideZeroTertiary = true,
            showLeech = false,
            showAvoidance = false,
            showSpeed = true,
            showDefensive = false,
        },
        getUnitSpeed = function() return 0, 0, 0, 0 end,
        getCombatRating = function() return 377 end,
    })
    fireEvent("render.speed_rating_only_zero_speed_uses_clean_rating.fire", speedEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(speedTest.buildRenderBlocks)
    check("render.speed_rating_only_zero_speed_uses_clean_rating.no_error", ok, blocks)
    eq("render.speed_rating_only_zero_speed_uses_clean_rating.row", blockDumpContains(blocks, "Movement:"), true)
    eq("render.speed_rating_only_zero_speed_uses_clean_rating.rating", blockDumpContains(blocks, "377"), true)
end

do
    local speedEnv, _, speedTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showTertiary = true,
            showRating = true,
            showPercentage = true,
            hideZeroTertiary = true,
            showLeech = false,
            showAvoidance = false,
            showSpeed = true,
            showDefensive = false,
        },
        getUnitSpeed = function() return 0, 0, 0, 0 end,
        getCombatRating = function() return 377 end,
    })
    fireEvent("render.speed_dual_zero_speed_uses_clean_rating.fire", speedEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(speedTest.buildRenderBlocks)
    check("render.speed_dual_zero_speed_uses_clean_rating.no_error", ok, blocks)
    local tertiary = blocks[3]
    eq("render.speed_dual_zero_speed_uses_clean_rating.row_count", #(tertiary.labels or {}), 1)
    eq("render.speed_dual_zero_speed_uses_clean_rating.label",
        tertiary.labels[1]:find("Movement:", 1, true) ~= nil, true)
    eq("render.speed_dual_zero_speed_uses_clean_rating.rating",
        tertiary.ratings[1]:find("377", 1, true) ~= nil, true)
    eq("render.speed_dual_zero_speed_uses_clean_rating.clean_zero_percent",
        tertiary.values[1]:find("0.0%", 1, true) ~= nil, true)
end

do
    local speedEnv, _, speedTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showTertiary = true,
            showRating = false,
            showPercentage = true,
            hideZeroTertiary = false,
            showLeech = false,
            showAvoidance = false,
            showSpeed = true,
            showDefensive = false,
        },
        getUnitSpeed = function() return 0, 15.4, 29.4, 7.7 end,
        isSwimming = function() return false end,
        isFlying = function() return false end,
    })
    fireEvent("render.speed_ground_mount_uses_run_not_flight.fire", speedEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(speedTest.buildRenderBlocks)
    check("render.speed_ground_mount_uses_run_not_flight.no_error", ok, blocks)
    eq("render.speed_ground_mount_uses_run_not_flight.value",
        blockDumpContains(blocks, "220.0%"), true)
    eq("render.speed_ground_mount_uses_run_not_flight.no_flight_value",
        blockDumpContains(blocks, "420.0%"), false)
end

do
    local runYps = 7.7
    local speedEnv, _, speedTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showTertiary = true,
            showRating = false,
            showPercentage = true,
            hideZeroTertiary = false,
            showLeech = false,
            showAvoidance = false,
            showSpeed = true,
            showDefensive = false,
        },
        getUnitSpeed = function() return 0, runYps, 7.7, 7.7 end,
    })
    fireEvent("render.speed_ground_buff_tracks_run_speed.fire", speedEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(speedTest.buildRenderBlocks)
    check("render.speed_ground_buff_tracks_run_speed.buff_no_error", ok, blocks)
    eq("render.speed_ground_buff_tracks_run_speed.buff_value",
        blockDumpContains(blocks, "110.0%"), true)

    runYps = 7
    ok, blocks = pcall(speedTest.buildRenderBlocks)
    check("render.speed_ground_buff_tracks_run_speed.unbuff_no_error", ok, blocks)
    eq("render.speed_ground_buff_tracks_run_speed.unbuff_value",
        blockDumpContains(blocks, "100.0%"), true)
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
    local ilvlHiddenEnv, _, ilvlHiddenTest = loadStatsPro("enUS", {
        statsProDB = {
            labelStyle = "hidden",
            showRating = true,
            showPercentage = true,
            showOffensive = false,
            showTertiary = false,
            showDefensive = false,
            showItemLevel = true,
            showDurability = false,
            showRepairCost = false,
        },
        getAverageItemLevel = function() return 273, 271 end,
    })
    fireEvent("render.item_level_hidden_label_keeps_values.fire", ilvlHiddenEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(ilvlHiddenTest.buildRenderBlocks)
    check("render.item_level_hidden_label_keeps_values.no_error", ok, blocks)
    local itemLevel = findBlockBySplitKey("render.item_level_hidden_label_keeps_values.block", blocks, "splitItemLevel")
    eq("render.item_level_hidden_label_keeps_values.row_count", #(itemLevel.labels or {}), 1)
    eq("render.item_level_hidden_label_keeps_values.blank_label", itemLevel.labels[1], "")
    eq("render.item_level_hidden_label_keeps_values.equipped", itemLevel.ratings[1]:find("271", 1, true) ~= nil, true)
    eq("render.item_level_hidden_label_keeps_values.overall", itemLevel.values[1]:find("273", 1, true) ~= nil, true)
    local mainBucket = ilvlHiddenTest.routeRenderBlocks(blocks, "sectioned", nil, "hidden")
    eq("render.item_level_hidden_label_keeps_values.bucket_content", ilvlHiddenTest.bucketHasContent(mainBucket), true)
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

    local movementCases = {
        { "enUS", "Movement" },
        { "ruRU", "Движ" },
        { "deDE", "Beweg" },
        { "frFR", "Dépl" },
        { "esES", "Mov" },
        { "esMX", "Mov" },
        { "itIT", "Mov" },
        { "ptBR", "Mov" },
        { "koKR", "이동" },
        { "zhCN", "移动" },
        { "zhTW", "移動" },
    }

    for _, case in ipairs(movementCases) do
        local locale, expected = case[1], case[2]
        runCache(runMigrate({ forceLocale = locale }))
        eq("labels.movement_" .. locale .. "_full", test.getStyledLabelText("Speed", "full"), expected .. ":")
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
eq("fonts.uncataloged_path_is_not_usable", test.usableFontPath("Interface\\AddOns\\Media\\Mystery.ttf"), nil)

do
    local dangling = "B – C"
    local danglingCalls = 0
    local coldEnv, _, coldTest = loadStatsPro("enUS", {
        statsProDB = {
            dbVersion = test.currentDBVersion(),
            font = dangling,
            fontBeforeAutoSwitch = dangling,
        },
        setFontResult = function(_, font)
            if font == dangling then
                danglingCalls = danglingCalls + 1
                error("dangling saved font must never reach SetFont")
            end
            return true
        end,
    })
    eq("fonts.dangling_saved_path.cold_load_never_attempts_asset", danglingCalls, 0)
    fireEvent("fonts.dangling_saved_path.pew", coldEnv, "PLAYER_ENTERING_WORLD")
    eq("fonts.dangling_saved_path.pew_never_attempts_asset", danglingCalls, 0)
    eq("fonts.dangling_saved_path.repairs_db", coldEnv.StatsProDB.font, "Fonts\\FRIZQT__.TTF")
    eq("fonts.dangling_saved_path.clears_restore_path", coldEnv.StatsProDB.fontBeforeAutoSwitch, nil)
    local state = coldTest.panelFontState()
    eq("fonts.dangling_saved_path.main_panel_uses_fallback", state.mainAppliedFont, "Fonts\\FRIZQT__.TTF")
    eq("fonts.dangling_saved_path.side_panel_uses_fallback", state.sideAppliedFont, "Fonts\\FRIZQT__.TTF")

    local ruEnv, _, ruTest = loadStatsPro("enUS", {
        statsProDB = {
            dbVersion = test.currentDBVersion(),
            font = dangling,
            forceLocale = "ruRU",
        },
        setFontResult = function(_, font)
            if font == dangling then error("dangling saved font must never reach SetFont") end
            return true
        end,
    })
    fireEvent("fonts.dangling_saved_path.ru_fallback.pew", ruEnv, "PLAYER_ENTERING_WORLD")
    eq("fonts.dangling_saved_path.ru_fallback.db", ruEnv.StatsProDB.font, "Fonts\\ARIALN.TTF")
    eq("fonts.dangling_saved_path.ru_fallback.panel", ruTest.panelFontState().mainAppliedFont, "Fonts\\ARIALN.TTF")
end

do
    local secretPath = "Interface\\AddOns\\SecretMedia\\Secret.ttf"
    local secretSetFontCalls = 0
    local secretEnv = loadStatsPro("enUS", {
        statsProDB = {
            dbVersion = test.currentDBVersion(),
            font = secretPath,
            fontBeforeAutoSwitch = secretPath,
        },
        issecretvalue = function(value) return value == secretPath end,
        setFontResult = function(_, font)
            if font == secretPath then secretSetFontCalls = secretSetFontCalls + 1 end
            return true
        end,
    })
    fireEvent("fonts.secret_saved_path.pew", secretEnv, "PLAYER_ENTERING_WORLD")
    eq("fonts.secret_saved_path.never_reaches_set_font", secretSetFontCalls, 0)
    eq("fonts.secret_saved_path.repairs_font", secretEnv.StatsProDB.font, "Fonts\\FRIZQT__.TTF")
    eq("fonts.secret_saved_path.clears_saved_font", secretEnv.StatsProDB.fontBeforeAutoSwitch, nil)

    local futureSecretDB = {
        dbVersion = test.currentDBVersion() + 1,
        font = secretPath,
        fontBeforeAutoSwitch = secretPath,
        fontSize = 14,
        forceLocale = "auto",
        textOutlineStyle = "outline",
    }
    local futureSecretEnv = loadStatsPro("enUS", {
        statsProDB = futureSecretDB,
        issecretvalue = function(value) return value == secretPath end,
    })
    fireEvent("fonts.secret_saved_path.future_pew", futureSecretEnv, "PLAYER_ENTERING_WORLD")
    clearPrints(futureSecretEnv)
    slash("fonts.secret_saved_path.future_debug", futureSecretEnv, "debug")
    eq("fonts.secret_saved_path.future_debug_redacts_saved",
        printContains(futureSecretEnv, "saved=<unavailable>"), true)
    eq("fonts.secret_saved_path.future_debug_preserves_db", futureSecretDB.fontBeforeAutoSwitch, secretPath)
end

do
    local missingDefault = "Fonts\\Missing.ttf"
    local defaultEnv, _, defaultTest = loadStatsPro("enUS", {
        standardTextFont = missingDefault,
        setFontResult = function(_, font)
            if font == missingDefault then return false end
            return true
        end,
    })
    fireEvent("fonts.invalid_standard_text_font.pew", defaultEnv, "PLAYER_ENTERING_WORLD")
    eq("fonts.invalid_standard_text_font.safe_default", defaultTest.safeDefaultFontPath(), "Fonts\\FRIZQT__.TTF")
    eq("fonts.invalid_standard_text_font.repairs_db", defaultEnv.StatsProDB.font, "Fonts\\FRIZQT__.TTF")
    eq("fonts.invalid_standard_text_font.panel_font", defaultTest.panelFontState().mainAppliedFont, "Fonts\\FRIZQT__.TTF")
end

do
    local futureDB = {
        dbVersion = test.currentDBVersion() + 1,
        font = "Fonts\\FRIZQT__.TTF",
        fontBeforeAutoSwitch = "B – C",
        fontSize = 14,
        forceLocale = "ruRU",
        textOutlineStyle = "outline",
    }
    local futureEnv, _, futureTest = loadStatsPro("enUS", { statsProDB = futureDB })
    fireEvent("fonts.future_schema_locale_runtime_fallback.pew", futureEnv, "PLAYER_ENTERING_WORLD")
    eq("fonts.future_schema_locale_runtime_fallback.db_font_unchanged", futureDB.font, "Fonts\\FRIZQT__.TTF")
    eq("fonts.future_schema_locale_runtime_fallback.saved_font_unchanged", futureDB.fontBeforeAutoSwitch, "B – C")
    eq("fonts.future_schema_locale_runtime_fallback.panel_uses_cyrillic_font",
        futureTest.panelFontState().mainAppliedFont, "Fonts\\ARIALN.TTF")
end

do
    local brokenSaved = "Interface\\AddOns\\BrokenMedia\\Broken.ttf"
    local brokenCalls = 0
    local savedEnv = loadStatsPro("enUS", {
        statsProDB = {
            dbVersion = test.currentDBVersion(),
            font = "Fonts\\FRIZQT__.TTF",
            fontBeforeAutoSwitch = brokenSaved,
        },
        lsmFonts = { { name = "Broken Saved", path = brokenSaved } },
        setFontResult = function(_, font)
            if font == brokenSaved then
                brokenCalls = brokenCalls + 1
                return false
            end
            return true
        end,
    })
    fireEvent("fonts.cataloged_but_unloadable_saved_path.pew", savedEnv, "PLAYER_ENTERING_WORLD")
    eq("fonts.cataloged_but_unloadable_saved_path.probed_once", brokenCalls, 1)
    eq("fonts.cataloged_but_unloadable_saved_path.cleared", savedEnv.StatsProDB.fontBeforeAutoSwitch, nil)
end

do
    local cjkFontPath = "Interface\\AddOns\\SharedMedia\\Fonts\\NotoSansCJK-Regular.otf"
    local brokenFontPath = "Interface\\AddOns\\SharedMedia\\Fonts\\Missing.ttf"
    local brokenFontCalls = 0
    local lsmEnv, lsmAddon, lsmTest = loadStatsPro("enUS", {
        lsmFonts = {
            { name = "Latin Decorative", path = "Interface\\AddOns\\SharedMedia\\Fonts\\Decorative.ttf" },
            { name = "Noto Sans CJK", path = cjkFontPath },
            { name = "Broken Registration", path = brokenFontPath },
        },
        lsmGlobalFontPath = "Fonts\\FRIZQT__.TTF",
        setFontResult = function(_, font)
            if font == brokenFontPath then
                brokenFontCalls = brokenFontCalls + 1
                return false
            end
            return true
        end,
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
    eq("fonts.lsm_picker_filters_unloadable_registration", countFrameField(lsmEnv, "fontName", "Broken Registration"), 0)
    eq("fonts.lsm_picker_probes_unloadable_registration_once", brokenFontCalls, 1)
    local lsmFontButton = findFrame("fonts.lsm_picker_registered_button", lsmEnv, function(frame)
        return frame.fontName == "Noto Sans CJK"
    end)
    eq("fonts.lsm_picker_button_carries_path", lsmFontButton.fontPath, cjkFontPath)
    eq("fonts.lsm_picker_ignores_global_fetch_override", lsmFontButton.fontPath, cjkFontPath)
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
    local outlineFallbackPath = "Interface\\AddOns\\SharedMedia\\Fonts\\NoOutline.ttf"
    local setFontCalls = 0
    local fallbackEnv, _, fallbackTest = loadStatsPro("enUS", {
        lsmFonts = { { name = "No Outline", path = outlineFallbackPath } },
        setFontResult = function(_, _, _, flags)
            setFontCalls = setFontCalls + 1
            if flags ~= nil then return false end
            return true
        end,
    })
    fireEvent("fonts.unsupported_flags_fall_back_to_base.pew", fallbackEnv, "PLAYER_ENTERING_WORLD")
    local applied, effectiveFont = fallbackTest.applyCommittedTextStyle(outlineFallbackPath, 14, true, false)
    eq("fonts.unsupported_flags_fall_back_to_base.applied", applied, true)
    eq("fonts.unsupported_flags_fall_back_to_base.effective_font", effectiveFont, outlineFallbackPath)
    eq("fonts.unsupported_flags_fall_back_to_base.db_font", fallbackEnv.StatsProDB.font, outlineFallbackPath)
    local state = fallbackTest.panelFontState()
    eq("fonts.unsupported_flags_fall_back_to_base.main_outline_preference", state.mainAppliedTextOutlineStyle, "outline")
    eq("fonts.unsupported_flags_fall_back_to_base.side_outline_preference", state.sideAppliedTextOutlineStyle, "outline")
    for _, key in ipairs({
        "mainAppliedFontFlags", "mainLabelFlags", "mainRatingFlags", "mainValueFlags",
        "mainRepairFlags", "mainRepairLabelFlags", "sideAppliedFontFlags", "sideLabelFlags",
        "sideRatingFlags", "sideValueFlags", "sideRepairFlags", "sideRepairLabelFlags",
    }) do
        eq("fonts.unsupported_flags_fall_back_to_base." .. key, state[key], nil)
    end
    local callsBeforeRepeat = setFontCalls
    applied = fallbackTest.applyCommittedTextStyle(outlineFallbackPath, 14, false, false)
    eq("fonts.unsupported_flags_fall_back_to_base.repeat_applied", applied, true)
    eq("fonts.unsupported_flags_fall_back_to_base.repeat_is_idempotent", setFontCalls, callsBeforeRepeat)
end

do
    local falsePath = "Interface\\AddOns\\SharedMedia\\Fonts\\FalseAtApply.ttf"
    local errorPath = "Interface\\AddOns\\SharedMedia\\Fonts\\ErrorAtApply.ttf"
    local failureMode = "pass"
    local rollbackEnv, _, rollbackTest = loadStatsPro("enUS", {
        statsProDB = { fontBeforeAutoSwitch = "Fonts\\ARIALN.TTF" },
        lsmFonts = {
            { name = "False At Apply", path = falsePath },
            { name = "Error At Apply", path = errorPath },
        },
        setFontResult = function(_, font)
            if font == falsePath and failureMode == "false" then return false end
            if font == errorPath and failureMode == "error" then error("synthetic SetFont error") end
            return true
        end,
    })
    fireEvent("fonts.failed_apply_rolls_back.pew", rollbackEnv, "PLAYER_ENTERING_WORLD")
    rollbackEnv.StatsProDB.fontBeforeAutoSwitch = "Fonts\\ARIALN.TTF"
    local stateKeys = {
        "mainAppliedFont", "mainAppliedSize", "mainAppliedTextOutlineStyle", "mainAppliedFontFlags",
        "mainLabelFont", "mainLabelSize", "mainLabelFlags", "mainRatingFont", "mainRatingFlags",
        "mainValueFont", "mainValueFlags", "mainRepairFont", "mainRepairFlags",
        "mainRepairLabelFont", "mainRepairLabelFlags", "sideAppliedFont", "sideAppliedSize",
        "sideAppliedTextOutlineStyle", "sideAppliedFontFlags", "sideLabelFont", "sideLabelSize",
        "sideLabelFlags", "sideRatingFont", "sideRatingFlags", "sideValueFont", "sideValueFlags",
        "sideRepairFont", "sideRepairFlags", "sideRepairLabelFont", "sideRepairLabelFlags",
    }
    local function assertPanelState(name, actual, expected)
        for _, key in ipairs(stateKeys) do eq(name .. "." .. key, actual[key], expected[key]) end
    end

    eq("fonts.failed_apply_rolls_back.false_path_preprobe", rollbackTest.usableFontPath(falsePath), falsePath)
    local baseline = rollbackTest.panelFontState()
    local baselineDBFont = rollbackEnv.StatsProDB.font
    failureMode = "false"
    local applied = rollbackTest.applyCommittedTextStyle(falsePath, 14, true, false)
    eq("fonts.failed_apply_rolls_back.false_result", applied, false)
    eq("fonts.failed_apply_rolls_back.false_db_font", rollbackEnv.StatsProDB.font, baselineDBFont)
    eq("fonts.failed_apply_rolls_back.false_saved_font", rollbackEnv.StatsProDB.fontBeforeAutoSwitch, "Fonts\\ARIALN.TTF")
    assertPanelState("fonts.failed_apply_rolls_back.false_state", rollbackTest.panelFontState(), baseline)

    failureMode = "pass"
    eq("fonts.failed_apply_rolls_back.error_path_preprobe", rollbackTest.usableFontPath(errorPath), errorPath)
    failureMode = "error"
    applied = rollbackTest.applyCommittedTextStyle(errorPath, 14, true, false)
    eq("fonts.failed_apply_rolls_back.error_result", applied, false)
    eq("fonts.failed_apply_rolls_back.error_db_font", rollbackEnv.StatsProDB.font, baselineDBFont)
    eq("fonts.failed_apply_rolls_back.error_saved_font", rollbackEnv.StatsProDB.fontBeforeAutoSwitch, "Fonts\\ARIALN.TTF")
    assertPanelState("fonts.failed_apply_rolls_back.error_state", rollbackTest.panelFontState(), baseline)
end

do
    local configTarget = "Interface\\AddOns\\SharedMedia\\Fonts\\ConfigTarget.ttf"
    local pickerTarget = "Interface\\AddOns\\SharedMedia\\Fonts\\PickerTarget.ttf"
    local mode = "pass"
    local defaultFontCalls = 0
    local configEnv, configAddon, configTest = loadStatsPro("enUS", {
        lsmFonts = {
            { name = "Config Target", path = configTarget },
            { name = "Picker Target", path = pickerTarget },
        },
        setFontResult = function(frame, font, _, flags)
            if font == configTarget and mode == "config-false" then return false end
            if font == pickerTarget and mode == "picker-false" then return false end
            if font == pickerTarget and mode == "picker-error" then error("synthetic config SetFont error") end
            if font == "Fonts\\ARIALN.TTF" and mode == "arial-false" then return false end
            if flags ~= nil then return false end
            if font == "Fonts\\FRIZQT__.TTF" then defaultFontCalls = defaultFontCalls + 1 end
            frame.text = ""  -- emulate Blizzard SetFont clearing an existing FontString
            return true
        end,
    })
    fireEvent("fonts.config_registry.pew", configEnv, "PLAYER_ENTERING_WORLD")
    local ok, err = pcall(function() configAddon:OpenConfigMenu() end)
    check("fonts.config_registry.open", ok, err)
    local before = configTest.configFontState()
    check("fonts.config_registry.has_entries", #before.entries > 10, "expected populated config font registry")

    local applied, effective = configTest.applyConfigFont(configTarget, true)
    eq("fonts.config_registry.flag_fallback_applies", applied, true)
    eq("fonts.config_registry.flag_fallback_effective", effective, configTarget)
    local after = configTest.configFontState()
    eq("fonts.config_registry.flag_fallback_current", after.currentFont, configTarget)
    eq("fonts.config_registry.flag_fallback_count", #after.entries, #before.entries)
    for i, entry in ipairs(after.entries) do
        eq("fonts.config_registry.flag_fallback.applied_font." .. i, entry.appliedFont, configTarget)
        eq("fonts.config_registry.flag_fallback.actual_font." .. i, entry.actualFont, configTarget)
        eq("fonts.config_registry.flag_fallback.applied_flags." .. i, entry.appliedFlags, nil)
        eq("fonts.config_registry.flag_fallback.actual_flags." .. i, entry.actualFlags, nil)
        eq("fonts.config_registry.flag_fallback.text_preserved." .. i, entry.actualText, before.entries[i].actualText)
    end

    applied = configTest.applyConfigFont("Fonts\\FRIZQT__.TTF", true)
    eq("fonts.config_registry.restore_default", applied, true)
    local defaultState = configTest.configFontState()
    mode = "config-false"
    applied = configTest.applyConfigFont(configTarget, true)
    eq("fonts.config_registry.false_rolls_back", applied, false)
    local falseState = configTest.configFontState()
    eq("fonts.config_registry.false_current_unchanged", falseState.currentFont, defaultState.currentFont)
    for i, entry in ipairs(falseState.entries) do
        eq("fonts.config_registry.false.applied_font." .. i, entry.appliedFont, defaultState.entries[i].appliedFont)
        eq("fonts.config_registry.false.actual_font." .. i, entry.actualFont, defaultState.entries[i].actualFont)
        eq("fonts.config_registry.false.actual_text." .. i, entry.actualText, defaultState.entries[i].actualText)
    end

    mode = "pass"
    applied = configTest.applyConfigFont(pickerTarget, true)
    eq("fonts.config_registry.error_preapply", applied, true)
    applied = configTest.applyConfigFont("Fonts\\FRIZQT__.TTF", true)
    eq("fonts.config_registry.error_restore_default", applied, true)
    local beforeError = configTest.configFontState()
    mode = "picker-error"
    applied = configTest.applyConfigFont(pickerTarget, true)
    eq("fonts.config_registry.error_rolls_back", applied, false)
    local errorState = configTest.configFontState()
    eq("fonts.config_registry.error_current_unchanged", errorState.currentFont, beforeError.currentFont)
    for i, entry in ipairs(errorState.entries) do
        eq("fonts.config_registry.error.applied_font." .. i, entry.appliedFont, beforeError.entries[i].appliedFont)
        eq("fonts.config_registry.error.actual_font." .. i, entry.actualFont, beforeError.entries[i].actualFont)
        eq("fonts.config_registry.error.actual_text." .. i, entry.actualText, beforeError.entries[i].actualText)
    end

    mode = "pass"
    eq("fonts.language_preview_failed_swap.preprobe_arial",
        configTest.usableFontPath("Fonts\\ARIALN.TTF"), "Fonts\\ARIALN.TTF")
    runDropdownInit("fonts.language_preview_failed_swap.language_init", configEnv.StatsProLanguageDropdown)
    configEnv.DropDownList1Button1.value = "ruRU"
    configEnv.UIDROPDOWNMENU_OPEN_MENU = configEnv.StatsProLanguageDropdown
    configEnv.DropDownList1:Hide()
    configEnv.DropDownList1:Show()
    local ruEnter = exists("fonts.language_preview_failed_swap.ru_hook",
        configEnv.DropDownList1Button1.hooks.OnEnter and configEnv.DropDownList1Button1.hooks.OnEnter[1])
    local panelBeforePreview = configTest.panelFontState()
    mode = "arial-false"
    ok, err = pcall(ruEnter, configEnv.DropDownList1Button1)
    check("fonts.language_preview_failed_swap.hover", ok, err)
    local panelAfterPreview = configTest.panelFontState()
    eq("fonts.language_preview_failed_swap.main_unchanged", panelAfterPreview.mainAppliedFont, panelBeforePreview.mainAppliedFont)
    eq("fonts.language_preview_failed_swap.side_unchanged", panelAfterPreview.sideAppliedFont, panelBeforePreview.sideAppliedFont)
    local callsAfterFailedPreview = defaultFontCalls
    configEnv.DropDownList1:Hide()
    configEnv.UIDROPDOWNMENU_OPEN_MENU = nil
    eq("fonts.language_preview_failed_swap.cancel_skips_false_restore", defaultFontCalls, callsAfterFailedPreview)

    mode = "pass"
    local beforeLazyPicker = configTest.configFontState()
    runScript("fonts.picker_failed_commit.open", configEnv.StatsProFontDropdownButton, "OnClick",
        configEnv.StatsProFontDropdownButton)
    local afterLazyPicker = configTest.configFontState()
    for i, entry in ipairs(beforeLazyPicker.entries) do
        eq("fonts.picker_lazy_registry.preserves_existing_text." .. i,
            afterLazyPicker.entries[i].actualText, entry.actualText)
    end
    local pickerButton = findFrame("fonts.picker_failed_commit.button", configEnv, function(frame)
        return frame.fontName == "Picker Target"
    end)
    local baselineDBFont = configEnv.StatsProDB.font
    configEnv.StatsProDB.fontBeforeAutoSwitch = "Fonts\\ARIALN.TTF"
    local baselineCaption = configEnv.StatsProFontDropdown.dropdownText
    local baselinePanel = configTest.panelFontState()
    mode = "picker-false"
    callScript("fonts.picker_failed_commit.hover", pickerButton, "OnEnter")
    callScript("fonts.picker_failed_commit.click", pickerButton, "OnClick")
    eq("fonts.picker_failed_commit.db_unchanged", configEnv.StatsProDB.font, baselineDBFont)
    eq("fonts.picker_failed_commit.saved_font_unchanged", configEnv.StatsProDB.fontBeforeAutoSwitch, "Fonts\\ARIALN.TTF")
    eq("fonts.picker_failed_commit.caption_unchanged", configEnv.StatsProFontDropdown.dropdownText, baselineCaption)
    local afterFailedPick = configTest.panelFontState()
    eq("fonts.picker_failed_commit.main_unchanged", afterFailedPick.mainAppliedFont, baselinePanel.mainAppliedFont)
    eq("fonts.picker_failed_commit.side_unchanged", afterFailedPick.sideAppliedFont, baselinePanel.sideAppliedFont)
end

do
    local failAll = false
    local settingsEnv, settingsAddon, settingsTest = loadStatsPro("enUS", {
        setFontResult = function()
            if failAll then return false end
            return true
        end,
    })
    fireEvent("fonts.settings_failure_rollback.pew", settingsEnv, "PLAYER_ENTERING_WORLD")
    local ok, err = pcall(function() settingsAddon:OpenConfigMenu() end)
    check("fonts.settings_failure_rollback.open", ok, err)
    local baseline = settingsTest.panelFontState()
    local baselineCaption = settingsEnv.StatsProFontDropdown.dropdownText
    failAll = true
    selectDropdownValue("fonts.settings_failure_rollback.outline", settingsEnv.StatsProTextOutlineDropdown, "thick")
    eq("fonts.settings_failure_rollback.outline_db", settingsEnv.StatsProDB.textOutlineStyle, "outline")
    eq("fonts.settings_failure_rollback.outline_caption", settingsEnv.StatsProTextOutlineDropdown.dropdownText, "Outline")
    eq("fonts.settings_failure_rollback.font_caption", settingsEnv.StatsProFontDropdown.dropdownText, baselineCaption)
    changeSlider("fonts.settings_failure_rollback.font_size", settingsEnv.StatsProFontSlider, 18)
    eq("fonts.settings_failure_rollback.font_size_db", settingsEnv.StatsProDB.fontSize, 14)
    eq("fonts.settings_failure_rollback.font_size_slider", settingsEnv.StatsProFontSlider:GetValue(), 14)
    eq("fonts.settings_failure_rollback.font_size_label", settingsEnv.StatsProFontSliderText:GetText(), "14")
    local after = settingsTest.panelFontState()
    eq("fonts.settings_failure_rollback.main_font", after.mainAppliedFont, baseline.mainAppliedFont)
    eq("fonts.settings_failure_rollback.main_size", after.mainAppliedSize, baseline.mainAppliedSize)
    eq("fonts.settings_failure_rollback.main_outline", after.mainAppliedTextOutlineStyle, baseline.mainAppliedTextOutlineStyle)
    eq("fonts.settings_failure_rollback.side_font", after.sideAppliedFont, baseline.sideAppliedFont)
    eq("fonts.settings_failure_rollback.side_size", after.sideAppliedSize, baseline.sideAppliedSize)
    eq("fonts.settings_failure_rollback.side_outline", after.sideAppliedTextOutlineStyle, baseline.sideAppliedTextOutlineStyle)
end

do
    local stalePath = "Interface\\AddOns\\SharedMedia\\Fonts\\StaleAfterLoad.ttf"
    local staleNow = false
    local staleEnv, staleAddon, staleTest = loadStatsPro("enUS", {
        statsProDB = { font = stalePath },
        lsmFonts = { { name = "Stale After Load", path = stalePath } },
        setFontResult = function(_, font)
            if font == stalePath and staleNow then return false end
            return true
        end,
    })
    fireEvent("fonts.runtime_failure_fallback_caption.pew", staleEnv, "PLAYER_ENTERING_WORLD")
    local ok, err = pcall(function() staleAddon:OpenConfigMenu() end)
    check("fonts.runtime_failure_fallback_caption.open", ok, err)
    eq("fonts.runtime_failure_fallback_caption.initial_caption",
        staleEnv.StatsProFontDropdown.dropdownText, "Stale After Load")
    staleNow = true
    changeSlider("fonts.runtime_failure_fallback_caption.font_size", staleEnv.StatsProFontSlider, 18)
    eq("fonts.runtime_failure_fallback_caption.db_font", staleEnv.StatsProDB.font, "Fonts\\FRIZQT__.TTF")
    eq("fonts.runtime_failure_fallback_caption.db_size", staleEnv.StatsProDB.fontSize, 18)
    eq("fonts.runtime_failure_fallback_caption.runtime_font",
        staleTest.currentRuntimeFontPath(), "Fonts\\FRIZQT__.TTF")
    eq("fonts.runtime_failure_fallback_caption.panel_font",
        staleTest.panelFontState().mainAppliedFont, "Fonts\\FRIZQT__.TTF")
    eq("fonts.runtime_failure_fallback_caption.caption",
        staleEnv.StatsProFontDropdown.dropdownText, "Friz Quadrata TT")
end

do
    local futureDB = {
        dbVersion = test.currentDBVersion() + 1,
        font = "Fonts\\FRIZQT__.TTF",
        fontSize = 14,
        forceLocale = "ruRU",
        textOutlineStyle = "outline",
    }
    local futureEnv, futureAddon, futureTest = loadStatsPro("enUS", { statsProDB = futureDB })
    fireEvent("fonts.future_schema_picker_baseline.pew", futureEnv, "PLAYER_ENTERING_WORLD")
    local ok, err = pcall(function() futureAddon:OpenConfigMenu() end)
    check("fonts.future_schema_picker_baseline.open_config", ok, err)
    runScript("fonts.future_schema_picker_baseline.open_picker", futureEnv.StatsProFontDropdownButton, "OnClick",
        futureEnv.StatsProFontDropdownButton)
    local frizButton = findFrame("fonts.future_schema_picker_baseline.friz_button", futureEnv, function(frame)
        return frame.fontName == "Friz Quadrata TT"
    end)
    callScript("fonts.future_schema_picker_baseline.refuses_commit", frizButton, "OnClick")
    eq("fonts.future_schema_picker_baseline.db_unchanged", futureDB.font, "Fonts\\FRIZQT__.TTF")
    eq("fonts.future_schema_picker_baseline.runtime_preserved",
        futureTest.currentRuntimeFontPath(), "Fonts\\ARIALN.TTF")
    eq("fonts.future_schema_picker_baseline.panel_preserved",
        futureTest.panelFontState().mainAppliedFont, "Fonts\\ARIALN.TTF")
    eq("fonts.future_schema_picker_baseline.caption_matches_runtime",
        futureEnv.StatsProFontDropdown.dropdownText, "Arial Narrow")
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
    eq("repair.scan_cost_complete", state.repairCostComplete, true)
    eq("repair.scan_skips_shirt_and_ranged.calls", table.concat(tooltipCalls, ","), "1,2")
    eq("repair.scan_surfaces_tooltip_args", surfaceCalls, 2)
    eq("repair.scan_no_retry_when_complete", state.retryScheduled, false)
    local repairBlock = findBlockBySplitKey("repair.scan_complete.block",
        repairTest.buildRenderBlocks(), "splitRepairCost")
    check("repair.scan_complete_row_visible", repairBlock.repairStr ~= "", "missing repair value")
end

do
    local secretRepairCost = setmetatable({}, {
        __tostring = function() error("secret repair cost inspected", 2) end,
    })
    local restricted = true
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
            return nil, nil
        end,
        getTooltipInventoryItem = function(_, slot)
            if slot == 2 then
                return { repairCost = restricted and secretRepairCost or 200 }
            end
            return tooltipDataBySlot[slot]
        end,
    })
    repairTest.cacheSettings()
    local ok, err = pcall(repairTest.refreshDurabilityCache)
    check("repair.pending_secret_cost_no_error", ok, err)
    local state = repairTest.durabilityState()
    near("repair.pending_worst_percent", state.durabilityValue, 50)
    eq("repair.pending_hides_partial_known_cost", state.repairCost, nil)
    eq("repair.pending_marks_cost_incomplete", state.repairCostComplete, false)
    eq("repair.pending_secret_waits_for_event", state.retryScheduled, false)
    eq("repair.pending_secret_has_no_timer", #repairEnv.__timers, 0)
    local repairBlock = findBlockBySplitKey("repair.pending_secret.block",
        repairTest.buildRenderBlocks(), "splitRepairCost")
    eq("repair.pending_secret_renders_unknown", repairBlock.repairStr, "?")
    restricted = false
    fireEvent("repair.pending_secret_regen", repairEnv, "PLAYER_REGEN_ENABLED")
    eq("repair.pending_secret_regen_marks_dirty", repairTest.durabilityState().dirty, true)
    repairTest.refreshDurabilityCache()
    state = repairTest.durabilityState()
    eq("repair.pending_secret_regen_recovers_cost", state.repairCost, 500)
    eq("repair.pending_secret_regen_recovers_complete", state.repairCostComplete, true)
    eq("repair.pending_secret_regen_no_timer", #repairEnv.__timers, 0)
end

do
    local mode = "known"
    local repairEnv, _, repairTest = loadStatsPro("enUS", {
        statsProDB = {
            showDurability = true,
            showRepairCost = true,
        },
        getInventoryItemDurability = function(slot)
            if slot == 1 then return 50, 100 end
            return nil, nil
        end,
        getTooltipInventoryItem = function()
            if mode == "known" then return { repairCost = 300 } end
            return nil
        end,
    })
    repairTest.cacheSettings()
    repairTest.refreshDurabilityCache()
    eq("repair.pending_all_nil.seed_cost", repairTest.durabilityState().repairCost, 300)
    mode = "pending"
    repairTest.refreshDurabilityCache()
    local state = repairTest.durabilityState()
    eq("repair.pending_all_nil_clears_prior_cost", state.repairCost, nil)
    eq("repair.pending_all_nil_marks_incomplete", state.repairCostComplete, false)
    local repairBlock = findBlockBySplitKey("repair.pending_all_nil.block",
        repairTest.buildRenderBlocks(), "splitRepairCost")
    eq("repair.pending_all_nil_renders_unknown", repairBlock.repairStr, "?")
    eq("repair.pending_all_nil_schedules_retry", state.retryScheduled, true)
    eq("repair.pending_all_nil_one_timer", #repairEnv.__timers, 1)
    repairTest.refreshDurabilityCache()
    eq("repair.pending_all_nil_no_duplicate_timer", #repairEnv.__timers, 1)
    flushTimers("repair.pending_all_nil_retry_timer", repairEnv, 3, 1)
    eq("repair.pending_all_nil_retry_marks_dirty", repairTest.durabilityState().dirty, true)
    repairTest.refreshDurabilityCache()
    eq("repair.pending_all_nil_stops_after_retry", #repairEnv.__timers, 0)
    mode = "known"
    fireEvent("repair.pending_all_nil_merchant_update", repairEnv, "MERCHANT_SHOW")
    eq("repair.pending_all_nil_merchant_marks_dirty", repairTest.durabilityState().dirty, true)
    repairTest.refreshDurabilityCache()
    state = repairTest.durabilityState()
    eq("repair.pending_all_nil_merchant_recovers_cost", state.repairCost, 300)
    eq("repair.pending_all_nil_merchant_recovers_complete", state.repairCostComplete, true)
    mode = "pending"
    fireEvent("repair.pending_all_nil_event_reset", repairEnv, "UPDATE_INVENTORY_DURABILITY")
    eq("repair.pending_all_nil_event_marks_dirty", repairTest.durabilityState().dirty, true)
    repairTest.refreshDurabilityCache()
    eq("repair.pending_all_nil_event_allows_one_retry", #repairEnv.__timers, 1)
end

do
    local mode = "known"
    local secretRepairCost = {}
    local _, _, repairTest = loadStatsPro("enUS", {
        statsProDB = {
            showDurability = true,
            showRepairCost = true,
        },
        issecretvalue = function(value) return value == secretRepairCost end,
        getInventoryItemDurability = function(slot)
            if slot == 1 then return 50, 100 end
            return nil, nil
        end,
        getTooltipInventoryItem = function()
            if mode == "known" then return { repairCost = 300 } end
            return { repairCost = secretRepairCost }
        end,
    })
    repairTest.cacheSettings()
    repairTest.refreshDurabilityCache()
    eq("repair.pending_all_secret.seed_cost", repairTest.durabilityState().repairCost, 300)
    mode = "pending"
    repairTest.refreshDurabilityCache()
    local state = repairTest.durabilityState()
    eq("repair.pending_all_secret_clears_prior_cost", state.repairCost, nil)
    eq("repair.pending_all_secret_marks_incomplete", state.repairCostComplete, false)
    eq("repair.pending_all_secret_uses_events", state.retryScheduled, false)
end

do
    local mode = "stale"
    local _, _, repairTest = loadStatsPro("enUS", {
        statsProDB = {
            showDurability = true,
            showRepairCost = true,
        },
        getInventoryItemDurability = function(slot)
            if slot == 1 then return 50, 100 end
            if slot == 2 then return 25, 100 end
            return nil, nil
        end,
        getTooltipInventoryItem = function(_, slot)
            if mode == "stale" then return { repairCost = 700 } end
            if slot == 1 then return { repairCost = 300 } end
            return nil
        end,
    })
    repairTest.cacheSettings()
    repairTest.refreshDurabilityCache()
    eq("repair.pending_partial.seed_cost", repairTest.durabilityState().repairCost, 1400)
    mode = "partial"
    repairTest.refreshDurabilityCache()
    local state = repairTest.durabilityState()
    eq("repair.pending_partial_hides_lower_bound", state.repairCost, nil)
    eq("repair.pending_partial_marks_incomplete", state.repairCostComplete, false)
    eq("repair.pending_partial_still_schedules_retry", state.retryScheduled, true)
    local repairBlock = findBlockBySplitKey("repair.pending_partial.block",
        repairTest.buildRenderBlocks(), "splitRepairCost")
    eq("repair.pending_partial_renders_unknown", repairBlock.repairStr, "?")
end

do
    local damaged = true
    local _, _, repairTest = loadStatsPro("enUS", {
        statsProDB = {
            showDurability = true,
            showRepairCost = true,
        },
        getInventoryItemDurability = function(slot)
            if slot == 1 then
                if damaged then return 50, 100 end
                return 100, 100
            end
            return nil, nil
        end,
        getTooltipInventoryItem = function() return { repairCost = 300 } end,
    })
    repairTest.cacheSettings()
    repairTest.refreshDurabilityCache()
    eq("repair.clean_zero.seed_cost", repairTest.durabilityState().repairCost, 300)
    damaged = false
    repairTest.refreshDurabilityCache()
    local state = repairTest.durabilityState()
    eq("repair.clean_zero_clears_prior_cost", state.repairCost, 0)
    eq("repair.clean_zero_is_complete", state.repairCostComplete, true)
    eq("repair.clean_zero_no_retry", state.retryScheduled, false)
end

do
    local mode = "pending"
    local repairEnv, _, repairTest = loadStatsPro("enUS", {
        statsProDB = { showRepairCost = true },
        getInventoryItemDurability = function(slot)
            if slot == 1 then return 50, 100 end
            return nil, nil
        end,
        getTooltipInventoryItem = function()
            if mode == "known" then return { repairCost = 300 } end
            return nil
        end,
    })
    repairTest.cacheSettings()
    repairTest.refreshDurabilityCache()
    eq("repair.stale_timer.seed_timer", #repairEnv.__timers, 1)
    mode = "known"
    fireEvent("repair.stale_timer.merchant_event", repairEnv, "MERCHANT_SHOW")
    repairTest.refreshDurabilityCache()
    local state = repairTest.durabilityState()
    eq("repair.stale_timer.complete_cost", state.repairCost, 300)
    eq("repair.stale_timer.complete_state", state.repairCostComplete, true)
    eq("repair.stale_timer.clean_before_flush", state.dirty, false)
    flushTimers("repair.stale_timer.flush_old_generation", repairEnv, 3, 1)
    state = repairTest.durabilityState()
    eq("repair.stale_timer_does_not_redirty", state.dirty, false)
    eq("repair.stale_timer_preserves_complete", state.repairCostComplete, true)
end

do
    local repairEnv, _, repairTest = loadStatsPro("enUS", {
        statsProDB = { showRepairCost = true },
        getInventoryItemDurability = function(slot)
            if slot == 1 then return 50, 100 end
            return nil, nil
        end,
        getTooltipInventoryItem = function() return { repairCost = 300 } end,
        surfaceTooltipArgs = function() error("surface failed") end,
    })
    repairTest.cacheSettings()
    local ok, err = pcall(repairTest.refreshDurabilityCache)
    check("repair.surface_failure_no_error", ok, err)
    local state = repairTest.durabilityState()
    eq("repair.surface_failure_is_unknown", state.repairCostComplete, false)
    eq("repair.surface_failure_hides_total", state.repairCost, nil)
    eq("repair.surface_failure_one_retry", #repairEnv.__timers, 1)
    flushTimers("repair.surface_failure_retry", repairEnv, 3, 1)
    repairTest.refreshDurabilityCache()
    eq("repair.surface_failure_retry_is_bounded", #repairEnv.__timers, 0)
end

do
    local r, g, b = test.normalizeColor({ r = "2", g = "-1", b = "bad" }, { r = 0.25, g = 0.5, b = 0.75 })
    near("color.normalize_fallback_and_clamp.r", r, 1)
    near("color.normalize_fallback_and_clamp.g", g, 0)
    near("color.normalize_fallback_and_clamp.b", b, 0.75)
    eq("color.rgb_to_hex_clamps_invalid_channels", test.rgbToHex(2, -1, "bad"), "ff0000")
end

do
    local function tableKeySet(value)
        local out = {}
        for key in pairs(value) do out[key] = true end
        return out
    end

    local function assertSameSet(name, expected, actual)
        for key in pairs(expected) do
            eq(name .. ".missing." .. tostring(key), actual[key], true)
        end
        for key in pairs(actual) do
            eq(name .. ".extra." .. tostring(key), expected[key], true)
        end
    end

    local registryEnv, registryAddon, registryTest = loadStatsPro("enUS")
    fireEvent("registry.config_bindings.fire", registryEnv, "PLAYER_ENTERING_WORLD")
    local ok, err = pcall(function() registryAddon:OpenConfigMenu() end)
    check("registry.config_bindings.open", ok, err)

    local defaults = registryTest.copyDefaults()
    local registry = registryTest.registrySnapshot()

    local boolDefaults = {}
    for key, value in pairs(defaults) do
        if type(value) == "boolean" then boolDefaults[key] = true end
    end

    local cachedBoolKeys = {}
    for index, key in ipairs(registry.cachedBoolKeys) do
        eq("registry.bool_cache.key_type." .. index, type(key), "string")
        check("registry.bool_cache.key_nonempty." .. index, key ~= "")
        eq("registry.bool_cache.duplicate." .. key, cachedBoolKeys[key], nil)
        cachedBoolKeys[key] = true
        eq("registry.bool_cache.default_type." .. key, type(defaults[key]), "boolean")
    end
    assertSameSet("registry.bool_defaults_cached", boolDefaults, cachedBoolKeys)

    local boolControls, numberControls, colorControls = {}, {}, {}
    for _, frame in ipairs(registryEnv.__frames) do
        local dbKey = frame.statsProDBKey
        if dbKey then
            eq("registry.config_binding.key_type", type(dbKey), "string")
            check("registry.config_binding.key_nonempty", dbKey ~= "")
            local expectedType = frame.statsProDBType
            check("registry.config_binding.expected_type." .. dbKey,
                expectedType == "boolean" or expectedType == "number")
            eq("registry.config_binding.default_type." .. dbKey,
                type(defaults[dbKey]), expectedType)
            if expectedType == "boolean" then
                eq("registry.bool_controls.duplicate." .. dbKey,
                    boolControls[dbKey], nil)
                boolControls[dbKey] = true
            else
                eq("registry.number_controls.duplicate." .. dbKey,
                    numberControls[dbKey], nil)
                numberControls[dbKey] = true
            end
        end

        local colorKey = frame.statsProColorKey
        if colorKey then
            eq("registry.color_binding.key_type", type(colorKey), "string")
            check("registry.color_binding.key_nonempty", colorKey ~= "")
            eq("registry.color_controls.duplicate." .. colorKey,
                colorControls[colorKey], nil)
            colorControls[colorKey] = true
        end
    end
    assertSameSet("registry.bool_cached_controls", cachedBoolKeys, boolControls)

    local numberMetaKeys = tableKeySet(registry.numberSettingMeta)
    assertSameSet("registry.number_meta_sliders", numberMetaKeys, numberControls)
    for key, meta in pairs(registry.numberSettingMeta) do
        eq("registry.number_meta.default_type." .. key, type(defaults[key]), "number")
        eq("registry.number_meta.entry_type." .. key, type(meta), "table")
        check("registry.number_meta.min_finite." .. key, isFiniteNumber(meta.min))
        check("registry.number_meta.max_finite." .. key, isFiniteNumber(meta.max))
        check("registry.number_meta.step_finite." .. key, isFiniteNumber(meta.step))
        check("registry.number_meta.range_order." .. key, meta.min <= meta.max)
        check("registry.number_meta.default_in_range." .. key,
            defaults[key] >= meta.min and defaults[key] <= meta.max)
        check("registry.number_meta.step_positive." .. key, meta.step > 0)
    end

    local stringControls = {
        StatsProDisplayModeDropdown = "displayMode",
        StatsProTargetSnapshotDropdown = "targetSnapshot",
        StatsProLabelStyleDropdown = "labelStyle",
        StatsProTextOutlineDropdown = "textOutlineStyle",
        StatsProFontDropdown = "font",
        StatsProLanguageDropdown = "forceLocale",
    }
    for frameName, dbKey in pairs(stringControls) do
        exists("registry.string_control.exists." .. frameName, registryEnv[frameName])
        eq("registry.string_control.default_type." .. dbKey, type(defaults[dbKey]), "string")
    end

    local optionValues, explicitLocales = {}, {}
    local autoCount = 0
    for index, option in ipairs(registry.languageOptions) do
        eq("registry.locale_option.entry_type." .. index, type(option), "table")
        eq("registry.locale_option.value_type." .. index, type(option.value), "string")
        check("registry.locale_option.value_nonempty." .. index, option.value ~= "")
        eq("registry.locale_option.duplicate." .. option.value, optionValues[option.value], nil)
        optionValues[option.value] = true
        if option.value == "auto" then
            autoCount = autoCount + 1
            eq("registry.locale_option.auto_label", option.label, nil)
        else
            explicitLocales[option.value] = true
            eq("registry.locale_option.label_type." .. option.value,
                type(option.label), "string")
            check("registry.locale_option.label_nonempty." .. option.value,
                option.label ~= "")
        end
    end
    eq("registry.locale_option.one_auto", autoCount, 1)
    eq("registry.locale_option.auto_first", registry.languageOptions[1].value, "auto")
    assertSameSet("registry.locale_options_labels",
        explicitLocales, tableKeySet(registry.labelsByLocale))
    assertSameSet("registry.locale_options_glyphs",
        explicitLocales, tableKeySet(registry.localeGlyphReq))

    local englishLabels = registry.labelsByLocale.enUS
    eq("registry.locale_keys.enUS_table", type(englishLabels), "table")
    local englishKeySet = tableKeySet(englishLabels)
    for locale in pairs(explicitLocales) do
        local labels = registry.labelsByLocale[locale]
        eq("registry.locale_keys.table_type." .. locale, type(labels), "table")
        assertSameSet("registry.locale_keys." .. locale,
            englishKeySet, tableKeySet(labels))
        eq("registry.locale_glyph.type." .. locale,
            type(registry.localeGlyphReq[locale]), "string")
        check("registry.locale_glyph.nonempty." .. locale,
            registry.localeGlyphReq[locale] ~= "")
        for key, value in pairs(labels) do
            eq("registry.locale_value.type." .. locale .. "." .. key,
                type(value), "string")
            check("registry.locale_value.nonempty." .. locale .. "." .. key,
                value ~= "")
        end
    end

    eq("registry.colors.defaults_type", type(defaults.colors), "table")
    assertSameSet("registry.color_defaults_swatches",
        tableKeySet(defaults.colors), colorControls)
    local expectedChannels = { r = true, g = true, b = true }
    for colorKey, color in pairs(defaults.colors) do
        eq("registry.color.entry_type." .. colorKey, type(color), "table")
        assertSameSet("registry.color.channels." .. colorKey,
            expectedChannels, tableKeySet(color))
        for channel in pairs(expectedChannels) do
            local value = color[channel]
            check("registry.color.channel_finite." .. colorKey .. "." .. channel,
                isFiniteNumber(value))
            check("registry.color.channel_range." .. colorKey .. "." .. channel,
                value >= 0 and value <= 1)
        end
    end
end

do
    local badDisplayEnv, badDisplayAddon = loadStatsPro("enUS", {
        statsProDB = { displayMode = "sideways" },
    })
    fireEvent("config.invalid_display_mode_recovers.fire", badDisplayEnv, "PLAYER_ENTERING_WORLD")
    slash("config.invalid_display_mode_recovers.dump", badDisplayEnv, "debug bucket")
    eq("config.invalid_display_mode_recovers.cache_mode", printContains(badDisplayEnv, "bucket: mode=flat"), true)

    local ok, err = pcall(function() badDisplayAddon:OpenConfigMenu() end)
    check("config.invalid_display_mode_recovers.open", ok, err)
    eq("config.invalid_display_mode_recovers.caption", badDisplayEnv.StatsProDisplayModeDropdown.dropdownText, "Flat")
    local displayEntries = runDropdownInit("config.invalid_display_mode_recovers.dropdown", badDisplayEnv.StatsProDisplayModeDropdown)
    eq("config.invalid_display_mode_recovers.checked", checkedDropdownValue("config.invalid_display_mode_recovers", displayEntries), "flat")
    eq("config.invalid_display_mode_recovers.split_check_disabled", badDisplayEnv.StatsProSplitOffensiveCheck:IsEnabled(), false)
    eq("config.invalid_display_mode_recovers.db_unchanged", badDisplayEnv.StatsProDB.displayMode, "sideways")
end

do
    local badLocaleEnv, badLocaleAddon, badLocaleTest = loadStatsPro("deDE", {
        statsProDB = { forceLocale = "xxYY" },
    })
    fireEvent("config.invalid_force_locale_recovers.fire", badLocaleEnv, "PLAYER_ENTERING_WORLD")
    eq("config.invalid_force_locale_recovers.label", badLocaleTest.getStyledLabelText("ItemLevel", "full"), "GS:")
    eq("config.invalid_force_locale_recovers.db_unchanged", badLocaleEnv.StatsProDB.forceLocale, "xxYY")

    local ok, err = pcall(function() badLocaleAddon:OpenConfigMenu() end)
    check("config.invalid_force_locale_recovers.open", ok, err)
    eq("config.invalid_force_locale_recovers.caption", badLocaleEnv.StatsProLanguageDropdown.dropdownText, "Deutsch")
    local languageEntries = runDropdownInit("config.invalid_force_locale_recovers.dropdown", badLocaleEnv.StatsProLanguageDropdown)
    eq("config.invalid_force_locale_recovers.checked", checkedDropdownValue("config.invalid_force_locale_recovers", languageEntries), "auto")
    eq("config.invalid_force_locale_recovers.db_after_open", badLocaleEnv.StatsProDB.forceLocale, "xxYY")
end

do
    local function assertLanguageCaption(name, clientLocale, forceLocale, expected)
        local localeEnv, localeAddon = loadStatsPro(clientLocale, {
            statsProDB = { forceLocale = forceLocale },
        })
        fireEvent(name .. ".fire", localeEnv, "PLAYER_ENTERING_WORLD")
        local ok, err = pcall(function() localeAddon:OpenConfigMenu() end)
        check(name .. ".open", ok, err)
        eq(name .. ".caption", localeEnv.StatsProLanguageDropdown.dropdownText, expected)
        return localeEnv
    end

    assertLanguageCaption("config.language_compact.esES_explicit", "enUS", "esES", "Español ES")
    assertLanguageCaption("config.language_compact.esMX_explicit", "enUS", "esMX", "Español MX")
    assertLanguageCaption("config.language_compact.esMX_auto_current", "esMX", "auto", "Español MX")
    assertLanguageCaption("config.language_compact.koKR_forced_fallback", "enUS", "koKR", "한국어 / Korean")
    assertLanguageCaption("config.language_compact.zhCN_forced_fallback", "enUS", "zhCN", "中文 / Simpl.")
    assertLanguageCaption("config.language_compact.zhTW_forced_fallback", "enUS", "zhTW", "中文 / Trad.")
end

do
    local function assertLocalizedCheckboxGuards(locale)
        local guardEnv, guardAddon = loadStatsPro("enUS", {
            statsProDB = { forceLocale = locale },
        })
        fireEvent("config.checkbox_label_guard." .. locale .. ".fire", guardEnv, "PLAYER_ENTERING_WORLD")
        local ok, err = pcall(function() guardAddon:OpenConfigMenu() end)
        check("config.checkbox_label_guard." .. locale .. ".open", ok, err)
        for _, name in ipairs({
            "StatsProOffensiveCheckText",
            "StatsProCritCheckText",
            "StatsProHideZeroOffCheckText",
            "StatsProDefensiveCheckText",
            "StatsProStaggerCheckText",
            "StatsProWorstDurCheckText",
        }) do
            local label = exists("config.checkbox_label_guard." .. locale .. "." .. name, guardEnv[name])
            eq("config.checkbox_label_guard." .. locale .. "." .. name .. ".word_wrap", label.wordWrap, false)
            eq("config.checkbox_label_guard." .. locale .. "." .. name .. ".max_lines", label.maxLines, 1)
        end
        for _, name in ipairs({
            "StatsProCritCheckText",
            "StatsProStaggerCheckText",
        }) do
            local label = exists("config.checkbox_label_guard." .. locale .. "." .. name .. ".width", guardEnv[name])
            check("config.checkbox_label_guard." .. locale .. "." .. name .. ".width_cap",
                label.width <= 160,
                "color checkbox label width exceeds cap")
        end
    end

    assertLocalizedCheckboxGuards("ruRU")
    assertLocalizedCheckboxGuards("deDE")
    assertLocalizedCheckboxGuards("frFR")
end

do
    local enGBEnv, enGBAddon, enGBTest = loadStatsPro("enGB", {
        statsProDB = {
            forceLocale = "auto",
            showOffensive = true,
            hideZeroOffensive = false,
            showCrit = true,
            showHaste = false,
            showMastery = false,
            showVersatility = false,
            showTertiary = false,
            showDefensive = false,
        },
        getCritChance = function() return 12 end,
    })
    fireEvent("config.language_enGB_uses_english.fire", enGBEnv, "PLAYER_ENTERING_WORLD")
    local blocks = enGBTest.buildRenderBlocks()
    eq("config.language_enGB_uses_english.hud_label", blockDumpContains(blocks, "Crit:"), true)
    eq("config.language_enGB_uses_english.snapshot_date",
        enGBTest.formatSnapshotDate("2026-05-15"), "15-May-26")

    local ok, err = pcall(function() enGBAddon:OpenConfigMenu() end)
    check("config.language_enGB_uses_english.open", ok, err)
    eq("config.language_enGB_uses_english.auto_caption",
        enGBEnv.StatsProLanguageDropdown.dropdownText, "English")
    local entries = runDropdownInit("config.language_enGB_uses_english.dropdown",
        enGBEnv.StatsProLanguageDropdown)
    eq("config.language_enGB_uses_english.checked", checkedDropdownValue(
        "config.language_enGB_uses_english", entries), "auto")

    local autoCount, englishCount, enGBCount = 0, 0, 0
    local autoText, englishText
    for _, entry in ipairs(entries) do
        if entry.value == "auto" then
            autoCount = autoCount + 1
            autoText = entry.text
        end
        if entry.value == "enUS" then
            englishCount = englishCount + 1
            englishText = entry.text
        end
        if entry.value == "enGB" then enGBCount = enGBCount + 1 end
    end
    eq("config.language_enGB_uses_english.menu_size", #entries, 12)
    eq("config.language_enGB_uses_english.one_auto_option", autoCount, 1)
    eq("config.language_enGB_uses_english.auto_menu_text", autoText, "Auto (current: English)")
    eq("config.language_enGB_uses_english.one_english_option", englishCount, 1)
    eq("config.language_enGB_uses_english.english_option_text", englishText, "English")
    eq("config.language_enGB_uses_english.no_duplicate_enGB_option", enGBCount, 0)
    eq("config.language_enGB_uses_english.db_stays_auto", enGBEnv.StatsProDB.forceLocale, "auto")
    clearPrints(enGBEnv)
    slash("config.language_enGB_uses_english.debug", enGBEnv, "debug")
    eq("config.language_enGB_uses_english.debug_active",
        printContains(enGBEnv, "locale: client=enGB force=auto active=enUS"), true)
end

do
    local invalidEnv, invalidAddon = loadStatsPro("deDE", {
        statsProDB = { forceLocale = "enGB" },
    })
    fireEvent("config.language_enGB_not_accepted_as_explicit.fire", invalidEnv,
        "PLAYER_ENTERING_WORLD")
    local ok, err = pcall(function() invalidAddon:OpenConfigMenu() end)
    check("config.language_enGB_not_accepted_as_explicit.open", ok, err)
    eq("config.language_enGB_not_accepted_as_explicit.caption",
        invalidEnv.StatsProLanguageDropdown.dropdownText, "Deutsch")
    local entries = runDropdownInit("config.language_enGB_not_accepted_as_explicit.dropdown",
        invalidEnv.StatsProLanguageDropdown)
    eq("config.language_enGB_not_accepted_as_explicit.checked", checkedDropdownValue(
        "config.language_enGB_not_accepted_as_explicit", entries), "auto")
    eq("config.language_enGB_not_accepted_as_explicit.db_unchanged",
        invalidEnv.StatsProDB.forceLocale, "enGB")
end

do
    local warningEnv, warningAddon, warningTest = loadStatsPro("enUS", {
        statsProDB = {
            forceLocale = "koKR",
            font = "Fonts\\FRIZQT__.TTF",
        },
    })
    warningTest.cacheSettings()
    local ok, err = pcall(function() warningAddon:OpenConfigMenu() end)
    check("config.language_warning_layout.open", ok, err)

    local config = exists("config.language_warning_layout.frame", warningEnv.StatsProConfigFrame)
    local warning = exists("config.language_warning_layout.warning", config.languageWarning)
    local appearance = exists("config.language_warning_layout.appearance", config.appearanceTab)
    local scroll = exists("config.language_warning_layout.scroll", warningEnv.StatsProConfigScroll)
    local scrollChild = exists("config.language_warning_layout.scroll_child", scroll.scrollChild)
    config.SwitchToTab(3)

    check("config.language_warning_layout.text_visible", warning:GetText() ~= "", "missing warning text")
    eq("config.language_warning_layout.word_wrap", warning.wordWrap, true)
    eq("config.language_warning_layout.max_lines", warning.maxLines, 2)
    eq("config.language_warning_layout.two_line_height", warning:GetHeight(), 28)
    eq("config.language_warning_layout.scroll_child_width", scrollChild:GetWidth(), 450)
    eq("config.language_warning_layout.practical_width", warning:GetWidth(), 426)
    check("config.language_warning_layout.fits_content",
        warning:GetWidth() <= scrollChild:GetWidth() - 24,
        "warning exceeds padded scroll content")
    check("config.language_warning_layout.replaces_oversized_width",
        warning:GetWidth() < 470,
        "warning kept oversized legacy width")

    local warningPoint = exists("config.language_warning_layout.point", warning.points[1])
    eq("config.language_warning_layout.point_x", warningPoint[2], 12)
    local warningTopY = warningPoint[3]
    check("config.language_warning_layout.bottom_inside_content",
        appearance.contentHeight >= -warningTopY + warning:GetHeight() + 12,
        "appearance content clips warning bottom")
    eq("config.language_warning_layout.active_scroll_height",
        scrollChild:GetHeight(), appearance.contentHeight)

    local widthBefore, heightBefore, contentBefore =
        warning:GetWidth(), warning:GetHeight(), appearance.contentHeight
    warningAddon:OpenConfigMenu()
    warningAddon:OpenConfigMenu()
    config.SwitchToTab(3)
    eq("config.language_warning_layout.reopen_width", warning:GetWidth(), widthBefore)
    eq("config.language_warning_layout.reopen_height", warning:GetHeight(), heightBefore)
    eq("config.language_warning_layout.reopen_content", appearance.contentHeight, contentBefore)
end

do
    runCache(runMigrate({ forceLocale = "auto" }))

    local ok, err = pcall(function() addon:OpenConfigMenu() end)
    check("config.open_constructs_frame", ok, err)

    exists("config.frame_registered.frame", env.StatsProConfigFrame)
    eq("config.frame_strata.dialog", env.StatsProConfigFrame:GetFrameStrata(), "DIALOG")
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
        "StatsProTargetSnapshotDropdown",
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
    runDropdownInit("config.dropdown_initializers.target_snapshot", env.StatsProTargetSnapshotDropdown)
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
        eq("config.language_hover_restore.ru_snapshot_month_preview", test.formatSnapshotDate("2026-05-15"), "15-май-26")

        test.setPanelAppliedStyleForSmoke(defaultFont, 14)
        ok, err = pcall(enEnter, env.DropDownList1Button2)
        check("config.language_hover_restore.preview_en", ok, err)
        local afterEnPreview = test.panelFontState()
        eq("config.language_hover_restore.forces_main_font", afterEnPreview.mainLabelFont, defaultFont)
        eq("config.language_hover_restore.forces_side_font", afterEnPreview.sideLabelFont, defaultFont)
        eq("config.language_hover_restore.en_snapshot_month_preview", test.formatSnapshotDate("2026-05-15"), "15-May-26")

        env.DropDownList1:Hide()
        env.UIDROPDOWNMENU_OPEN_MENU = nil
    end

    selectDropdownValue("config.dropdown_display_mode_split_writes_db", env.StatsProDisplayModeDropdown, "split")
    eq("config.dropdown_display_mode_split_writes_db.value", env.StatsProDB.displayMode, "split")
    eq("config.dropdown_display_mode_split_writes_db.split_check_enabled",
        env.StatsProSplitOffensiveCheck:IsEnabled(), true)

    selectDropdownValue("config.dropdown_target_snapshot_raid_writes_db", env.StatsProTargetSnapshotDropdown, "raid")
    eq("config.dropdown_target_snapshot_raid_writes_db.value", env.StatsProDB.targetSnapshot, "raid")
    eq("config.dropdown_target_snapshot_raid_writes_db.cache", test.cachedTargetSnapshot(), "raid")

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

    for _, name in ipairs({
        "StatsProOffensiveCheckText",
        "StatsProCritCheckText",
        "StatsProHideZeroOffCheckText",
        "StatsProTertiaryCheckText",
        "StatsProDefensiveCheckText",
        "StatsProStaggerCheckText",
        "StatsProWorstDurCheckText",
    }) do
        local label = exists("config.checkbox_label_guard.enUS." .. name, env[name])
        eq("config.checkbox_label_guard.enUS." .. name .. ".word_wrap", label.wordWrap, false)
        eq("config.checkbox_label_guard.enUS." .. name .. ".max_lines", label.maxLines, 1)
    end

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
    eq("config.font_picker_strata.dialog", env.StatsProFontPicker:GetFrameStrata(), "DIALOG")
    check("config.font_picker_level_above_config",
        env.StatsProFontPicker:GetFrameLevel() > env.StatsProConfigFrame:GetFrameLevel(),
        "font picker should stay above config frame")
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
    env.__setColorPickerRGB(0.4, 0.5, 0.6)
    ok, err = pcall(env.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.reset_closes_picker.preview", ok, err)
    assertColor("config.color_picker.reset_closes_picker.preview_db",
        env.StatsProDB.colors.crit, 0.4, 0.5, 0.6)
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
    local rawHideEnv = loadStatsPro("enUS", {
        statsProDB = { colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } } },
    })
    fireEvent("config.color_picker.raw_hide.fire", rawHideEnv, "PLAYER_ENTERING_WORLD")
    slash("config.color_picker.raw_hide.open_config", rawHideEnv, "")
    local critSwatch = findFrame("config.color_picker.raw_hide.crit_swatch", rawHideEnv, function(frame)
        local color = frame.backdropColor
        return type(frame.scripts.OnClick) == "function"
            and color and color.r == 0.2 and color.g == 0.3 and color.b == 0.4
    end)
    callScript("config.color_picker.raw_hide.open_picker", critSwatch, "OnClick")
    rawHideEnv.__setColorPickerRGB(0.6, 0.7, 0.8)
    local options = rawHideEnv.ColorPickerFrame.colorPickerOptions
    local ok, err = pcall(options.swatchFunc)
    check("config.color_picker.raw_hide.preview", ok, err)
    rawHideEnv.ColorPickerFrame:Hide()
    assertColor("config.color_picker.raw_hide_restores_snapshot.crit",
        rawHideEnv.StatsProDB.colors.crit, 0.2, 0.3, 0.4)
    ok, err = pcall(options.swatchFunc)
    check("config.color_picker.raw_hide.stale_callback_call", ok, err)
    assertColor("config.color_picker.raw_hide.stale_callback_noop.crit",
        rawHideEnv.StatsProDB.colors.crit, 0.2, 0.3, 0.4)

    rawHideEnv.StatsProDB.colors.crit = nil
    callScript("config.color_picker.raw_hide_default.open_picker", critSwatch, "OnClick")
    rawHideEnv.__setColorPickerRGB(0.7, 0.8, 0.9)
    ok, err = pcall(rawHideEnv.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.raw_hide_default.preview", ok, err)
    rawHideEnv.ColorPickerFrame:Hide()
    eq("config.color_picker.raw_hide_default_restores_nil", rawHideEnv.StatsProDB.colors.crit, nil)
end

do
    local fallbackEnv = loadStatsPro("enUS", {
        statsProDB = { colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } } },
    })
    fireEvent("config.color_picker.accept_boundary_fallback.fire", fallbackEnv, "PLAYER_ENTERING_WORLD")
    slash("config.color_picker.accept_boundary_fallback.open_config", fallbackEnv, "")
    local critSwatch = findFrame("config.color_picker.accept_boundary_fallback.crit_swatch", fallbackEnv, function(frame)
        local color = frame.backdropColor
        return type(frame.scripts.OnClick) == "function"
            and color and color.r == 0.2 and color.g == 0.3 and color.b == 0.4
    end)
    fallbackEnv.ColorPickerFrame.Footer.OkayButton = nil
    callScript("config.color_picker.accept_boundary_fallback.open_picker", critSwatch, "OnClick")
    fallbackEnv.__setColorPickerRGB(0.6, 0.7, 0.8)
    local options = fallbackEnv.ColorPickerFrame.colorPickerOptions
    local ok, err = pcall(options.swatchFunc)
    check("config.color_picker.accept_boundary_fallback.preview", ok, err)
    -- Model Blizzard OK when PreClick is unavailable: final swatchFunc, then Hide.
    ok, err = pcall(options.swatchFunc)
    check("config.color_picker.accept_boundary_fallback.ok_swatch", ok, err)
    fallbackEnv.ColorPickerFrame:Hide()
    assertColor("config.color_picker.accept_boundary_fallback.preserves_ok_commit",
        fallbackEnv.StatsProDB.colors.crit, 0.6, 0.7, 0.8)
end

do
    local takeoverEnv = loadStatsPro("enUS", {
        statsProDB = { colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } } },
    })
    fireEvent("config.color_picker.takeover.fire", takeoverEnv, "PLAYER_ENTERING_WORLD")
    slash("config.color_picker.takeover.open_config", takeoverEnv, "")
    local critSwatch = findFrame("config.color_picker.takeover.crit_swatch", takeoverEnv, function(frame)
        local color = frame.backdropColor
        return type(frame.scripts.OnClick) == "function"
            and color and color.r == 0.2 and color.g == 0.3 and color.b == 0.4
    end)
    callScript("config.color_picker.takeover.open_statspro", critSwatch, "OnClick")
    takeoverEnv.__setColorPickerRGB(0.6, 0.7, 0.8)
    local ok, err = pcall(takeoverEnv.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.takeover.preview", ok, err)

    local foreignToken = {}
    local foreignAccepted, foreignCanceled = 0, false
    takeoverEnv.ColorPickerFrame:SetupColorPickerAndShow({
        r = 0.1, g = 0.2, b = 0.3,
        extraInfo = foreignToken,
        swatchFunc = function() foreignAccepted = foreignAccepted + 1 end,
        cancelFunc = function() foreignCanceled = true end,
    })
    foreignAccepted = 0
    assertColor("config.color_picker.takeover_immediate_restores_statspro.crit",
        takeoverEnv.StatsProDB.colors.crit, 0.2, 0.3, 0.4)
    eq("config.color_picker.takeover_immediate.foreign_stays_open",
        takeoverEnv.ColorPickerFrame:IsShown(), true)
    takeoverEnv.__acceptColorPicker()
    eq("config.color_picker.takeover.foreign_accept_called", foreignAccepted, 1)
    eq("config.color_picker.takeover.foreign_not_canceled", foreignCanceled, false)
    assertColor("config.color_picker.takeover_foreign_hide_restores_statspro.crit",
        takeoverEnv.StatsProDB.colors.crit, 0.2, 0.3, 0.4)

    callScript("config.color_picker.takeover_config_hide.open_statspro", critSwatch, "OnClick")
    takeoverEnv.__setColorPickerRGB(0.7, 0.8, 0.9)
    ok, err = pcall(takeoverEnv.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.takeover_config_hide.preview", ok, err)
    foreignCanceled = false
    -- Model a takeover that bypasses SetupColorPickerAndShow and leaves the old token
    -- behind. Callback identity must still prevent hiding/canceling the foreign UI.
    takeoverEnv.ColorPickerFrame.swatchFunc = function() end
    takeoverEnv.ColorPickerFrame.cancelFunc = function() foreignCanceled = true end
    takeoverEnv.StatsProConfigFrame:Hide()
    eq("config.color_picker.takeover_config_hide.foreign_stays_open",
        takeoverEnv.ColorPickerFrame:IsShown(), true)
    eq("config.color_picker.takeover_config_hide.foreign_not_canceled", foreignCanceled, false)
    assertColor("config.color_picker.takeover_config_hide.restores_statspro.crit",
        takeoverEnv.StatsProDB.colors.crit, 0.2, 0.3, 0.4)
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
    local oldCritOptions = colorEnv.ColorPickerFrame.colorPickerOptions
    local ok, err = pcall(oldCritOptions.swatchFunc)
    check("config.color_picker.switch_swatch.preview_crit", ok, err)
    callScript("config.color_picker.switch_swatch.open_haste", hasteSwatch, "OnClick")
    eq("config.color_picker.switch_swatch_cancels_previous_preview.crit", colorEnv.StatsProDB.colors.crit, nil)
    eq("config.color_picker.switch_swatch_cancels_previous_preview.shown", colorEnv.ColorPickerFrame:IsShown(), true)
    colorEnv.__setColorPickerRGB(0.6, 0.7, 0.8)
    ok, err = pcall(colorEnv.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.switch_swatch.preview_haste", ok, err)
    ok, err = pcall(oldCritOptions.swatchFunc)
    check("config.color_picker.switch_swatch.stale_swatch_call", ok, err)
    ok, err = pcall(oldCritOptions.cancelFunc, oldCritOptions)
    check("config.color_picker.switch_swatch.stale_cancel_call", ok, err)
    eq("config.color_picker.switch_swatch.stale_callbacks_keep_crit_nil", colorEnv.StatsProDB.colors.crit, nil)
    assertColor("config.color_picker.switch_swatch.stale_callbacks_keep_haste_preview",
        colorEnv.StatsProDB.colors.haste, 0.6, 0.7, 0.8)
end

do
    local foreignEnv = loadStatsPro("enUS")
    fireEvent("config.color_picker.foreign.fire", foreignEnv, "PLAYER_ENTERING_WORLD")
    slash("config.color_picker.foreign.open_config", foreignEnv, "")
    local critSwatch = findFrame("config.color_picker.foreign.crit_swatch", foreignEnv, function(frame)
        local color = frame.backdropColor
        return type(frame.scripts.OnClick) == "function"
            and color and color.r == 1 and color.g == 0 and color.b == 0
    end)
    local canceled = false
    local foreignToken = {}
    foreignEnv.ColorPickerFrame:SetupColorPickerAndShow({
        r = 0.1, g = 0.2, b = 0.3,
        extraInfo = foreignToken,
        cancelFunc = function() canceled = true end,
    })
    callScript("config.color_picker.foreign.open_statspro_swatch_noop", critSwatch, "OnClick")
    eq("config.color_picker.foreign.open_statspro_preserves_owner",
        foreignEnv.ColorPickerFrame:GetExtraInfo(), foreignToken)
    eq("config.color_picker.foreign.open_statspro_preserves_picker",
        foreignEnv.ColorPickerFrame:IsShown(), true)
    eq("config.color_picker.foreign.open_statspro_does_not_cancel", canceled, false)
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
