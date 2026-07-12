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

local function deepEqual(actual, expected, seen)
    if rawequal(actual, expected) then return true end
    if type(actual) ~= type(expected) or type(actual) ~= "table" then return false end
    seen = seen or {}
    seen[actual] = seen[actual] or {}
    if seen[actual][expected] then return true end
    seen[actual][expected] = true
    for key, value in pairs(actual) do
        if not deepEqual(value, expected[key], seen) then return false end
    end
    for key in pairs(expected) do
        if actual[key] == nil then return false end
    end
    return true
end

local function assertDeepEqual(name, actual, expected)
    check(name, deepEqual(actual, expected), "tables differ")
end

local function collectTableIdentities(value, identities, visited)
    if type(value) ~= "table" then return end
    identities[value] = true
    visited = visited or {}
    if visited[value] then return end
    visited[value] = true
    for key, child in pairs(value) do
        collectTableIdentities(key, identities, visited)
        collectTableIdentities(child, identities, visited)
    end
end

local function assertNoSharedTables(name, left, right)
    local leftIdentities = {}
    collectTableIdentities(left, leftIdentities)
    local visited = {}
    local function inspect(value)
        if type(value) ~= "table" or visited[value] then return end
        visited[value] = true
        check(name, leftIdentities[value] ~= true, "shared nested table")
        for key, child in pairs(value) do inspect(key); inspect(child) end
    end
    inspect(right)
end

local function dbRoot(value)
    if type(value) == "table" and type(value.StatsProDB) == "table" then
        return value.StatsProDB
    end
    return value
end

local function accountSettings(value)
    local root = dbRoot(value)
    if type(root) == "table" and type(root.account) == "table" then
        return root.account
    end
    return root
end

local function activeSettings(value)
    local root = dbRoot(value)
    local account = type(root) == "table" and root.account or nil
    local profiles = type(root) == "table" and root.profiles or nil
    local profileID = type(account) == "table" and account.defaultProfileID or nil
    local profile = type(profiles) == "table" and profiles[profileID] or nil
    if type(profile) == "table" and type(profile.settings) == "table" then
        return profile.settings
    end
    return root
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

-- Approximate rendered width without treating every UTF-8 byte as a glyph. Latin and
-- Cyrillic count as one unit; CJK/Hangul/emoji count as two, matching WoW font behavior
-- closely enough for overlap guards without pretending this harness is a layout engine.
local function utf8VisualUnits(text)
    local units, index, length = 0, 1, #(text or "")
    while index <= length do
        local b1 = string.byte(text, index)
        local codepoint, charLength = b1, 1
        if b1 >= 0xC2 and b1 <= 0xDF then
            local b2 = string.byte(text, index + 1)
            if b2 then
                codepoint = (b1 - 0xC0) * 0x40 + (b2 - 0x80)
                charLength = 2
            end
        elseif b1 >= 0xE0 and b1 <= 0xEF then
            local b2, b3 = string.byte(text, index + 1), string.byte(text, index + 2)
            if b2 and b3 then
                codepoint = (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80)
                charLength = 3
            end
        elseif b1 >= 0xF0 and b1 <= 0xF4 then
            local b2, b3, b4 = string.byte(text, index + 1), string.byte(text, index + 2),
                string.byte(text, index + 3)
            if b2 and b3 and b4 then
                codepoint = (b1 - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000
                    + (b3 - 0x80) * 0x40 + (b4 - 0x80)
                charLength = 4
            end
        end
        local wide = (codepoint >= 0x1100 and codepoint <= 0x11FF)
            or (codepoint >= 0x2E80 and codepoint <= 0x9FFF)
            or (codepoint >= 0xAC00 and codepoint <= 0xD7AF)
            or (codepoint >= 0xF900 and codepoint <= 0xFAFF)
            or codepoint >= 0x1F000
        units = units + (wide and 2 or 1)
        index = index + charLength
    end
    return units
end

local function makeFrame(name, setFontResult, parent)
    local frame = {
        name = name,
        parent = parent,
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
    function frame:SetMovable(value) self.movable = value ~= false end
    function frame:IsMovable() return self.movable == true end
    function frame:EnableMouse(value) self.mouseEnabled = value ~= false end
    function frame:IsMouseEnabled() return self.mouseEnabled == true end
    function frame:SetClampedToScreen(value) self.clamped = value ~= false end
    function frame:IsClampedToScreen() return self.clamped == true end
    function frame:SetToplevel(value) self.toplevel = value ~= false end
    function frame:SetBackdrop(backdrop) self.backdrop = backdrop end
    function frame:SetBackdropColor(r, g, b, a) self.backdropColor = { r = r, g = g, b = b, a = a } end
    function frame:SetBackdropBorderColor(r, g, b, a) self.backdropBorderColor = { r = r, g = g, b = b, a = a } end
    function frame:SetColorTexture(r, g, b, a) self.colorTexture = { r = r, g = g, b = b, a = a } end
    function frame:SetVertexColor(r, g, b, a) self.vertexColor = { r = r, g = g, b = b, a = a } end
    function frame:SetDesaturated(value) self.desaturated = value ~= false end
    function frame:SetBlendMode(mode) self.blendMode = mode end
    function frame:SetTexture(texture) self.texture = texture end
    function frame:SetFont(font, size, flags)
        if type(font) ~= "string" then error("SetFont font must be a string", 2) end
        if not isFiniteNumber(size) then error("SetFont size must be a finite number", 2) end
        if self.setFontResult and self.setFontResult(self, font, size, flags) ~= true then
            return false
        end
        self.font, self.fontSize, self.fontFlags = font, size, flags
        return true
    end
    function frame:SetJustifyH(value) self.justifyH = value end
    function frame:SetJustifyV(value) self.justifyV = value end
    function frame:SetTextColor(r, g, b, a) self.textColor = { r = r, g = g, b = b, a = a } end
    function frame:SetFontString(fontString) self.fontString = fontString end
    function frame:GetFontString() return self.fontString end
    function frame:SetText(text)
        self.text = text or ""
        if self.fontString and self.fontString ~= self then self.fontString:SetText(self.text) end
    end
    function frame:GetText()
        if self.fontString and self.fontString ~= self then return self.fontString:GetText() end
        return self.text
    end
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
    function frame:GetAlpha() return self.alpha or 1 end
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
    function frame:IsVisible()
        if not self.shown then return false end
        if self.parent and type(self.parent.IsVisible) == "function" then
            return self.parent:IsVisible()
        end
        return true
    end
    function frame:GetParent() return self.parent end
    function frame:Enable()
        self.enabled = true
        runFrameHandlers(self, "OnEnable")
    end
    function frame:Disable()
        self.enabled = false
        runFrameHandlers(self, "OnDisable")
    end
    function frame:IsEnabled() return self.enabled end
    function frame:RegisterForDrag(...) self.dragButtons = { ... } end
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
    function frame:SetAllPoints(target) self.allPointsTarget = target end
    function frame:SetScrollChild(child) self.scrollChild = child end
    function frame:SetVerticalScroll(value) self.verticalScroll = value or 0 end
    function frame:GetVerticalScroll() return self.verticalScroll end
    function frame:GetVerticalScrollRange() return 0 end
    function frame:SetNormalFontObject() end
    function frame:SetHighlightFontObject() end
    function frame:SetNormalTexture(texture)
        self.normalTexture = type(texture) == "table" and texture
            or self.normalTexture or makeFrame(nil, self.setFontResult, self)
        if type(texture) == "string" then self.normalTexture.texture = texture end
    end
    function frame:GetNormalTexture() return self.normalTexture end
    function frame:SetHighlightTexture(texture)
        self.highlightTexture = type(texture) == "table" and texture
            or self.highlightTexture or makeFrame(nil, self.setFontResult, self)
        if type(texture) == "string" then self.highlightTexture.texture = texture end
    end
    function frame:GetHighlightTexture()
        self.highlightTexture = self.highlightTexture or makeFrame(nil, self.setFontResult, self)
        return self.highlightTexture
    end
    function frame:SetPushedTexture(texture)
        self.pushedTexture = type(texture) == "table" and texture
            or self.pushedTexture or makeFrame(nil, self.setFontResult, self)
        if type(texture) == "string" then self.pushedTexture.texture = texture end
    end
    function frame:GetPushedTexture() return self.pushedTexture end
    function frame:SetDisabledTexture(texture)
        self.disabledTexture = type(texture) == "table" and texture
            or self.disabledTexture or makeFrame(nil, self.setFontResult, self)
        if type(texture) == "string" then self.disabledTexture.texture = texture end
    end
    function frame:GetDisabledTexture() return self.disabledTexture end
    function frame:GetCheckedTexture() return self.checkedTexture end
    function frame:GetDisabledCheckedTexture() return self.disabledCheckedTexture end
    function frame:GetThumbTexture() return self.thumbTexture end
    function frame:SetChecked(value) self.checked = value end
    function frame:GetChecked() return self.checked end
    function frame:GetName() return self.name end
    function frame:StartMoving()
        self.startMovingCalls = (self.startMovingCalls or 0) + 1
        self.moving = true
    end
    function frame:StopMovingOrSizing()
        self.stopMovingCalls = (self.stopMovingCalls or 0) + 1
        self.moving = false
    end
    function frame:SetMinMaxValues(minValue, maxValue) self.minValue, self.maxValue = minValue, maxValue end
    function frame:SetValueStep(step) self.valueStep = step end
    function frame:SetObeyStepOnDrag() end
    function frame:SetValue(value) self.value = value end
    function frame:GetValue() return self.value or 0 end
    function frame:SetOrientation() end
    function frame:EnableKeyboard(value) self.keyboardEnabled = value ~= false end
    function frame:IsKeyboardEnabled() return self.keyboardEnabled == true end
    function frame:SetAutoFocus(value) self.autoFocus = value ~= false end
    function frame:SetFocus()
        self.focused = true
        runFrameHandlers(self, "OnEditFocusGained")
    end
    function frame:HighlightText() self.highlightedText = self:GetText() end
    function frame:ClearFocus()
        if not self.focused then return end
        self.focused = false
        runFrameHandlers(self, "OnEditFocusLost")
    end
    function frame:HasFocus() return self.focused == true end
    function frame:SetMultiLine() end
    function frame:SetMaxLetters() end
    function frame:SetMaxLines(value) self.maxLines = value end
    function frame:SetNumeric() end
    function frame:SetTextInsets() end
    function frame:SetWordWrap(value) self.wordWrap = value end
    function frame:GetStringWidth()
        if self.statsProWidthOverride ~= nil then return self.statsProWidthOverride end
        return utf8VisualUnits(self.text or "") * ((self.fontSize or 12) * 0.5)
    end
    function frame:GetStringHeight()
        if self.statsProHeightOverride ~= nil then return self.statsProHeightOverride end
        local text = self.text or ""
        local _, lines = text:gsub("\n", "\n")
        return (lines + 1) * (self.fontSize or 12) * (self.statsProStringHeightMultiplier or 1)
    end
    function frame:CreateFontString()
        local region = makeFrame(nil, self.setFontResult, self)
        region.regionType = "FontString"
        return region
    end
    function frame:CreateTexture()
        local region = makeFrame(nil, self.setFontResult, self)
        region.regionType = "Texture"
        return region
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
        rawequal = rawequal,
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
    env.__fontStrings = {}
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
    env.StaticPopup_Show = function(key, textArg1, textArg2, data)
        local definition = env.StaticPopupDialogs[key]
        if type(definition) ~= "table" then error("missing static popup " .. tostring(key), 2) end
        env.__staticPopupShows = env.__staticPopupShows + 1
        local popup = makeFrame(nil, opts.setFontResult, env.UIParent)
        popup.key = key
        popup.definition = definition
        popup.textArg1 = textArg1
        popup.textArg2 = textArg2
        popup.data = data
        if definition.hasEditBox then
            popup.EditBox = makeFrame(nil, opts.setFontResult, popup)
            function popup:GetEditBox() return self.EditBox end
        end
        env.__lastStaticPopup = popup
        if type(definition.OnShow) == "function" then
            definition.OnShow(popup, data)
        end
        return env.__lastStaticPopup
    end
    env.StaticPopup_Hide = function(key)
        local popup = env.__lastStaticPopup
        if not popup or popup.key ~= key then return end
        env.__lastStaticPopup = nil
        if type(popup.definition.OnCancel) == "function" then popup.definition.OnCancel() end
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
    env.UIParent:SetSize(opts.uiParentWidth or 1920, opts.uiParentHeight or 1080)
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
    env.UIDropDownMenu_SetText = function(frame, text)
        if not frame then return end
        frame.dropdownText = text
        if frame.statsProTrigger and frame.statsProTrigger.statsProText then
            frame.statsProTrigger.statsProText:SetText(text)
        end
    end
    env.UIDropDownMenu_SetWidth = function(frame, width)
        if frame then frame.dropdownWidth = width end
    end
    env.UIDropDownMenu_JustifyText = function(frame, justify)
        if frame then frame.dropdownJustify = justify end
    end
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
    function env.GameTooltip:GetOwner() return self.owner end
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

    env.CreateFrame = function(frameType, name, parent, template)
        local frame = makeFrame(name, opts.setFontResult, parent)
        function frame:SetFocus()
            local previous = env.__focusedFrame
            if previous and previous ~= self then
                previous.focused = false
                runFrameHandlers(previous, "OnEditFocusLost")
            end
            self.focused = true
            env.__focusedFrame = self
            runFrameHandlers(self, "OnEditFocusGained")
        end
        function frame:ClearFocus()
            if not self.focused then return end
            self.focused = false
            if env.__focusedFrame == self then env.__focusedFrame = nil end
            runFrameHandlers(self, "OnEditFocusLost")
        end
        frame.frameType = frameType
        frame.template = template
        frame.CreateFontString = function()
            local fontString = makeFrame(nil, opts.setFontResult, frame)
            fontString.regionType = "FontString"
            env.__fontStrings[#env.__fontStrings + 1] = fontString
            return fontString
        end
        frame.CreateTexture = function()
            local texture = makeFrame(nil, opts.setFontResult, frame)
            texture.regionType = "Texture"
            return texture
        end
        env.__frames[#env.__frames + 1] = frame
        if name then
            env[name] = frame
            env[name .. "Text"] = env[name .. "Text"] or makeFrame(name .. "Text", opts.setFontResult)
            env[name .. "Low"] = env[name .. "Low"] or makeFrame(name .. "Low", opts.setFontResult)
            env[name .. "High"] = env[name .. "High"] or makeFrame(name .. "High", opts.setFontResult)
            env[name .. "Button"] = env[name .. "Button"] or makeFrame(name .. "Button", opts.setFontResult)
            frame.Button = env[name .. "Button"]
        end
        if template == "UIPanelScrollFrameTemplate" then
            local scrollBarName = name and (name .. "ScrollBar") or nil
            local scrollBar = makeFrame(scrollBarName, opts.setFontResult, frame)
            local thumb = makeFrame(nil, opts.setFontResult, scrollBar)
            local up = makeFrame(scrollBarName and (scrollBarName .. "ScrollUpButton") or nil,
                opts.setFontResult, scrollBar)
            local down = makeFrame(scrollBarName and (scrollBarName .. "ScrollDownButton") or nil,
                opts.setFontResult, scrollBar)
            scrollBar.ThumbTexture = thumb
            scrollBar.ScrollUpButton = up
            scrollBar.ScrollDownButton = down
            for _, button in ipairs({ up, down }) do
                button.normalTexture = makeFrame(nil, opts.setFontResult, button)
                button.highlightTexture = makeFrame(nil, opts.setFontResult, button)
                button.pushedTexture = makeFrame(nil, opts.setFontResult, button)
                button.disabledTexture = makeFrame(nil, opts.setFontResult, button)
            end
            function scrollBar:GetThumbTexture() return thumb end
            frame.ScrollBar = scrollBar
            env.__frames[#env.__frames + 1] = scrollBar
            env.__frames[#env.__frames + 1] = up
            env.__frames[#env.__frames + 1] = down
            if scrollBarName then
                env[scrollBarName] = scrollBar
                env[scrollBarName .. "ScrollUpButton"] = up
                env[scrollBarName .. "ScrollDownButton"] = down
            end
        end
        if template == "UICheckButtonTemplate" then
            frame.normalTexture = makeFrame(nil, opts.setFontResult, frame)
            frame.checkedTexture = makeFrame(nil, opts.setFontResult, frame)
            frame.disabledCheckedTexture = makeFrame(nil, opts.setFontResult, frame)
        elseif template == "OptionsSliderTemplate" then
            frame.thumbTexture = makeFrame(nil, opts.setFontResult, frame)
        elseif template == "InputBoxTemplate" and name then
            for _, suffix in ipairs({ "Left", "Middle", "Right" }) do
                env[name .. suffix] = makeFrame(name .. suffix, opts.setFontResult, frame)
            end
        end
        return frame
    end

    local function zero() return 0 end
    env.GetCritChance = opts.getCritChance or zero
    env.GetSpellCritChance = opts.getSpellCritChance or zero
    env.GetRangedCritChance = opts.getRangedCritChance or zero
    env.MAX_SPELL_SCHOOLS = opts.maxSpellSchools or 7
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
    env.UnitGUID = opts.unitGUID
    env.UnitFullName = opts.unitFullName or function()
        return opts.unitName or "Tester", opts.realmName or "TestRealm"
    end
    env.GetServerTime = opts.getServerTime or function() return 1770000000 end
    env.UnitClass = opts.unitClass or function()
        return opts.unitClassName or "Warrior", opts.unitClassToken or "WARRIOR", opts.classID or 1
    end
    env.UnitRace = function() return "Human", "Human" end
    env.UnitSex = function() return 2 end
    env.GetSpecialization = function() return nil end
    env.GetSpecializationInfo = function() return nil end
    env.GetSpecializationRole = function() return nil end
    env.C_SpecializationInfo = {
        GetSpecialization = opts.getSpecialization or function() return opts.specIndex end,
        GetSpecializationInfo = opts.getSpecializationInfo or function()
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

local function withProfileIdentity(opts)
    opts = opts or {}
    opts.unitGUID = opts.unitGUID or function() return "Player-1-IMPORT" end
    opts.getSpecialization = opts.getSpecialization or function() return 1 end
    opts.specID = opts.specID or 73
    opts.specName = opts.specName or "Protection"
    opts.specRole = opts.specRole or "TANK"
    opts.primaryStat = opts.primaryStat or 1
    return opts
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
    eq("archon.meta.state", meta.comparisonState, "exact")
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
    eq("archon.v2.raid_tooltip_source_label", dualEnv.GameTooltip.lines[6].left, "Source:")
    eq("archon.v2.raid_tooltip_source_value", dualEnv.GameTooltip.lines[6].right, "Archon")

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

    local restrictedFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(restrictedFixture, "mythicPlus", "MAGE", "frost",
        { crit = 1007, haste = 560, mastery = 823, versatility = 97 })
    local restrictedEnv, _, restrictedTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        statsProArchonTargets = restrictedFixture,
        issecretvalue = function(value) return value == -1 end,
    })
    local ratingCRs = {
        crit = restrictedEnv.CR_CRIT_MELEE,
        haste = restrictedEnv.CR_HASTE_MELEE,
        mastery = restrictedEnv.CR_MASTERY,
        versatility = restrictedEnv.CR_VERSATILITY_DAMAGE_DONE,
    }
    for _, statKey in ipairs({ "crit", "haste", "mastery", "versatility" }) do
        local targetOnly = restrictedTest.buildArchonTargetMeta(statKey, -1, ratingCRs[statKey])
        check("archon.restricted.target_only." .. statKey .. ".meta", type(targetOnly) == "table", targetOnly)
        eq("archon.restricted.target_only." .. statKey .. ".state", targetOnly.comparisonState, "targetOnly")
        eq("archon.restricted.target_only." .. statKey .. ".current", targetOnly.current, nil)
        eq("archon.restricted.target_only." .. statKey .. ".delta", targetOnly.delta, nil)
    end

    local exactMeta = restrictedTest.buildArchonTargetMeta("mastery", 700, restrictedEnv.CR_MASTERY, 22.4)
    eq("archon.restricted.exact.state", exactMeta.comparisonState, "exact")
    eq("archon.restricted.exact.current", exactMeta.current, 700)
    eq("archon.restricted.exact.current_pct", exactMeta.currentPct, 22.4)
    local lastKnownMeta = restrictedTest.buildArchonTargetMeta("mastery", -1, restrictedEnv.CR_MASTERY)
    eq("archon.restricted.last_known.state", lastKnownMeta.comparisonState, "lastKnown")
    eq("archon.restricted.last_known.current", lastKnownMeta.current, 700)
    eq("archon.restricted.last_known.current_pct", lastKnownMeta.currentPct, 22.4)
    eq("archon.restricted.last_known.delta", lastKnownMeta.delta, -123)
    local recoveredMeta = restrictedTest.buildArchonTargetMeta("mastery", 710, restrictedEnv.CR_MASTERY, 23.1)
    eq("archon.restricted.recovery.state", recoveredMeta.comparisonState, "exact")
    eq("archon.restricted.recovery.current", recoveredMeta.current, 710)
    eq("archon.restricted.recovery.current_pct", recoveredMeta.currentPct, 23.1)

    restrictedFixture.snapshots.mythicPlus.specs.MAGE.frost.targets.mastery = 900
    local changedTargetMeta = restrictedTest.buildArchonTargetMeta("mastery", -1, restrictedEnv.CR_MASTERY)
    eq("archon.restricted.changed_target.state", changedTargetMeta.comparisonState, "targetOnly")
    eq("archon.restricted.changed_target.target", changedTargetMeta.target, 900)
    restrictedFixture.snapshots.mythicPlus.specs.MAGE.frost.targets.mastery = 823
    local revertedTargetMeta = restrictedTest.buildArchonTargetMeta("mastery", -1, restrictedEnv.CR_MASTERY)
    eq("archon.restricted.target_revert_stays_invalid.state", revertedTargetMeta.comparisonState, "targetOnly")
    restrictedTest.buildArchonTargetMeta("mastery", 710, restrictedEnv.CR_MASTERY, 23.1)
    restrictedFixture.snapshots.mythicPlus.capturedAt = "2026-05-16"
    local changedCaptureMeta = restrictedTest.buildArchonTargetMeta("mastery", -1, restrictedEnv.CR_MASTERY)
    eq("archon.restricted.changed_capture.state", changedCaptureMeta.comparisonState, "targetOnly")
    eq("archon.restricted.changed_capture.captured_at", changedCaptureMeta.capturedAt, "2026-05-16")
    restrictedFixture.snapshots.mythicPlus.capturedAt = "2026-05-15"
    local revertedCaptureMeta = restrictedTest.buildArchonTargetMeta("mastery", -1, restrictedEnv.CR_MASTERY)
    eq("archon.restricted.capture_revert_stays_invalid.state", revertedCaptureMeta.comparisonState, "targetOnly")

    local contextFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(contextFixture, "mythicPlus", "MAGE", "frost",
        { crit = 100, haste = 200, mastery = 823, versatility = 400 })
    setArchonFixtureTargets(contextFixture, "mythicPlus", "MAGE", "fire",
        { crit = 110, haste = 210, mastery = 933, versatility = 410 })
    setArchonFixtureTargets(contextFixture, "raid", "MAGE", "frost",
        { crit = 120, haste = 220, mastery = 812, versatility = 420 })
    local activeSpecID = 64
    local contextEnv, _, contextTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        statsProArchonTargets = contextFixture,
        getSpecializationInfo = function()
            return activeSpecID, nil, nil, nil, nil, 4
        end,
        issecretvalue = function(value) return value == -1 end,
    })
    contextTest.buildArchonTargetMeta("mastery", 700, contextEnv.CR_MASTERY, 20.0)
    local untouchedCritMeta = contextTest.buildArchonTargetMeta("crit", -1, contextEnv.CR_CRIT_MELEE)
    eq("archon.restricted.stat_isolation.state", untouchedCritMeta.comparisonState, "targetOnly")
    activeSpecID = 63
    local fireMeta = contextTest.buildArchonTargetMeta("mastery", -1, contextEnv.CR_MASTERY)
    eq("archon.restricted.spec_isolation.state", fireMeta.comparisonState, "targetOnly")
    eq("archon.restricted.spec_isolation.target", fireMeta.target, 933)
    activeSpecID = 64
    local frostAgainMeta = contextTest.buildArchonTargetMeta("mastery", -1, contextEnv.CR_MASTERY)
    eq("archon.restricted.spec_switch_back_invalidates.state", frostAgainMeta.comparisonState, "targetOnly")
    activeSettings(contextEnv).targetSnapshot = "raid"
    contextTest.cacheSettings()
    local raidRestrictedMeta = contextTest.buildArchonTargetMeta("mastery", -1, contextEnv.CR_MASTERY)
    eq("archon.restricted.snapshot_isolation.state", raidRestrictedMeta.comparisonState, "targetOnly")
    eq("archon.restricted.snapshot_isolation.target", raidRestrictedMeta.target, 812)
    activeSettings(contextEnv).targetSnapshot = "mythicPlus"
    contextTest.cacheSettings()
    local mythicPlusAgainMeta = contextTest.buildArchonTargetMeta("mastery", -1, contextEnv.CR_MASTERY)
    eq("archon.restricted.snapshot_switch_back_invalidates.state", mythicPlusAgainMeta.comparisonState, "targetOnly")
    contextTest.buildArchonTargetMeta("mastery", 705, contextEnv.CR_MASTERY, 20.5)
    contextFixture.snapshots.mythicPlus.specs.MAGE.fire = nil
    activeSpecID = 63
    eq("archon.restricted.missing_spec_context.meta",
        contextTest.buildArchonTargetMeta("mastery", -1, contextEnv.CR_MASTERY), nil)
    activeSpecID = 64
    local afterMissingSpecMeta = contextTest.buildArchonTargetMeta("mastery", -1, contextEnv.CR_MASTERY)
    eq("archon.restricted.missing_spec_switch_back_invalidates.state",
        afterMissingSpecMeta.comparisonState, "targetOnly")
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

local function assertRGBA(name, color, r, g, b, a)
    if type(r) == "table" then
        r, g, b, a = r[1], r[2], r[3], r[4]
    end
    assertColor(name, color, r, g, b)
    near(name .. ".a", color.a, a)
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

    activeSettings(repairEnv).labelStyle = "hidden"
    repairTest.cacheSettings()
    repairTest.renderMainPanelForSmoke("", "", "", 0, "coin", "")
    local hiddenLabel = repairTest.panelVisualState()
    eq("panel.secret_repair.hidden_label_width", hiddenLabel.mainRepairLabelWidth, 0)
    eq("panel.secret_repair.hidden_label_frame_width", hiddenLabel.mainFrameWidth, 112)
    eq("panel.secret_repair.hidden_label_hidden", hiddenLabel.mainRepairLabelShown, false)

    activeSettings(repairEnv).labelStyle = "full"
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
    local targetFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(targetFixture, "mythicPlus", "MAGE", "frost",
        { crit = 1043, haste = 560, mastery = 823, versatility = 97 })
    local targetOnlyEnv, _, targetOnlyTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        statsProDB = { matchValueColorToStat = false },
        statsProArchonTargets = targetFixture,
        inCombatLockdown = function() return true end,
        getCombatRating = function() return -1 end,
        issecretvalue = function(value) return value == -1 end,
    })
    local okTargetOnlyFire, errTargetOnlyFire = pcall(targetOnlyEnv.__fireEvent, "PLAYER_ENTERING_WORLD")
    check("tooltip.restricted_target_only.fire", okTargetOnlyFire, errTargetOnlyFire)
    local targetOnlyMeta = targetOnlyTest.buildArchonTargetMeta(
        "crit", -1, targetOnlyEnv.CR_CRIT_MELEE)
    eq("tooltip.restricted_target_only.state", targetOnlyMeta.comparisonState, "targetOnly")
    targetOnlyTest.renderMainPanelForSmoke("Crit:", "812", "30.0%", 1, nil, nil, { targetOnlyMeta })
    targetOnlyTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    eq("tooltip.restricted_target_only.combat_on_enter_shows", targetOnlyEnv.GameTooltip:IsShown(), true)
    eq("tooltip.restricted_target_only.line_count", #targetOnlyEnv.GameTooltip.lines, 4)
    eq("tooltip.restricted_target_only.target_label", targetOnlyEnv.GameTooltip.lines[2].left, "Target:")
    eq("tooltip.restricted_target_only.target_value", targetOnlyEnv.GameTooltip.lines[2].right, "1043")
    eq("tooltip.restricted_target_only.snapshot_label", targetOnlyEnv.GameTooltip.lines[3].left, "Snapshot:")
    eq("tooltip.restricted_target_only.source_label", targetOnlyEnv.GameTooltip.lines[4].left, "Source:")
    eq("tooltip.restricted_target_only.source_value", targetOnlyEnv.GameTooltip.lines[4].right, "Archon")

    local exactMeta = targetOnlyTest.buildArchonTargetMeta(
        "crit", 812, targetOnlyEnv.CR_CRIT_MELEE, 30.0)
    eq("tooltip.restricted_last_known.prime_exact", exactMeta.comparisonState, "exact")
    local lastKnownMeta = targetOnlyTest.buildArchonTargetMeta(
        "crit", -1, targetOnlyEnv.CR_CRIT_MELEE)
    targetOnlyTest.renderMainPanelForSmoke("Crit:", "812", "30.0%", 1, nil, nil, { lastKnownMeta })
    targetOnlyTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    eq("tooltip.restricted_last_known.line_count", #targetOnlyEnv.GameTooltip.lines, 7)
    eq("tooltip.restricted_last_known.notice", targetOnlyEnv.GameTooltip.lines[2].left, "Last known comparison")
    eq("tooltip.restricted_last_known.target_label", targetOnlyEnv.GameTooltip.lines[3].left, "Target:")
    eq("tooltip.restricted_last_known.current_label", targetOnlyEnv.GameTooltip.lines[4].left, "Current:")
    eq("tooltip.restricted_last_known.current_value", targetOnlyEnv.GameTooltip.lines[4].right, "812 (~30.0%)")
    eq("tooltip.restricted_last_known.delta_label", targetOnlyEnv.GameTooltip.lines[5].left, "Missing:")
    eq("tooltip.restricted_last_known.snapshot_label", targetOnlyEnv.GameTooltip.lines[6].left, "Snapshot:")
    eq("tooltip.restricted_last_known.source_label", targetOnlyEnv.GameTooltip.lines[7].left, "Source:")
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
        issecretvalue = function(value) return value == -1 end,
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
    local localizedLastKnown = localizedTooltipTest.buildArchonTargetMeta(
        "crit", -1, localizedTooltipEnv.CR_CRIT_MELEE)
    localizedTooltipTest.renderMainPanelForSmoke("Крит:", "812", "30.0%", 1, nil, nil, { localizedLastKnown })
    localizedTooltipTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    eq("tooltip.localized_ruRU_last_known_notice",
        localizedTooltipEnv.GameTooltip.lines[2].left, "Последнее известное сравнение")
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
    local meta = { statKey = "mastery", target = 1043, comparisonState = "targetOnly" }
    local blocks = {
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
    }
    local flatMain = test.routeRenderBlocks(blocks, "flat", nil, "hidden")
    eq("tooltip.route_flat_character_row", flatMain.targetRows[1], false)
    eq("tooltip.route_flat_offensive_row", flatMain.targetRows[2], meta)

    local main = test.routeRenderBlocks(blocks, "sectioned", nil, "full")
    eq("tooltip.route_header_character", main.targetRows[1], false)
    eq("tooltip.route_character_row", main.targetRows[2], false)
    eq("tooltip.route_header_offensive", main.targetRows[3], false)
    eq("tooltip.route_offensive_row", main.targetRows[4], meta)

    local splitMain, splitSide = test.routeRenderBlocks(blocks, "split", {
        splitCharacter = false,
        splitOffensive = true,
    }, "hidden")
    eq("tooltip.route_split_main_character_row", splitMain.targetRows[1], false)
    eq("tooltip.route_split_side_offensive_row", splitSide.targetRows[1], meta)
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

local function userInteract(name, frame, scriptName, ...)
    frame = exists(name .. ".frame", frame)
    if (scriptName == "OnClick" or scriptName == "OnMouseDown" or scriptName == "OnMouseUp")
        and type(frame.IsEnabled) == "function" and not frame:IsEnabled() then
        return false
    end
    local ok, err = pcall(runFrameHandlers, frame, scriptName, ...)
    check(name, ok, err)
    return true
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

local function countValue(t, value)
    local count = 0
    for _, item in ipairs(t) do
        if item == value then count = count + 1 end
    end
    return count
end

local function closeSpecialWindows(env)
    local closed = false
    -- Match Blizzard UIParentPanelManager exactly: Escape walks the live shared
    -- table. OnHide mutations therefore remain observable during this loop.
    for _, name in pairs(env.UISpecialFrames) do
        local frame = env[name]
        if frame and frame:IsShown() then
            frame:Hide()
            closed = true
        end
    end
    return closed
end

local function findFontString(name, env, predicate)
    for _, fontString in ipairs(env.__fontStrings) do
        if predicate(fontString) then return fontString end
    end
    fail(name, "matching font string not found")
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
    local flat = {
        dbVersion = 9,
        forceLocale = "ruRU",
        updateInterval = 0.85,
        isVisible = false,
        showCrit = false,
        splitItemLevel = false,
        point = "TOPLEFT",
        relativePoint = "TOPLEFT",
        xOfs = 37,
        yOfs = -41,
        defensive_point = "BOTTOMRIGHT",
        defensive_relativePoint = "BOTTOMRIGHT",
        defensive_xOfs = -19,
        defensive_yOfs = 23,
        colors = {
            crit = { r = 0.2, g = 0.3, b = 0.4 },
            haste = { r = 0.6, g = 0.7, b = 0.8 },
        },
        futureRollbackScalar = "keep",
        futureRollbackNested = { child = { value = 42 } },
    }
    flat.colors.mastery = flat.colors.crit
    local before = deepCopy(flat)
    local sourceColors = flat.colors
    local sourceCrit = flat.colors.crit
    local root = runMigrate(flat)
    eq("profiles.migration.same_root", rawequal(root, flat), true)
    eq("profiles.migration.version", root.dbVersion, test.currentDBVersion())
    check("profiles.migration.account", type(root.account) == "table", "account missing")
    check("profiles.migration.profiles", type(root.profiles) == "table", "profiles missing")
    local account = accountSettings(root)
    local settings = activeSettings(root)
    eq("profiles.migration.account_locale", account.forceLocale, "ruRU")
    near("profiles.migration.account_interval", account.updateInterval, 0.85)
    eq("profiles.migration.default_profile_id", account.defaultProfileID, "p1")
    eq("profiles.migration.next_profile_id", account.nextProfileID, 2)
    eq("profiles.migration.profile_name", root.profiles.p1.name, "Default")
    eq("profiles.migration.explicit_false_visible", settings.isVisible, false)
    eq("profiles.migration.explicit_false_crit", settings.showCrit, false)
    eq("profiles.migration.explicit_false_routing", settings.splitItemLevel, false)
    eq("profiles.migration.account_locale_not_profile", rawget(settings, "forceLocale"), nil)
    eq("profiles.migration.account_interval_not_profile", rawget(settings, "updateInterval"), nil)
    eq("profiles.migration.main_position", settings.xOfs, 37)
    eq("profiles.migration.side_position", settings.defensive_xOfs, -19)
    assertColor("profiles.migration.crit_color", settings.colors.crit, 0.2, 0.3, 0.4)
    eq("profiles.migration.role_tank", root.roleTemplates.TANK, "p1")
    eq("profiles.migration.role_healer", root.roleTemplates.HEALER, "p1")
    eq("profiles.migration.role_damage", root.roleTemplates.DAMAGER, "p1")
    eq("profiles.migration.characters_empty", next(root.characters), nil)
    eq("profiles.migration.rollback_scalar", root.futureRollbackScalar, before.futureRollbackScalar)
    assertDeepEqual("profiles.migration.rollback_nested", root.futureRollbackNested, before.futureRollbackNested)
    eq("profiles.migration.rollback_missing_stays_missing", rawget(root, "showRepairCost"), nil)
    eq("profiles.migration.profile_unknown_scalar", settings.futureRollbackScalar, before.futureRollbackScalar)
    assertDeepEqual("profiles.migration.profile_unknown_nested",
        settings.futureRollbackNested, before.futureRollbackNested)
    eq("profiles.migration.profile_unknown_isolated",
        rawequal(settings.futureRollbackNested, root.futureRollbackNested), false)
    eq("profiles.migration.colors_source_preserved", rawequal(root.colors, sourceColors), true)
    eq("profiles.migration.profile_colors_isolated", rawequal(settings.colors, sourceColors), false)
    eq("profiles.migration.profile_crit_isolated", rawequal(settings.colors.crit, sourceCrit), false)
    eq("profiles.migration.shared_source_color_dealiased",
        rawequal(settings.colors.crit, settings.colors.mastery), false)
    settings.colors.crit.r = 0.9
    near("profiles.migration.profile_mutation_does_not_touch_shadow", root.colors.crit.r, 0.2)
    root.futureRollbackNested.child.value = 99
    eq("profiles.migration.shadow_mutation_does_not_enter_profile",
        settings.futureRollbackNested.child.value, 42)
end

do
    local legacyColors = { primary = { r = 0.25, g = 0.35, b = 0.45 } }
    local legacyUnknown = { child = { value = 17 } }
    local flat = {
        dbVersion = 4,
        useLocalizedLabels = false,
        showStrength = true,
        showAgility = false,
        showIntellect = false,
        colors = legacyColors,
        legacyRollbackUnknown = legacyUnknown,
    }
    local root = runMigrate(flat)
    local settings = activeSettings(root)
    eq("profiles.legacy_transform_shadow.same_root", rawequal(root, flat), true)
    eq("profiles.legacy_transform_shadow.locale_field_missing", rawget(root, "forceLocale"), nil)
    eq("profiles.legacy_transform_shadow.main_stat_missing", rawget(root, "showMainStat"), nil)
    eq("profiles.legacy_transform_shadow.localized_unchanged", root.useLocalizedLabels, false)
    eq("profiles.legacy_transform_shadow.strength_unchanged", root.showStrength, true)
    eq("profiles.legacy_transform_shadow.colors_identity", rawequal(root.colors, legacyColors), true)
    eq("profiles.legacy_transform_shadow.primary_identity",
        rawequal(root.colors.primary, legacyColors.primary), true)
    eq("profiles.legacy_transform_shadow.unknown_identity",
        rawequal(root.legacyRollbackUnknown, legacyUnknown), true)
    eq("profiles.legacy_transform_shadow.account_locale", accountSettings(root).forceLocale, "enUS")
    eq("profiles.legacy_transform_shadow.profile_main_stat", settings.showMainStat, true)
    eq("profiles.legacy_transform_shadow.profile_legacy_locale_removed",
        rawget(settings, "useLocalizedLabels"), nil)
    eq("profiles.legacy_transform_shadow.profile_primary_removed",
        rawget(settings.colors, "primary"), nil)
    assertColor("profiles.legacy_transform_shadow.profile_main_color",
        settings.colors.mainStat, 0.25, 0.35, 0.45)
    assertDeepEqual("profiles.legacy_transform_shadow.profile_unknown",
        settings.legacyRollbackUnknown, legacyUnknown)
    eq("profiles.legacy_transform_shadow.profile_unknown_isolated",
        rawequal(settings.legacyRollbackUnknown, legacyUnknown), false)
end

do
    local unsafeUnknown = {}
    unsafeUnknown.self = unsafeUnknown
    local flat = {
        dbVersion = 9,
        showCrit = false,
        colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } },
        unsafeRollbackOnly = unsafeUnknown,
    }
    local root = runMigrate(flat)
    eq("profiles.unsafe_unknown.migrates", root.dbVersion, test.currentDBVersion())
    eq("profiles.unsafe_unknown.shadow_identity", rawequal(root.unsafeRollbackOnly, unsafeUnknown), true)
    eq("profiles.unsafe_unknown.shadow_cycle", rawequal(root.unsafeRollbackOnly.self, unsafeUnknown), true)
    eq("profiles.unsafe_unknown.profile_excluded", rawget(activeSettings(root), "unsafeRollbackOnly"), nil)
    eq("profiles.unsafe_unknown.current_mode", test.dbCompatibilityState().mode, "current")
end

do
    local secretSetting = -987654
    local flat = {
        dbVersion = 9,
        showCrit = secretSetting,
        colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } },
    }
    local before = deepCopy(flat)
    local secretEnv, _, secretTest = loadStatsPro("enUS", {
        statsProDB = flat,
        issecretvalue = function(value) return value == secretSetting end,
    })
    local ok, err = pcall(secretEnv.__fireEvent, "PLAYER_ENTERING_WORLD")
    check("profiles.secret_migration.no_error", ok, err)
    eq("profiles.secret_migration.same_root", rawequal(secretEnv.StatsProDB, flat), true)
    assertDeepEqual("profiles.secret_migration.atomic", secretEnv.StatsProDB, before)
    eq("profiles.secret_migration.no_registry", rawget(flat, "account"), nil)
    eq("profiles.secret_migration.corrupt_mode", secretTest.dbCompatibilityState().mode, "corrupt")
end

do
    local cases = {
        {
            name = "boolean",
            key = "showDefensive",
            value = true,
            expected = false,
            read = function(smokeTest) return smokeTest.getBoolDB("showDefensive") end,
        },
        {
            name = "number",
            key = "updateInterval",
            value = 0.85,
            expected = 0.5,
            read = function(smokeTest) return smokeTest.getNumberDB("updateInterval") end,
        },
        {
            name = "string",
            key = "forceLocale",
            value = "ruRU",
            expected = "auto",
            read = function(smokeTest) return smokeTest.getDB("forceLocale") end,
        },
    }
    for _, case in ipairs(cases) do
        local root = { dbVersion = 9 }
        root[case.key] = case.value
        local before = deepCopy(root)
        local secretEnv, _, secretTest = loadStatsPro("enUS", {
            statsProDB = root,
            issecretvalue = function(value) return value == case.value end,
        })
        local ok, err = pcall(secretEnv.__fireEvent, "PLAYER_ENTERING_WORLD")
        check("profiles.secret_typed." .. case.name .. ".pew_no_error", ok, err)
        eq("profiles.secret_typed." .. case.name .. ".mode",
            secretTest.dbCompatibilityState().mode, "corrupt")
        eq("profiles.secret_typed." .. case.name .. ".safe_fallback",
            case.read(secretTest), case.expected)
        eq("profiles.secret_typed." .. case.name .. ".same_root",
            rawequal(secretEnv.StatsProDB, root), true)
        assertDeepEqual("profiles.secret_typed." .. case.name .. ".no_writes", root, before)
    end
end

do
    local root = runMigrate({
        dbVersion = 9,
        isVisible = false,
        colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } },
    })
    local before = deepCopy(root)
    local first = test.profileState()
    local rootRef = first.root
    local accountRef = first.account
    local profilesRef = first.profiles
    local settingsRef = first.settings
    local roleTemplatesRef = first.roleTemplates
    local charactersRef = first.characters
    test.migrateDB()
    test.migrateDB()
    local second = test.profileState()
    assertDeepEqual("profiles.migration_idempotent.deep", root, before)
    eq("profiles.migration_idempotent.root_identity", rawequal(second.root, rootRef), true)
    eq("profiles.migration_idempotent.account_identity", rawequal(second.account, accountRef), true)
    eq("profiles.migration_idempotent.profiles_identity", rawequal(second.profiles, profilesRef), true)
    eq("profiles.migration_idempotent.settings_identity", rawequal(second.settings, settingsRef), true)
    eq("profiles.migration_idempotent.roles_identity", rawequal(second.roleTemplates, roleTemplatesRef), true)
    eq("profiles.migration_idempotent.characters_identity", rawequal(second.characters, charactersRef), true)
    eq("profiles.migration_idempotent.profile_id", second.profileID, "p1")
    eq("profiles.migration_idempotent.next_id", second.account.nextProfileID, 2)
end

do
    local idempotentEnv, _, idempotentTest = loadStatsPro("enUS", {
        statsProDB = { dbVersion = 9, isVisible = false, colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } } },
    })
    fireEvent("profiles.pew_idempotent.first", idempotentEnv, "PLAYER_ENTERING_WORLD")
    local before = deepCopy(idempotentEnv.StatsProDB)
    local first = idempotentTest.profileState()
    fireEvent("profiles.pew_idempotent.second", idempotentEnv, "PLAYER_ENTERING_WORLD")
    local second = idempotentTest.profileState()
    assertDeepEqual("profiles.pew_idempotent.deep", idempotentEnv.StatsProDB, before)
    eq("profiles.pew_idempotent.root_identity", rawequal(second.root, first.root), true)
    eq("profiles.pew_idempotent.settings_identity", rawequal(second.settings, first.settings), true)
    eq("profiles.pew_idempotent.account_identity", rawequal(second.account, first.account), true)
end

do
    local root = runMigrate({
        dbVersion = 9,
        forceLocale = "ruRU",
        updateInterval = 0.85,
        isVisible = false,
        scale = 1.4,
        point = "TOPLEFT",
        xOfs = 37,
        colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } },
    })
    local settings = activeSettings(root)
    root.forceLocale = "deDE"
    root.updateInterval = 0.1
    root.isVisible = true
    root.scale = 0.5
    root.point = "BOTTOMRIGHT"
    root.colors.crit = { r = 0.9, g = 0.8, b = 0.7 }
    eq("profiles.accessor.profile_bool", test.getBoolDB("isVisible"), false)
    near("profiles.accessor.profile_number", test.getNumberDB("scale"), 1.4)
    eq("profiles.accessor.profile_position", test.getDB("point"), "TOPLEFT")
    assertColor("profiles.accessor.profile_color", test.getColor("crit"), 0.2, 0.3, 0.4)
    eq("profiles.accessor.account_locale", test.getDB("forceLocale"), "ruRU")
    near("profiles.accessor.account_interval", test.getNumberDB("updateInterval"), 0.85)
    eq("profiles.accessor.settings_identity", rawequal(test.profileState().settings, settings), true)
end

do
    local registry = test.registrySnapshot()
    local defaults = test.copyDefaults()
    for key in pairs(defaults) do
        local expectedAccount = key == "forceLocale" or key == "updateInterval"
        eq("profiles.scope_classification." .. key,
            registry.accountSettingKeys[key] == true, expectedAccount)
    end
    for key in pairs(registry.accountSettingKeys) do
        check("profiles.scope_classification.known_account_key." .. key,
            defaults[key] ~= nil, "account key missing from defaults")
    end
end

do
    local cycle = {}
    cycle.self = cycle
    local root = { dbVersion = 9, isVisible = false, colors = cycle }
    local before = deepCopy(root)
    local cycleEnv, _, cycleTest = loadStatsPro("enUS", { statsProDB = root })
    fireEvent("profiles.migration_cycle.pew", cycleEnv, "PLAYER_ENTERING_WORLD")
    local state = cycleTest.dbCompatibilityState()
    eq("profiles.migration_cycle.mode", state.mode, "corrupt")
    eq("profiles.migration_cycle.same_root", rawequal(cycleEnv.StatsProDB, root), true)
    assertDeepEqual("profiles.migration_cycle.no_partial_write", cycleEnv.StatsProDB, before)
    eq("profiles.migration_cycle.no_registry", cycleEnv.StatsProDB.account, nil)
end

do
    local root = runMigrate({})
    local db = activeSettings(root)
    eq("db.empty_default_population.version", root.dbVersion, test.currentDBVersion())
    eq("db.empty_default_population.force_locale", accountSettings(root).forceLocale, "auto")
    eq("db.empty_default_population.font", db.font, test.copyDefaults().font)
    eq("db.empty_default_population.font_size", db.fontSize, 14)
    eq("db.empty_default_population.text_alpha", db.textAlpha, 100)
    eq("db.empty_default_population.panel_background_alpha", db.panelBackgroundAlpha, 15)
    eq("db.empty_default_population.text_outline_style", db.textOutlineStyle, "outline")
    eq("db.empty_default_population.appearance_preset", db.appearancePresetID, "default")
    eq("db.empty_default_population.show_rating", db.showRating, true)
    eq("db.empty_default_population.show_percentage", db.showPercentage, true)
    eq("db.empty_default_population.match_value_color", db.matchValueColorToStat, true)
    eq("db.empty_default_population.label_style", db.labelStyle, "full")
    eq("db.empty_default_population.target_snapshot", db.targetSnapshot, "mythicPlus")
    eq("db.empty_default_population.split_item_level", db.splitItemLevel, true)
    eq("db.empty_default_population.show_stagger", db.showStagger, false)
    check("db.empty_default_population.colors", type(db.colors) == "table", "colors table missing")
    assertColor("db.empty_default_population.crit", db.colors.crit, 1, 0, 0)
    assertColor("db.empty_default_population.stagger", db.colors.stagger, 0.3, 0.8, 0.5)
end

do
    local root = runMigrate({ dbVersion = 8, splitItemLevel = false })
    local db = activeSettings(root)
    eq("db.v8_preserves_existing_split_item_level_false.value", db.splitItemLevel, false)
    eq("db.v8_preserves_existing_split_item_level_false.version", root.dbVersion, test.currentDBVersion())
end

do
    local root = runMigrate({ dbVersion = 4, useLocalizedLabels = false })
    local db = activeSettings(root)
    eq("db.v4_use_localized_false_to_enUS.force", accountSettings(root).forceLocale, "enUS")
    eq("db.v4_use_localized_false_to_enUS.legacy_removed", db.useLocalizedLabels, nil)
    eq("db.v4_use_localized_false_to_enUS.version", root.dbVersion, test.currentDBVersion())
end

do
    local db = activeSettings(runMigrate({
        dbVersion = 5,
        colors = { primary = { r = 0.25, g = 0.5, b = 0.75 } },
    }))
    assertColor("db.v5_primary_color_split.mainStat", db.colors.mainStat, 0.25, 0.5, 0.75)
    eq("db.v5_primary_color_split.primary_removed", db.colors.primary, nil)
    eq("db.v5_primary_color_split.intermediate_removed", db.colors.intellect, nil)
end

do
    local db = activeSettings(runMigrate({
        dbVersion = 6,
        showStrength = false,
        showAgility = true,
        showIntellect = false,
        colors = {
            strength = { r = 1, g = 0.84, b = 0 },
            agility = { r = 0.2, g = 0.3, b = 0.4 },
            intellect = { r = 1, g = 0.84, b = 0 },
        },
    }))
    eq("db.v6_main_stat_toggle_and_color_collapse.show", db.showMainStat, true)
    assertColor("db.v6_main_stat_toggle_and_color_collapse.color", db.colors.mainStat, 0.2, 0.3, 0.4)
    eq("db.v6_main_stat_toggle_and_color_collapse.strength_removed", db.showStrength, nil)
    eq("db.v6_main_stat_toggle_and_color_collapse.color_agility_removed", db.colors.agility, nil)
end

do
    local db = activeSettings(runMigrate({
        dbVersion = 6,
        showStrength = "false",
        showAgility = false,
        showIntellect = false,
    }))
    eq("db.v6_legacy_boolean_string_not_truthy", db.showMainStat, false)
end

do
    local db = activeSettings(runMigrate({ dbVersion = 7, showDurability = true }))
    eq("db.v7_repair_preserve_visible_layout", db.showRepairCost, true)
end

do
    local db = activeSettings(runMigrate({ dbVersion = 7, showDurability = false, showRepairCost = true }))
    eq("db.v7_repair_no_new_repair_only_row", db.showRepairCost, false)
end

do
    local root = runMigrate({ dbVersion = "7", showDurability = true })
    eq("db.version_string_migrates_without_error.version", root.dbVersion, test.currentDBVersion())
    eq("db.version_string_migrates_without_error.repair", activeSettings(root).showRepairCost, true)
end

do
    local root = runMigrate({ dbVersion = "bad" })
    eq("db.version_invalid_runs_forward_migrations.string", root.dbVersion, test.currentDBVersion())
    root = runMigrate({ dbVersion = 0 / 0 })
    eq("db.version_invalid_runs_forward_migrations.nan", root.dbVersion, test.currentDBVersion())
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
    local db = activeSettings(runMigrate({ font = {}, fontBeforeAutoSwitch = {} }))
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
    eq("numbers.nan_falls_back.panel_background_alpha", test.normalizeNumberSetting("panelBackgroundAlpha", nan), 15)
    near("numbers.nan_falls_back.update_interval", test.normalizeNumberSetting("updateInterval", nan), 0.5)
end

do
    local inf = 1 / 0
    eq("numbers.inf_handled.font_size_pos", test.normalizeNumberSetting("fontSize", inf), 14)
    eq("numbers.inf_handled.font_size_neg", test.normalizeNumberSetting("fontSize", -inf), 14)
    near("numbers.inf_handled.scale_pos", test.normalizeNumberSetting("scale", inf), 1)
    near("numbers.inf_handled.scale_neg", test.normalizeNumberSetting("scale", -inf), 1)
    eq("numbers.inf_handled.panel_background_alpha_pos", test.normalizeNumberSetting("panelBackgroundAlpha", inf), 15)
    eq("numbers.inf_handled.panel_background_alpha_neg", test.normalizeNumberSetting("panelBackgroundAlpha", -inf), 15)
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
    local wideEnv = loadStatsPro("enUS", {
        statsProDB = {},
        uiParentWidth = 7680,
        uiParentHeight = 4320,
    })
    fireEvent("position.ui_bound.wide_round_trip.pew", wideEnv, "PLAYER_ENTERING_WORLD")
    wideEnv.StatsProFrame:ClearAllPoints()
    wideEnv.StatsProFrame:SetPoint("CENTER", wideEnv.UIParent, "CENTER", 3500, -120)
    fireEvent("position.ui_bound.wide_round_trip.logout", wideEnv, "PLAYER_LOGOUT")
    eq("position.ui_bound.wide_round_trip.saved_x", activeSettings(wideEnv).xOfs, 3500)

    local saved = deepCopy(wideEnv.StatsProDB)
    local reloadEnv = loadStatsPro("enUS", {
        statsProDB = saved,
        uiParentWidth = 7680,
        uiParentHeight = 4320,
    })
    fireEvent("position.ui_bound.wide_round_trip.reload", reloadEnv, "PLAYER_ENTERING_WORLD")
    eq("position.ui_bound.wide_round_trip.loaded_x", reloadEnv.StatsProFrame.points[1][4], 3500)
    eq("position.ui_bound.wide_round_trip.loaded_y", reloadEnv.StatsProFrame.points[1][5], -120)
    clearPrints(reloadEnv)
    slash("position.ui_bound.wide_round_trip.debug", reloadEnv, "debug")
    eq("position.ui_bound.wide_round_trip.debug_x",
        printContains(reloadEnv, "main: CENTER/CENTER  +3500/-120"), true)

    local fullExtentEnv = loadStatsPro("enUS", {
        statsProDB = {
            point = "LEFT",
            relativePoint = "RIGHT",
            xOfs = -7680,
            yOfs = 0,
        },
        uiParentWidth = 7680,
        uiParentHeight = 4320,
    })
    fireEvent("position.ui_bound.full_anchor_extent.pew", fullExtentEnv, "PLAYER_ENTERING_WORLD")
    eq("position.ui_bound.full_anchor_extent.point", fullExtentEnv.StatsProFrame.points[1][1], "LEFT")
    eq("position.ui_bound.full_anchor_extent.relative", fullExtentEnv.StatsProFrame.points[1][3], "RIGHT")
    eq("position.ui_bound.full_anchor_extent.x", fullExtentEnv.StatsProFrame.points[1][4], -7680)

    local narrowEnv = loadStatsPro("enUS", {
        statsProDB = deepCopy(saved),
        uiParentWidth = 1920,
        uiParentHeight = 1080,
    })
    fireEvent("position.ui_bound.narrow_rejects_wide.pew", narrowEnv, "PLAYER_ENTERING_WORLD")
    eq("position.ui_bound.narrow_rejects_wide.frame_x", narrowEnv.StatsProFrame.points[1][4], 0)
    eq("position.ui_bound.narrow_rejects_wide.db_unchanged", activeSettings(narrowEnv).xOfs, 3500)
end

do
    local axisEnv = loadStatsPro("enUS", {
        statsProDB = {
            xOfs = 3500,
            yOfs = 3500,
            defensive_xOfs = -3000,
            defensive_yOfs = 3500,
        },
        uiParentWidth = 1920,
        uiParentHeight = 5000,
    })
    fireEvent("position.ui_bound.axis_independent.pew", axisEnv, "PLAYER_ENTERING_WORLD")
    eq("position.ui_bound.axis_independent.main_x_fallback", axisEnv.StatsProFrame.points[1][4], 0)
    eq("position.ui_bound.axis_independent.main_y", axisEnv.StatsProFrame.points[1][5], 3500)
    eq("position.ui_bound.axis_independent.legacy_floor",
        axisEnv.StatsProDefensiveFrame.points[1][4], -3000)
    eq("position.ui_bound.axis_independent.defensive_y",
        axisEnv.StatsProDefensiveFrame.points[1][5], 3500)

    local malformedEnv = loadStatsPro("enUS", {
        statsProDB = {
            xOfs = "3500",
            yOfs = math.huge,
            defensive_xOfs = -math.huge,
            defensive_yOfs = 0 / 0,
        },
        uiParentWidth = 7680,
        uiParentHeight = 5000,
    })
    fireEvent("position.ui_bound.malformed_offsets.pew", malformedEnv, "PLAYER_ENTERING_WORLD")
    eq("position.ui_bound.malformed_offsets.string", malformedEnv.StatsProFrame.points[1][4], 0)
    eq("position.ui_bound.malformed_offsets.inf", malformedEnv.StatsProFrame.points[1][5], 0)
    eq("position.ui_bound.malformed_offsets.neg_inf",
        malformedEnv.StatsProDefensiveFrame.points[1][4], 0)
    eq("position.ui_bound.malformed_offsets.nan",
        malformedEnv.StatsProDefensiveFrame.points[1][5], -100)

    local invalidParentEnv = loadStatsPro("enUS", {
        statsProDB = { xOfs = 3500 },
        uiParentWidth = 7680,
    })
    invalidParentEnv.UIParent.GetWidth = function() return math.huge end
    local ok, err = pcall(invalidParentEnv.__fireEvent, "PLAYER_ENTERING_WORLD")
    check("position.ui_bound.invalid_parent.no_error", ok, err)
    eq("position.ui_bound.invalid_parent.fallback", invalidParentEnv.StatsProFrame.points[1][4], 0)
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
    eq("lifecycle.pew_legacy_priority.font_size", activeSettings(legacyEnv).fontSize, 17)
    assertColor("lifecycle.pew_legacy_priority.color_copied", activeSettings(legacyEnv).colors.crit, 0.2, 0.3, 0.4)
    eq("lifecycle.pew_legacy_priority.foreign_version_ignored",
        legacyEnv.StatsProDB.dbVersion, legacyTest.currentDBVersion())
    eq("lifecycle.pew_legacy_priority.minimap_ignored", activeSettings(legacyEnv).minimapPos, nil)
    eq("lifecycle.pew_legacy_priority.runtime_flag_ignored", activeSettings(legacyEnv).updateNoticeShown, nil)
    eq("lifecycle.pew_legacy_priority.unknown_ignored", activeSettings(legacyEnv).privatePayload, nil)
    eq("lifecycle.pew_legacy_priority.unknown_color_ignored", activeSettings(legacyEnv).colors.unknown, nil)
    legacySource.colors.crit.r = 0.9
    near("lifecycle.pew_legacy_priority.deep_copy", activeSettings(legacyEnv).colors.crit.r, 0.2)

    local fallbackEnv = loadStatsPro("enUS", {
        statsProDB = {},
        swiftStatsLocalDB = { fontSize = 19 },
    })
    fireEvent("lifecycle.pew_legacy_local_fallback.fire", fallbackEnv, "PLAYER_ENTERING_WORLD")
    eq("lifecycle.pew_legacy_local_fallback.font_size", activeSettings(fallbackEnv).fontSize, 19)
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
        activeSettings(legacyEnv).fontSize, 17)
    eq("lifecycle.pew_swiftstats_foreign_db_version_ignored.non_upstream_locale_ignored",
        accountSettings(legacyEnv).forceLocale, "auto")
    eq("lifecycle.pew_swiftstats_foreign_db_version_ignored.main_stat",
        activeSettings(legacyEnv).showMainStat, true)
    assertColor("lifecycle.pew_swiftstats_foreign_db_version_ignored.main_color",
        activeSettings(legacyEnv).colors.mainStat, 0.2, 0.3, 0.4)
    eq("lifecycle.pew_swiftstats_foreign_db_version_ignored.primary_removed",
        activeSettings(legacyEnv).colors.primary, nil)

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
        activeSettings(localEnv).fontSize, 14)
    eq("lifecycle.pew_swiftstatslocal_future_db_version_refused.repair_default",
        activeSettings(localEnv).showRepairCost, false)
end

do
    local idempotentSource = { fontSize = 18 }
    local idempotentEnv = loadStatsPro("enUS", {
        statsProDB = {},
        swiftStatsDB = idempotentSource,
    })
    fireEvent("lifecycle.pew_idempotent.first", idempotentEnv, "PLAYER_ENTERING_WORLD")
    activeSettings(idempotentEnv).fontSize = 22
    idempotentSource.fontSize = 9
    fireEvent("lifecycle.pew_idempotent.second", idempotentEnv, "PLAYER_ENTERING_WORLD")
    eq("lifecycle.pew_idempotent.no_recapture", activeSettings(idempotentEnv).fontSize, 22)
end

do
    local existingEnv = loadStatsPro("enUS", {
        statsProDB = { fontSize = 22 },
        swiftStatsDB = { fontSize = 17 },
    })
    fireEvent("legacy_import.existing_db_pew.fire", existingEnv, "PLAYER_ENTERING_WORLD")
    eq("legacy_import.existing_db_pew.no_unprompted_overwrite", activeSettings(existingEnv).fontSize, 22)
    eq("legacy_import.existing_db_pew.no_popup", existingEnv.__staticPopupShows, 0)
end

do
    local fallbackEnv = loadStatsPro("enUS", {
        statsProDB = {},
        swiftStatsDB = { updateNoticeShown = true, minimapPos = 45 },
        swiftStatsLocalDB = { dbVersion = test.currentDBVersion() - 1, fontSize = 18 },
    })
    fireEvent("legacy_import.ignored_public_falls_back_local.fire", fallbackEnv, "PLAYER_ENTERING_WORLD")
    eq("legacy_import.ignored_public_falls_back_local.font_size", activeSettings(fallbackEnv).fontSize, 18)
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
    eq("legacy_import.invalid_groups.supported_scalar_imported", activeSettings(invalidEnv).fontSize, 18)
    eq("legacy_import.invalid_groups.position_rejected_atomically", activeSettings(invalidEnv).point, "CENTER")
    eq("legacy_import.invalid_groups.position_x_default", activeSettings(invalidEnv).xOfs, 0)
    assertColor("legacy_import.invalid_groups.color_rejected", activeSettings(invalidEnv).colors.crit, 1, 0, 0)
end

do
    local wideImportEnv = loadStatsPro("enUS", {
        statsProDB = {},
        swiftStatsDB = {
            point = "CENTER",
            relativePoint = "CENTER",
            xOfs = 3500,
            yOfs = -120,
        },
        uiParentWidth = 7680,
        uiParentHeight = 4320,
    })
    fireEvent("legacy_import.ui_bound.wide.pew", wideImportEnv, "PLAYER_ENTERING_WORLD")
    eq("legacy_import.ui_bound.wide.settings_x", activeSettings(wideImportEnv).xOfs, 3500)
    eq("legacy_import.ui_bound.wide.frame_x", wideImportEnv.StatsProFrame.points[1][4], 3500)

    local tallImportEnv = loadStatsPro("enUS", {
        statsProDB = {},
        swiftStatsLocalDB = {
            defensive_point = "CENTER",
            defensive_relativePoint = "CENTER",
            defensive_xOfs = 80,
            defensive_yOfs = 3500,
        },
        uiParentWidth = 1920,
        uiParentHeight = 5000,
    })
    fireEvent("legacy_import.ui_bound.tall_defensive.pew", tallImportEnv, "PLAYER_ENTERING_WORLD")
    eq("legacy_import.ui_bound.tall_defensive.settings_y",
        activeSettings(tallImportEnv).defensive_yOfs, 3500)
    eq("legacy_import.ui_bound.tall_defensive.frame_y",
        tallImportEnv.StatsProDefensiveFrame.points[1][5], 3500)

    for caseName, invalidOffset in pairs({
        nan = 0 / 0,
        positive_infinity = math.huge,
        negative_infinity = -math.huge,
    }) do
        local invalidOffsetEnv = loadStatsPro("enUS", {
            statsProDB = {},
            swiftStatsDB = {
                fontSize = 18,
                point = "TOPLEFT",
                relativePoint = "TOPLEFT",
                xOfs = invalidOffset,
                yOfs = 25,
            },
            uiParentWidth = 7680,
            uiParentHeight = 4320,
        })
        fireEvent("legacy_import.ui_bound.atomic_invalid." .. caseName,
            invalidOffsetEnv, "PLAYER_ENTERING_WORLD")
        eq("legacy_import.ui_bound.atomic_invalid." .. caseName .. ".scalar",
            activeSettings(invalidOffsetEnv).fontSize, 18)
        eq("legacy_import.ui_bound.atomic_invalid." .. caseName .. ".point",
            activeSettings(invalidOffsetEnv).point, "CENTER")
        eq("legacy_import.ui_bound.atomic_invalid." .. caseName .. ".x",
            activeSettings(invalidOffsetEnv).xOfs, 0)
        eq("legacy_import.ui_bound.atomic_invalid." .. caseName .. ".y",
            activeSettings(invalidOffsetEnv).yOfs, 0)
    end
end

do
    local missingEnv = loadStatsPro("enUS")
    fireEvent("legacy_import.missing_source.pew", missingEnv, "PLAYER_ENTERING_WORLD")
    local beforeFontSize = activeSettings(missingEnv).fontSize
    clearPrints(missingEnv)
    slash("legacy_import.missing_source.request", missingEnv, "import")
    eq("legacy_import.missing_source.no_popup", missingEnv.__staticPopupShows, 0)
    eq("legacy_import.missing_source.no_mutation", activeSettings(missingEnv).fontSize, beforeFontSize)
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
    eq("legacy_import.secret_source.no_mutation", activeSettings(secretEnv).fontSize, 20)
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
    eq("legacy_import.secret_root.no_mutation", activeSettings(secretRootEnv).fontSize, 20)
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
    eq("legacy_import.inaccessible_root.no_mutation", activeSettings(inaccessibleEnv).fontSize, 20)
end

do
    local secretColors = { crit = { r = 0.2, g = 0.3, b = 0.4 } }
    local nestedSecretEnv, _, nestedSecretTest = loadStatsPro("enUS", withProfileIdentity({
        statsProDB = { fontSize = 20 },
        swiftStatsDB = { fontSize = 18, colors = secretColors },
        issecrettable = function(value) return value == secretColors end,
    }))
    fireEvent("legacy_import.secret_nested_table.pew", nestedSecretEnv, "PLAYER_ENTERING_WORLD")
    slash("legacy_import.secret_nested_table.request", nestedSecretEnv, "import")
    nestedSecretEnv.__acceptStaticPopup()
    eq("legacy_import.secret_nested_table.scalar_imported",
        nestedSecretTest.profileState().settings.fontSize, 18)
    assertColor("legacy_import.secret_nested_table.color_rejected",
        nestedSecretTest.profileState().settings.colors.crit, 1, 0, 0)
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
    local lateEnv, _, lateTest = loadStatsPro(
        "enUS", withProfileIdentity({ statsProDB = {} }))
    fireEvent("legacy_import.late.pew_without_source", lateEnv, "PLAYER_ENTERING_WORLD")
    eq("legacy_import.late.defaults_initialized", activeSettings(lateEnv).fontSize, 14)
    lateEnv.SwiftStatsDB = source
    fireEvent("legacy_import.late.second_pew", lateEnv, "PLAYER_ENTERING_WORLD")
    lateEnv.__flushTimers(0.1)
    eq("legacy_import.late.second_pew_no_auto_overwrite", activeSettings(lateEnv).fontSize, 14)

    slash("legacy_import.late.request_cancel", lateEnv, "import")
    eq("legacy_import.late.popup_shown", lateEnv.__staticPopupShows, 1)
    eq("legacy_import.late.request_no_mutation", activeSettings(lateEnv).fontSize, 14)
    lateEnv.__cancelStaticPopup()
    eq("legacy_import.late.cancel_no_mutation", activeSettings(lateEnv).fontSize, 14)
    eq("legacy_import.late.cancel_no_reload", lateEnv.__reloadUICalls, 0)

    local rootRef = lateEnv.StatsProDB
    local oldActive = lateTest.profileState()
    local oldProfileID = oldActive.profileID
    local oldProfileRef = rootRef.profiles[oldProfileID]
    local oldSettingsBefore = deepCopy(oldProfileRef.settings)
    local nextProfileIDBefore = rootRef.account.nextProfileID
    local accountDefaultBefore = rootRef.account.defaultProfileID
    local accountLocaleBefore = rootRef.account.forceLocale
    local accountIntervalBefore = rootRef.account.updateInterval
    local rolesRef = rootRef.roleTemplates
    local assignmentBefore = rootRef.characters["Player-1-IMPORT"].specProfiles[73]
    local shadowFontSize = rawget(rootRef, "fontSize")
    local shadowColors = rawget(rootRef, "colors")
    slash("legacy_import.late.request_accept", lateEnv, "import")
    eq("legacy_import.late.second_popup_shown", lateEnv.__staticPopupShows, 2)
    source.fontSize = 8
    source.xOfs = 999
    source.colors.primary.r = 0.9
    lateEnv.__acceptStaticPopup()
    local imported = lateTest.profileState()
    eq("legacy_import.late.accept_no_reload", lateEnv.__reloadUICalls, 0)
    check("legacy_import.late.accept_new_profile", imported.profileID ~= oldProfileID)
    eq("legacy_import.late.accept_new_profile_name",
        rootRef.profiles[imported.profileID].name, "SwiftStats Import")
    eq("legacy_import.late.accept_current_assignment",
        rootRef.characters["Player-1-IMPORT"].specProfiles[73], imported.profileID)
    eq("legacy_import.late.accept_old_assignment_was_active", assignmentBefore, oldProfileID)
    eq("legacy_import.late.accept_old_profile_identity",
        rawequal(rootRef.profiles[oldProfileID], oldProfileRef), true)
    assertDeepEqual("legacy_import.late.accept_old_profile_unchanged",
        oldProfileRef.settings, oldSettingsBefore)
    eq("legacy_import.late.accept_snapshot_font_size", imported.settings.fontSize, 19)
    eq("legacy_import.late.accept_snapshot_x", imported.settings.xOfs, 123)
    eq("legacy_import.late.accept_primary_toggle_migrated", imported.settings.showMainStat, true)
    assertColor("legacy_import.late.accept_primary_color_migrated",
        imported.settings.colors.mainStat, 0.2, 0.3, 0.4)
    assertColor("legacy_import.late.accept_crit_color",
        imported.settings.colors.crit, 0.4, 0.5, 0.6)
    eq("legacy_import.late.accept_unknown_ignored", imported.settings.unknown, nil)
    eq("legacy_import.late.accept_minimap_ignored", imported.settings.minimapPos, nil)
    eq("legacy_import.late.accept_transient_ignored", imported.settings.fontBeforeAutoSwitch, nil)
    eq("legacy_import.late.accept_unknown_color_ignored", imported.settings.colors.evil, nil)
    eq("legacy_import.late.accept_account_id_advanced",
        rootRef.account.nextProfileID, nextProfileIDBefore + 1)
    eq("legacy_import.late.accept_account_default_unchanged",
        rootRef.account.defaultProfileID, accountDefaultBefore)
    eq("legacy_import.late.accept_account_locale_unchanged",
        rootRef.account.forceLocale, accountLocaleBefore)
    near("legacy_import.late.accept_account_interval_unchanged",
        rootRef.account.updateInterval, accountIntervalBefore)
    eq("legacy_import.late.accept_current_version",
        lateEnv.StatsProDB.dbVersion, lateTest.currentDBVersion())
    eq("legacy_import.late.accept_keeps_root", rawequal(lateEnv.StatsProDB, rootRef), true)
    eq("legacy_import.late.accept_keeps_roles", rawequal(rootRef.roleTemplates, rolesRef), true)
    eq("legacy_import.late.accept_keeps_shadow_font", rawget(rootRef, "fontSize"), shadowFontSize)
    eq("legacy_import.late.accept_keeps_shadow_colors", rawget(rootRef, "colors"), shadowColors)
    local loadedPoint = lateEnv.StatsProFrame.points[1]
    eq("legacy_import.late.accept_position_loaded.point", loadedPoint[1], "TOPLEFT")
    eq("legacy_import.late.accept_position_loaded.x", loadedPoint[4], 123)
    fireEvent("legacy_import.late.logout_preserves_imported_position", lateEnv, "PLAYER_LOGOUT")
    eq("legacy_import.late.logout_position_x", imported.settings.xOfs, 123)
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
    eq("legacy_import.future_destination.no_mutation", activeSettings(futureEnv).fontSize, 23)
    eq("legacy_import.future_destination.message",
        printContains(futureEnv, "read-only"), true)
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
    eq("legacy_import.secret_local_version.no_mutation", activeSettings(localVersionEnv).fontSize, 20)
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
    eq("legacy_import.secret_destination.no_mutation", activeSettings(secretDestinationEnv).fontSize, 23)
    eq("legacy_import.secret_destination.no_tonumber", secretTonumberCalls, 0)
    eq("legacy_import.secret_destination.message",
        printContains(secretDestinationEnv, "read-only"), true)

    secretTonumberCalls = 0
    local acceptEnv = loadStatsPro("enUS", withProfileIdentity({
        statsProDB = { fontSize = 23 },
        swiftStatsDB = { fontSize = 17 },
        issecretvalue = function(value) return value == secretVersion end,
        tonumber = guardedTonumber,
    }))
    fireEvent("legacy_import.secret_destination_accept.pew", acceptEnv, "PLAYER_ENTERING_WORLD")
    slash("legacy_import.secret_destination_accept.request", acceptEnv, "import")
    acceptEnv.StatsProDB.dbVersion = secretVersion
    clearPrints(acceptEnv)
    acceptEnv.__acceptStaticPopup()
    eq("legacy_import.secret_destination_accept.no_reload", acceptEnv.__reloadUICalls, 0)
    eq("legacy_import.secret_destination_accept.no_mutation", activeSettings(acceptEnv).fontSize, 23)
    eq("legacy_import.secret_destination_accept.no_tonumber", secretTonumberCalls, 0)
    eq("legacy_import.secret_destination_accept.message",
        printContains(acceptEnv, "read-only"), true)
end

do
    local applyFailureEnv, _, applyFailureTest = loadStatsPro("enUS", withProfileIdentity({
        statsProDB = {
            dbVersion = 9,
            forceLocale = "enUS",
            updateInterval = 0.85,
            point = "BOTTOM",
            relativePoint = "BOTTOM",
            xOfs = 45,
            yOfs = 67,
            fontSize = 20,
            colors = { crit = { r = 0.15, g = 0.25, b = 0.35 } },
            rollbackUnknown = { child = { value = 91 } },
        },
        swiftStatsDB = {
            fontSize = 17,
            updateInterval = 0.2,
            point = "TOPLEFT",
            relativePoint = "TOPLEFT",
            xOfs = 222,
            yOfs = -333,
            colors = {
                primary = { r = 0.8, g = 0.7, b = 0.6 },
                crit = { r = 0.9, g = 0.8, b = 0.7 },
            },
        },
    }))
    fireEvent("legacy_import.apply_failure.pew", applyFailureEnv, "PLAYER_ENTERING_WORLD")
    local root = applyFailureEnv.StatsProDB
    local state = applyFailureTest.profileState()
    local settings = state.settings
    local rootRef = root
    local accountRef = root.account
    local profilesRef = root.profiles
    local settingsRef = settings
    local rolesRef = root.roleTemplates
    local charactersRef = root.characters
    local shadowColorsRef = root.colors
    local shadowUnknownRef = root.rollbackUnknown
    local before = deepCopy(root)
    local settingsBefore = deepCopy(settings)
    local activeProfileID = state.profileID
    slash("legacy_import.apply_failure.request", applyFailureEnv, "import")
    applyFailureTest.profileOps.setFailureStage("apply")
    clearPrints(applyFailureEnv)
    applyFailureEnv.__acceptStaticPopup()
    eq("legacy_import.apply_failure.no_reload", applyFailureEnv.__reloadUICalls, 0)
    eq("legacy_import.apply_failure.root_identity", rawequal(applyFailureEnv.StatsProDB, rootRef), true)
    eq("legacy_import.apply_failure.account_identity", rawequal(root.account, accountRef), true)
    eq("legacy_import.apply_failure.profiles_identity", rawequal(root.profiles, profilesRef), true)
    eq("legacy_import.apply_failure.settings_identity",
        rawequal(applyFailureTest.profileState().settings, settingsRef), true)
    eq("legacy_import.apply_failure.roles_identity", rawequal(root.roleTemplates, rolesRef), true)
    eq("legacy_import.apply_failure.characters_identity", rawequal(root.characters, charactersRef), true)
    eq("legacy_import.apply_failure.shadow_colors_identity", rawequal(root.colors, shadowColorsRef), true)
    eq("legacy_import.apply_failure.shadow_unknown_identity",
        rawequal(root.rollbackUnknown, shadowUnknownRef), true)
    assertDeepEqual("legacy_import.apply_failure.full_root_restored", root, before)
    assertDeepEqual("legacy_import.apply_failure.settings_restored", settings, settingsBefore)
    eq("legacy_import.apply_failure.active_profile_restored",
        applyFailureTest.profileState().profileID, activeProfileID)
    eq("legacy_import.apply_failure.position_restored",
        applyFailureEnv.StatsProFrame.points[1][1], "BOTTOM")
    eq("legacy_import.apply_failure.failure_message",
        printContains(applyFailureEnv, "profiles and assignments were preserved"), true)
    eq("legacy_import.apply_failure.no_success_message",
        printContains(applyFailureEnv, "settings imported"), false)
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
    eq("lifecycle.logout_saves_positions.main_point", activeSettings(logoutEnv).point, "TOPLEFT")
    eq("lifecycle.logout_saves_positions.main_x", activeSettings(logoutEnv).xOfs, 41)
    eq("lifecycle.logout_saves_positions.defensive_point", activeSettings(logoutEnv).defensive_point, "BOTTOMRIGHT")
    eq("lifecycle.logout_saves_positions.defensive_x", activeSettings(logoutEnv).defensive_xOfs, -17)

    local nilPointEnv = loadStatsPro("enUS", {
        statsProDB = { point = "BOTTOM", xOfs = 7, yOfs = 8 },
    })
    nilPointEnv.StatsProFrame.noPoint = true
    fireEvent("lifecycle.logout_nil_point_preserves_db.fire", nilPointEnv, "PLAYER_LOGOUT")
    eq("lifecycle.logout_nil_point_preserves_db.point", activeSettings(nilPointEnv).point, "BOTTOM")
    eq("lifecycle.logout_nil_point_preserves_db.x", activeSettings(nilPointEnv).xOfs, 7)

    local profileLogoutEnv = loadStatsPro("enUS", {
        statsProDB = { dbVersion = 9, point = "CENTER", xOfs = 7, yOfs = 8 },
    })
    fireEvent("profiles.logout.pew", profileLogoutEnv, "PLAYER_ENTERING_WORLD")
    profileLogoutEnv.StatsProFrame:ClearAllPoints()
    profileLogoutEnv.StatsProFrame:SetPoint("TOPLEFT", profileLogoutEnv.UIParent, "TOPLEFT", 41, -42)
    fireEvent("profiles.logout.save", profileLogoutEnv, "PLAYER_LOGOUT")
    eq("profiles.logout.profile_position", activeSettings(profileLogoutEnv).xOfs, 41)
    eq("profiles.logout.shadow_position_unchanged", profileLogoutEnv.StatsProDB.xOfs, 7)
end

do
    local resetEnv, _, resetTest = loadStatsPro("enUS", withProfileIdentity({
        statsProDB = {
            dbVersion = 9,
            forceLocale = "ruRU",
            updateInterval = 0.85,
            isVisible = false,
            scale = 1.7,
            colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } },
        },
    }))
    fireEvent("profiles.reset.pew", resetEnv, "PLAYER_ENTERING_WORLD")
    local root = resetEnv.StatsProDB
    local activeProfileID = resetTest.profileState().profileID
    local active = resetTest.profileState().settings
    root.profiles.p4 = { name = "Other", settings = deepCopy(active) }
    root.account.nextProfileID = 5
    root.profiles.p4.settings.scale = 1.3
    local otherBefore = deepCopy(root.profiles.p4)
    local accountBefore = deepCopy(root.account)
    local shadowBefore = {
        forceLocale = root.forceLocale,
        updateInterval = root.updateInterval,
        isVisible = root.isVisible,
        scale = root.scale,
        colors = root.colors,
    }
    local beforeRequest = deepCopy(root)
    slash("profiles.reset.request", resetEnv, "reset")
    eq("profiles.reset.request_popup", resetEnv.__staticPopupShows, 1)
    assertDeepEqual("profiles.reset.request_zero_writes", root, beforeRequest)
    check("profiles.reset.shared_warning_name",
        resetEnv.__lastStaticPopup.definition.text:find(
            root.profiles[activeProfileID].name, 1, true) ~= nil)
    resetEnv.__cancelStaticPopup()
    assertDeepEqual("profiles.reset.cancel_zero_writes", root, beforeRequest)

    slash("profiles.reset.active_only", resetEnv, "reset")
    resetEnv.__acceptStaticPopup()
    local resetSettings = resetTest.profileState().settings
    eq("profiles.reset.active_id_preserved",
        resetTest.profileState().profileID, activeProfileID)
    eq("profiles.reset.active_visible_default", resetSettings.isVisible, true)
    near("profiles.reset.active_scale_default", resetSettings.scale, 1)
    assertColor("profiles.reset.active_color_default", resetSettings.colors.crit, 1, 0, 0)
    assertDeepEqual("profiles.reset.other_profile_unchanged", root.profiles.p4, otherBefore)
    assertDeepEqual("profiles.reset.account_unchanged", root.account, accountBefore)
    eq("profiles.reset.shadow_locale", root.forceLocale, shadowBefore.forceLocale)
    eq("profiles.reset.shadow_interval", root.updateInterval, shadowBefore.updateInterval)
    eq("profiles.reset.shadow_visible", root.isVisible, shadowBefore.isVisible)
    eq("profiles.reset.shadow_scale", root.scale, shadowBefore.scale)
    eq("profiles.reset.shadow_colors_identity", rawequal(root.colors, shadowBefore.colors), true)
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
    local staleEnv, _, staleTest = loadStatsPro("enUS", withProfileIdentity())
    fireEvent("appearance.presets.stale.pew", staleEnv, "PLAYER_ENTERING_WORLD")
    local service = staleTest.appearancePresets
    local ok = service.startPreview("midnight")
    eq("appearance.presets.stale.in_place_preview", ok, true)
    local settings = staleTest.profileState().settings
    settings.textAlpha = 65
    local result, reason = service.applyPreview()
    eq("appearance.presets.stale.in_place_rejected", result, false)
    eq("appearance.presets.stale.in_place_reason", reason, "stale")
    eq("appearance.presets.stale.in_place_preserved", settings.textAlpha, 65)
    eq("appearance.presets.stale.in_place_closed", service.state().active, false)

    ok = service.startPreview("midnight")
    eq("appearance.presets.stale.replacement_preview", ok, true)
    local state = staleTest.profileState()
    local replacement = deepCopy(state.settings)
    state.root.profiles[state.profileID].settings = replacement
    result, reason = service.applyPreview()
    eq("appearance.presets.stale.replacement_rejected", result, false)
    eq("appearance.presets.stale.replacement_reason", reason, "stale")
    eq("appearance.presets.stale.replacement_preserved",
        state.root.profiles[state.profileID].settings, replacement)

    local restoreEnv, restoreAddon, restoreTest = loadStatsPro("enUS", withProfileIdentity())
    fireEvent("appearance.presets.restore.pew", restoreEnv, "PLAYER_ENTERING_WORLD")
    service = restoreTest.appearancePresets
    ok = service.startPreview("midnight")
    eq("appearance.presets.restore.preview", ok, true)
    service.setRuntimeFailureCount(1)
    result, reason = service.cancelPreview()
    eq("appearance.presets.restore.cancel_rejected", result, false)
    eq("appearance.presets.restore.cancel_reason", reason, "restore-failed")
    eq("appearance.presets.restore.session_preserved", service.state().active, true)
    eq("appearance.presets.restore.retry", service.cancelPreview(), true)
    ok = service.startPreview("midnight")
    eq("appearance.presets.restore.baseline_click_preview", ok, true)
    service.setRuntimeFailureCount(1)
    result, reason = service.startPreview("default")
    eq("appearance.presets.restore.baseline_click_rejected", result, false)
    eq("appearance.presets.restore.baseline_click_reason", reason, "restore-failed")
    eq("appearance.presets.restore.baseline_click_session", service.state().active, true)
    eq("appearance.presets.restore.baseline_click_retry", service.cancelPreview(), true)
    ok = service.startPreview("midnight")
    eq("appearance.presets.restore.modal_preview", ok, true)
    service.setRuntimeFailureCount(1)
    result, reason = service.startPreview("monochrome")
    eq("appearance.presets.restore.modal_close_rejected", result, false)
    eq("appearance.presets.restore.modal_close_reason", reason, "close-failed")
    eq("appearance.presets.restore.modal_session", service.state().active, true)
    eq("appearance.presets.restore.modal_retry", service.cancelPreview(), true)
    restoreAddon:OpenConfigMenu()
    ok = service.startPreview("high-contrast")
    eq("appearance.presets.restore.manual_preview", ok, true)
    local settingsBeforeManual = deepCopy(restoreTest.profileState().settings)
    service.setRuntimeFailureCount(1)
    restoreEnv.StatsProFontSlider:SetValue(15)
    userInteract("appearance.presets.restore.manual_change",
        restoreEnv.StatsProFontSlider, "OnValueChanged", 15)
    assertDeepEqual("appearance.presets.restore.manual_zero_writes",
        restoreTest.profileState().settings, settingsBeforeManual)
    eq("appearance.presets.restore.manual_session", service.state().active, true)
    eq("appearance.presets.restore.manual_retry", service.cancelPreview(), true)
    ok = service.startPreview("midnight")
    eq("appearance.presets.restore.config_hide_preview", ok, true)
    service.setRuntimeFailureCount(1)
    restoreEnv.StatsProConfigFrame:Hide()
    eq("appearance.presets.restore.config_hide_forced", service.state().active, false)
    assertDeepEqual("appearance.presets.restore.config_hide_zero_writes",
        restoreTest.profileState().settings, settingsBeforeManual)
end

do
    local defaultEnv, _, defaultTest = loadStatsPro("enUS", withProfileIdentity())
    fireEvent("appearance.presets.default_round_trip.pew", defaultEnv, "PLAYER_ENTERING_WORLD")
    local service = defaultTest.appearancePresets
    local settings = defaultTest.profileState().settings
    settings.showRating = false
    settings.showPercentage = false
    settings.labelStyle = "short"
    settings.targetSnapshot = "raid"
    local ok = service.startPreview("midnight")
    eq("appearance.presets.default_round_trip.midnight_preview", ok, true)
    ok = service.applyPreview()
    eq("appearance.presets.default_round_trip.midnight_apply", ok, true)
    eq("appearance.presets.default_round_trip.midnight_current", service.currentID(), "midnight")
    ok = service.startPreview("default")
    eq("appearance.presets.default_round_trip.default_preview", ok, true)
    ok = service.applyPreview()
    eq("appearance.presets.default_round_trip.default_apply", ok, true)
    settings = defaultTest.profileState().settings
    eq("appearance.presets.default_round_trip.default_current", service.currentID(), "default")
    eq("appearance.presets.default_round_trip.font_size", settings.fontSize, 14)
    eq("appearance.presets.default_round_trip.text_alpha", settings.textAlpha, 100)
    eq("appearance.presets.default_round_trip.panel_background", settings.panelBackgroundAlpha, 15)
    eq("appearance.presets.default_round_trip.outline", settings.textOutlineStyle, "outline")
    eq("appearance.presets.default_round_trip.match_value_color", settings.matchValueColorToStat, true)
    eq("appearance.presets.default_round_trip.preserve_rating", settings.showRating, false)
    eq("appearance.presets.default_round_trip.preserve_percentage", settings.showPercentage, false)
    eq("appearance.presets.default_round_trip.preserve_label_style", settings.labelStyle, "short")
    eq("appearance.presets.default_round_trip.preserve_target_snapshot", settings.targetSnapshot, "raid")
end

do
    local inCombat = false
    local editEnv, editAddon, editTest = loadStatsPro("enUS", {
        statsProDB = { panelBackgroundAlpha = 0 },
        inCombatLockdown = function() return inCombat end,
    })
    fireEvent("panel.edit.pew", editEnv, "PLAYER_ENTERING_WORLD")
    local initialRoot = deepCopy(editEnv.StatsProDB)
    local initialVisual = editTest.panelVisualState()
    local state = editTest.panelEditAffordanceState()
    eq("panel.edit.closed.requested", state.requested, false)
    eq("panel.edit.closed.main_hidden", state.main.visible, false)
    eq("panel.edit.closed.side_hidden", state.side.visible, false)
    eq("panel.edit.closed.side_content_hidden", state.side.frameShown, false)

    editAddon:OpenConfigMenu()
    state = editTest.panelEditAffordanceState()
    eq("panel.edit.first_open.config_shown", state.configShown, true)
    eq("panel.edit.first_open.requested", state.requested, true)
    eq("panel.edit.first_open.main_visible", state.main.visible, true)
    eq("panel.edit.first_open.side_visible_when_content_hidden", state.side.visible, true)
    eq("panel.edit.first_open.side_content_stays_hidden", state.side.frameShown, false)
    eq("panel.edit.first_open.main_parent", state.main.parentIsUIParent, true)
    eq("panel.edit.first_open.side_parent", state.side.parentIsUIParent, true)
    eq("panel.edit.first_open.main_outline_clickthrough", state.main.outlineMouseEnabled, false)
    eq("panel.edit.first_open.side_outline_clickthrough", state.side.outlineMouseEnabled, false)
    eq("panel.edit.first_open.main_handle_mouse", state.main.handleMouseEnabled, true)
    eq("panel.edit.first_open.side_handle_mouse", state.side.handleMouseEnabled, true)
    check("panel.edit.first_open.main_border_visible", (state.main.borderAlpha or 0) > 0)
    check("panel.edit.first_open.side_border_visible", (state.side.borderAlpha or 0) > 0)
    local openVisual = editTest.panelVisualState()
    near("panel.edit.zero_background.main", openVisual.mainBackgroundTextureAlpha, 0)
    near("panel.edit.zero_background.side", openVisual.sideBackgroundTextureAlpha, 0)
    near("panel.edit.decoration_keeps_main_width", state.main.frameWidth, initialVisual.mainFrameWidth)
    near("panel.edit.decoration_keeps_main_height", state.main.frameHeight, initialVisual.mainFrameHeight)
    near("panel.edit.decoration_keeps_side_width", state.side.frameWidth, initialVisual.sideFrameWidth)
    near("panel.edit.decoration_keeps_side_height", state.side.frameHeight, initialVisual.sideFrameHeight)
    assertDeepEqual("panel.edit.open_no_db_write", editEnv.StatsProDB, initialRoot)

    editAddon:OpenConfigMenu()
    state = editTest.panelEditAffordanceState()
    eq("panel.edit.toggle_close.config_hidden", state.configShown, false)
    eq("panel.edit.toggle_close.main_hidden", state.main.visible, false)
    eq("panel.edit.toggle_close.side_hidden", state.side.visible, false)
    assertDeepEqual("panel.edit.close_no_db_write", editEnv.StatsProDB, initialRoot)

    editAddon:OpenConfigMenu()
    state = editTest.panelEditAffordanceState()
    eq("panel.edit.reopen.main_visible", state.main.visible, true)
    eq("panel.edit.reopen.side_visible", state.side.visible, true)

    local beforeLock = deepCopy(editEnv.StatsProDB)
    clickCheckbox("panel.edit.lock_on", editEnv.StatsProLockCheck, true)
    state = editTest.panelEditAffordanceState()
    eq("panel.edit.lock_on.cached", state.locked, true)
    eq("panel.edit.lock_on.main_hidden", state.main.visible, false)
    eq("panel.edit.lock_on.side_hidden", state.side.visible, false)
    local expectedLocked = deepCopy(beforeLock)
    activeSettings(expectedLocked).isLocked = true
    assertDeepEqual("panel.edit.lock_on_only_intentional_write", editEnv.StatsProDB, expectedLocked)

    clickCheckbox("panel.edit.lock_off", editEnv.StatsProLockCheck, false)
    state = editTest.panelEditAffordanceState()
    eq("panel.edit.lock_off.cached", state.locked, false)
    eq("panel.edit.lock_off.main_visible", state.main.visible, true)
    eq("panel.edit.lock_off.side_visible", state.side.visible, true)
    assertDeepEqual("panel.edit.lock_roundtrip", editEnv.StatsProDB, beforeLock)

    local settings = activeSettings(editEnv)
    settings.displayMode = "split"
    settings.splitCharacter = false
    settings.splitItemLevel = false
    settings.splitOffensive = false
    settings.splitTertiary = false
    settings.splitDefensive = false
    settings.splitDurability = false
    settings.splitRepairCost = false
    editTest.cacheSettings()
    editAddon:RunUpdateStatsSafe()
    state = editTest.panelEditAffordanceState()
    eq("panel.edit.split_empty_side.content_hidden", state.side.frameShown, false)
    eq("panel.edit.split_empty_side.affordance_visible", state.side.visible, true)
    eq("panel.edit.split.main_affordance_visible", state.main.visible, true)

    settings.displayMode = "flat"
    settings.splitItemLevel = true
    settings.splitDefensive = true
    settings.splitDurability = true
    settings.splitRepairCost = true
    editTest.cacheSettings()
    editAddon:RunUpdateStatsSafe()
    state = editTest.panelEditAffordanceState()
    eq("panel.edit.flat.side_content_hidden", state.side.frameShown, false)
    eq("panel.edit.flat.side_affordance_visible", state.side.visible, true)

    settings.isVisible = false
    editTest.cacheSettings()
    editAddon:RunUpdateStatsSafe()
    state = editTest.panelEditAffordanceState()
    eq("panel.edit.master_hidden.main_content", state.main.frameShown, false)
    eq("panel.edit.master_hidden.side_content", state.side.frameShown, false)
    eq("panel.edit.master_hidden.main_affordance", state.main.visible, true)
    eq("panel.edit.master_hidden.side_affordance", state.side.visible, true)
    settings.isVisible = true
    editTest.cacheSettings()
    editAddon:RunUpdateStatsSafe()

    local beforeCombat = deepCopy(editEnv.StatsProDB)
    inCombat = true
    fireEvent("panel.edit.combat_enter", editEnv, "PLAYER_REGEN_DISABLED")
    state = editTest.panelEditAffordanceState()
    eq("panel.edit.combat_enter.config_stays_open", state.configShown, true)
    eq("panel.edit.combat_enter.main_hidden", state.main.visible, false)
    eq("panel.edit.combat_enter.side_hidden", state.side.visible, false)
    local startCalls = state.main.startMovingCalls
    editTest.firePanelEditHandleForSmoke("main", "OnDragStart")
    state = editTest.panelEditAffordanceState()
    eq("panel.edit.combat_direct_drag_blocked", state.main.startMovingCalls, startCalls)
    fireEvent("panel.edit.combat_enter_idempotent", editEnv, "PLAYER_REGEN_DISABLED")
    inCombat = false
    fireEvent("panel.edit.combat_leave", editEnv, "PLAYER_REGEN_ENABLED")
    state = editTest.panelEditAffordanceState()
    eq("panel.edit.combat_leave.main_visible", state.main.visible, true)
    eq("panel.edit.combat_leave.side_visible", state.side.visible, true)
    assertDeepEqual("panel.edit.combat_roundtrip_no_db_write", editEnv.StatsProDB, beforeCombat)

    startCalls = state.main.startMovingCalls
    local stopCalls = state.main.stopMovingCalls
    editTest.firePanelEditHandleForSmoke("main", "OnDragStart")
    state = editTest.panelEditAffordanceState()
    eq("panel.edit.handle_drag_started", state.main.dragging, true)
    eq("panel.edit.handle_drag_moves_panel", state.main.startMovingCalls, startCalls + 1)
    inCombat = true
    fireEvent("panel.edit.combat_stops_drag", editEnv, "PLAYER_REGEN_DISABLED")
    state = editTest.panelEditAffordanceState()
    eq("panel.edit.combat_stops_drag.dragging", state.main.dragging, false)
    eq("panel.edit.combat_stops_drag.stop_call", state.main.stopMovingCalls, stopCalls + 1)
    eq("panel.edit.combat_stops_drag.affordance_hidden", state.main.visible, false)

    editEnv.StatsProConfigFrame:Hide()
    inCombat = false
    fireEvent("panel.edit.closed_combat_leave", editEnv, "PLAYER_REGEN_ENABLED")
    state = editTest.panelEditAffordanceState()
    eq("panel.edit.closed_combat_leave.requested", state.requested, false)
    eq("panel.edit.closed_combat_leave.main_hidden", state.main.visible, false)
    eq("panel.edit.closed_combat_leave.side_hidden", state.side.visible, false)

    inCombat = true
    editAddon:OpenConfigMenu()
    state = editTest.panelEditAffordanceState()
    eq("panel.edit.open_in_combat.requested", state.requested, true)
    eq("panel.edit.open_in_combat.main_hidden", state.main.visible, false)
    eq("panel.edit.open_in_combat.side_hidden", state.side.visible, false)
    inCombat = false
    fireEvent("panel.edit.open_combat_leave", editEnv, "PLAYER_REGEN_ENABLED")
    state = editTest.panelEditAffordanceState()
    eq("panel.edit.open_combat_leave.main_visible", state.main.visible, true)
    eq("panel.edit.open_combat_leave.side_visible", state.side.visible, true)
    editEnv.StatsProConfigFrame:Hide()
    assertDeepEqual("panel.edit.lifecycle_preserves_db", editEnv.StatsProDB, initialRoot)
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
    local slashEnv, _, slashTest = loadStatsPro("enUS", withProfileIdentity())
    fireEvent("slash.pew", slashEnv, "PLAYER_ENTERING_WORLD")
    local slashSettings = slashTest.profileState().settings
    slash("slash.default_opens_config", slashEnv, "")
    exists("slash.default_opens_config.frame", slashEnv.StatsProConfigFrame)
    clearPrints(slashEnv)
    slash("slash.hide", slashEnv, "hide")
    eq("slash.hide.visible", slashSettings.isVisible, false)
    eq("slash.hide.checkbox_synced", slashEnv.StatsProVisibleCheck:GetChecked(), false)
    eq("slash.hide.print", lastPrint(slashEnv), STATSPRO_PRINT_PREFIX .. "Stats panel hidden")
    clearPrints(slashEnv)
    slash("slash.show", slashEnv, "show")
    eq("slash.show.visible", slashSettings.isVisible, true)
    eq("slash.show.print", lastPrint(slashEnv), STATSPRO_PRINT_PREFIX .. "Stats panel shown")
    clearPrints(slashEnv)
    slash("slash.toggle", slashEnv, "toggle")
    eq("slash.toggle.visible", slashSettings.isVisible, false)
    eq("slash.toggle.print", lastPrint(slashEnv), STATSPRO_PRINT_PREFIX .. "Stats panel hidden")
    clearPrints(slashEnv)
    slash("slash.help", slashEnv, "help")
    eq("slash.help.print", lastPrint(slashEnv), STATSPRO_PRINT_PREFIX .. "Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help")
    slashSettings.fontBeforeAutoSwitch = "Fonts\\ARIALN.TTF"
    slashSettings.useLocalizedLabels = false
    slashSettings.font = "Fonts\\ARIALN.TTF"
    slashSettings.fontSize = 22
    slashSettings.textAlpha = 50
    slashSettings.panelBackgroundAlpha = 55
    slashSettings.textOutlineStyle = "thick"
    slashSettings.appearancePresetID = "custom"
    slashSettings.showRating = false
    slashSettings.showPercentage = false
    slashSettings.matchValueColorToStat = false
    slashSettings.labelStyle = "short"
    slashSettings.targetSnapshot = "raid"
    slashSettings.colors.crit = { r = 0.4, g = 0.5, b = 0.6 }
    clearPrints(slashEnv)
    slash("slash.reset_restores_defaults", slashEnv, "reset")
    eq("slash.reset_confirmation_open", slashEnv.__lastStaticPopup.key,
        "STATSPRO_RESET_ACTIVE_PROFILE")
    slashEnv.__acceptStaticPopup()
    slashSettings = slashTest.profileState().settings
    eq("slash.reset_restores_defaults.visible", slashSettings.isVisible, true)
    eq("slash.reset_restores_defaults.font", slashSettings.font, slashTest.copyDefaults().font)
    eq("slash.reset_restores_defaults.font_size", slashSettings.fontSize, 14)
    eq("slash.reset_restores_defaults.text_alpha", slashSettings.textAlpha, 100)
    eq("slash.reset_restores_defaults.panel_background_alpha", slashSettings.panelBackgroundAlpha, 15)
    eq("slash.reset_restores_defaults.text_outline_style", slashSettings.textOutlineStyle, "outline")
    eq("slash.reset_restores_defaults.appearance_preset", slashSettings.appearancePresetID, "default")
    eq("slash.reset_restores_defaults.show_rating", slashSettings.showRating, true)
    eq("slash.reset_restores_defaults.show_percentage", slashSettings.showPercentage, true)
    eq("slash.reset_restores_defaults.match_value_color", slashSettings.matchValueColorToStat, true)
    eq("slash.reset_restores_defaults.label_style", slashSettings.labelStyle, "full")
    eq("slash.reset_restores_defaults.target_snapshot", slashSettings.targetSnapshot, "mythicPlus")
    eq("slash.reset_restores_defaults.transient_font", slashSettings.fontBeforeAutoSwitch, nil)
    eq("slash.reset_restores_defaults.legacy_locale", slashSettings.useLocalizedLabels, nil)
    eq("slash.reset_restores_defaults.print", lastPrint(slashEnv), STATSPRO_PRINT_PREFIX .. "Settings reset to defaults")
    assertColor("slash.reset_restores_defaults.crit", slashSettings.colors.crit, 1, 0, 0)
end

do
    local slashEnv, _, slashTest = loadStatsPro("enUS", withProfileIdentity({
        statsProDB = {
            forceLocale = "ruRU",
        },
    }))
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
    eq("slash.localized_ruRU.help.print", lastPrint(slashEnv), STATSPRO_PRINT_PREFIX .. "Команды: /ss или /statspro (настройки), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help")
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
    accountSettings(slashEnv).forceLocale = "ruRU"
    local localizedSettings = slashTest.profileState().settings
    localizedSettings.fontBeforeAutoSwitch = "Fonts\\ARIALN.TTF"
    localizedSettings.useLocalizedLabels = false
    clearPrints(slashEnv)
    slash("slash.localized_ruRU.reset", slashEnv, "reset")
    slashEnv.__acceptStaticPopup()
    localizedSettings = slashTest.profileState().settings
    eq("slash.localized_ruRU.reset.keeps_account_locale", accountSettings(slashEnv).forceLocale, "ruRU")
    eq("slash.localized_ruRU.reset.keeps_glyph_font",
        localizedSettings.font, "Fonts\\ARIALN.TTF")
    eq("slash.localized_ruRU.reset.panel_keeps_glyph_font",
        slashTest.panelFontState().mainAppliedFont, "Fonts\\ARIALN.TTF")
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
    local secretMaxSpellSchools = 99
    local maxSpellSchoolCases = {
        { name = "valid", value = 5, expected = 5 },
        { name = "malformed", value = "bad", expected = 7 },
        { name = "secret", value = secretMaxSpellSchools, expected = 7, secret = true },
    }
    for _, case in ipairs(maxSpellSchoolCases) do
        local _, critAddon = loadStatsPro("enUS", {
            maxSpellSchools = case.value,
            issecretvalue = function(value)
                return case.secret == true and value == secretMaxSpellSchools
            end,
        })
        eq("selector.max_spell_school." .. case.name, critAddon.GetMaxSpellSchool(), case.expected)
    end
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
    local schoolCrit = { [2] = 25, [3] = 20, [4] = 19, [5] = 18, [6] = 22, [7] = 15 }
    local critEnv, critAddon = loadStatsPro("enUS", {
        getCritChance = function() return 16 end,
        getRangedCritChance = function() return 17 end,
        getSpellCritChance = function(school) return schoolCrit[school] end,
    })
    local ok, value = pcall(critAddon.GetBestCritChance)
    check("selector.best_crit_uses_minimum_spell_school.no_error", ok, value)
    eq("selector.best_crit_uses_minimum_spell_school.value", value, 17)
    slash("selector.best_crit_uses_minimum_spell_school.debug_live", critEnv, "debug live")
    eq("selector.best_crit_uses_minimum_spell_school.debug_schools",
        printContains(critEnv, "debug live crit schools: 2=25.00 3=20.00 4=19.00 5=18.00 6=22.00 7=15.00"), true)
end

do
    local secretSpellCrit = 30
    local schoolCalls = {}
    local schoolCrit = { [2] = 24, [3] = 22, [4] = secretSpellCrit, [5] = 21, [6] = 20, [7] = 19 }
    local _, critAddon = loadStatsPro("enUS", {
        getCritChance = function() return 16 end,
        getRangedCritChance = function() return 18 end,
        getSpellCritChance = function(school)
            schoolCalls[school] = (schoolCalls[school] or 0) + 1
            return schoolCrit[school]
        end,
        issecretvalue = function(value) return value == secretSpellCrit end,
    })
    local ok, value = pcall(critAddon.GetBestCritChance)
    check("selector.best_crit_secret_school_rejects_partial_spell.no_error", ok, value)
    eq("selector.best_crit_secret_school_rejects_partial_spell.value", value, 18)
    for school = 2, 7 do
        eq("selector.best_crit_secret_school_rejects_partial_spell.school_" .. school, schoolCalls[school], 1)
    end
end

do
    local invalidSchoolCases = {
        { name = "error", read = function() error("school unavailable") end },
        { name = "string", read = function() return "bad" end },
        { name = "nan", read = function() return 0 / 0 end },
        { name = "infinity", read = function() return math.huge end },
    }
    for _, case in ipairs(invalidSchoolCases) do
        local _, critAddon = loadStatsPro("enUS", {
            getCritChance = function() return 16 end,
            getRangedCritChance = function() return 17 end,
            getSpellCritChance = function(school)
                if school == 4 then return case.read() end
                return 25
            end,
        })
        local ok, value = pcall(critAddon.GetBestCritChance)
        check("selector.best_crit_invalid_school_rejects_partial_spell." .. case.name .. ".no_error", ok, value)
        eq("selector.best_crit_invalid_school_rejects_partial_spell." .. case.name .. ".value", value, 17)
    end
end

do
    local otherSchoolCalls = 0
    local _, critAddon = loadStatsPro("enUS", {
        getCritChance = function() return nil end,
        getRangedCritChance = function() return nil end,
        getSpellCritChance = function(school)
            if school == 2 then return nil end
            otherSchoolCalls = otherSchoolCalls + 1
            return 23.4
        end,
    })
    local ok, value = pcall(critAddon.GetBestCritChance)
    check("selector.best_crit_incomplete_spell_aggregate_is_rejected.no_error", ok, value)
    eq("selector.best_crit_incomplete_spell_aggregate_is_rejected.value", value, nil)
    eq("selector.best_crit_incomplete_spell_aggregate_is_rejected.other_school_calls", otherSchoolCalls, 5)
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
    local spellCalls = 0
    local _, critAddon = loadStatsPro("enUS", {
        getCritChance = function() return 11 end,
        getRangedCritChance = function() return 18 end,
        getSpellCritChance = function(school)
            spellCalls = spellCalls + 1
            if school == 2 then return secretSpellCrit end
            return 23.8
        end,
        issecretvalue = function(value) return value == secretSpellCrit end,
    })
    local ok, value = pcall(critAddon.GetBestCritChance)
    check("selector.best_crit_secret_spell2_uses_clean_fallback.no_error", ok, value)
    eq("selector.best_crit_secret_spell2_uses_clean_fallback.value", value, 18)
    eq("selector.best_crit_secret_spell2_uses_clean_fallback.all_schools_seen", spellCalls, 6)
end

do
    local secretSpellCrit = 24.2
    local spellCalls = 0
    local _, critAddon = loadStatsPro("enUS", {
        getCritChance = function() return nil end,
        getRangedCritChance = function() return nil end,
        getSpellCritChance = function()
            spellCalls = spellCalls + 1
            return secretSpellCrit
        end,
        issecretvalue = function(value) return value == secretSpellCrit end,
    })
    local ok, value = pcall(critAddon.GetBestCritChance)
    check("selector.best_crit_secret_spell2_returns_secret.no_error", ok, value)
    eq("selector.best_crit_secret_spell2_returns_secret.value", value, secretSpellCrit)
    eq("selector.best_crit_secret_spell2_returns_secret.all_schools_seen", spellCalls, 6)
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
    local schoolCrit = { [2] = 25, [3] = 20, [4] = 19, [5] = 18, [6] = 22, [7] = 15 }
    local critEnv, _, critTest = loadStatsPro("enUS", {
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
        getCritChance = function() return 16 end,
        getRangedCritChance = function() return 17 end,
        getSpellCritChance = function(school) return schoolCrit[school] end,
    })
    fireEvent("render.crit_uses_minimum_spell_school.fire", critEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.crit_uses_minimum_spell_school.no_error", ok, blocks)
    eq("render.crit_uses_minimum_spell_school.paper_doll_value", blockDumpContains(blocks, "17.0%"), true)
    eq("render.crit_uses_minimum_spell_school.no_school2_overstatement", blockDumpContains(blocks, "25.0%"), false)
end

do
    local critEnv, _, critTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = true,
            showRating = false,
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
            showRating = false,
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
            showRating = false,
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
            showRating = false,
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
    local spellCalls = 0
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
            spellCalls = spellCalls + 1
            if school == 2 then return secretSpellCrit end
            return 23.8
        end,
        issecretvalue = function(value) return value == secretSpellCrit end,
    })
    fireEvent("render.crit_spell_secret_uses_best_clean_fallback.fire", critEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.crit_spell_secret_uses_best_clean_fallback.no_error", ok, blocks)
    eq("render.crit_spell_secret_uses_best_clean_fallback.all_schools_seen", spellCalls, 12)
    eq("render.crit_spell_secret_uses_best_clean_fallback.row", blockDumpContains(blocks, "Crit:"), true)
    eq("render.crit_spell_secret_uses_best_clean_fallback.clean_fallback_value", blockDumpContains(blocks, "18.6%"), true)
end

do
    local secretSpellCrit = 24.2
    local spellCalls = 0
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
        getSpellCritChance = function()
            spellCalls = spellCalls + 1
            return secretSpellCrit
        end,
        issecretvalue = function(value) return value == secretSpellCrit end,
    })
    fireEvent("render.crit_spell_secret_only_keeps_row.fire", critEnv, "PLAYER_ENTERING_WORLD")
    local ok, blocks = pcall(critTest.buildRenderBlocks)
    check("render.crit_spell_secret_only_keeps_row.no_error", ok, blocks)
    eq("render.crit_spell_secret_only_keeps_row.all_schools_seen", spellCalls, 12)
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
    local targetOnlyMeta = blocks[2].targetRows[1]
    check("render.target_hover_rating_error.target_only_meta", type(targetOnlyMeta) == "table", targetOnlyMeta)
    eq("render.target_hover_rating_error.target_only_state", targetOnlyMeta.comparisonState, "targetOnly")
    eq("render.target_hover_rating_error.no_false_current_zero", targetOnlyMeta.current, nil)
    eq("render.target_hover_rating_error.no_false_delta_zero", targetOnlyMeta.delta, nil)
    eq("render.target_hover_rating_error.no_second_percent_only_rating_read", ratingCalls, 1)
end

do
    local liveRating = 812
    local targetHoverFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(targetHoverFixture, "mythicPlus", "MAGE", "frost",
        { crit = 1000, haste = 200, mastery = 300, versatility = 400 })
    local critEnv, _, critTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        inCombatLockdown = function() return true end,
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
        getCombatRating = function() return liveRating end,
        issecretvalue = function(value) return value == -1 end,
    })
    fireEvent("render.target_hover_clean_secret_clean.fire", critEnv, "PLAYER_ENTERING_WORLD")
    local exactBlocks = critTest.buildRenderBlocks()
    local exactMeta = exactBlocks[2].targetRows[1]
    eq("render.target_hover_clean_secret_clean.exact_state", exactMeta.comparisonState, "exact")
    eq("render.target_hover_clean_secret_clean.exact_current", exactMeta.current, 812)

    liveRating = -1
    local restrictedBlocks = critTest.buildRenderBlocks()
    local lastKnownMeta = restrictedBlocks[2].targetRows[1]
    eq("render.target_hover_clean_secret_clean.last_known_state", lastKnownMeta.comparisonState, "lastKnown")
    eq("render.target_hover_clean_secret_clean.last_known_current", lastKnownMeta.current, 812)
    eq("render.target_hover_clean_secret_clean.secret_not_stored", lastKnownMeta.current == -1, false)
    local cacheState = critTest.archonComparisonCache()
    eq("render.target_hover_clean_secret_clean.cache_current_clean", cacheState.entries.crit.current, 812)
    critTest.renderMainPanelForSmoke("Crit:", "12.5%", "", 1, nil, nil, { lastKnownMeta })
    critTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    eq("render.target_hover_clean_secret_clean.combat_overlay_shows", critEnv.GameTooltip:IsShown(), true)

    liveRating = 830
    local recoveredBlocks = critTest.buildRenderBlocks()
    local recoveredMeta = recoveredBlocks[2].targetRows[1]
    eq("render.target_hover_clean_secret_clean.recovered_state", recoveredMeta.comparisonState, "exact")
    eq("render.target_hover_clean_secret_clean.recovered_current", recoveredMeta.current, 830)
end

do
    local function forbiddenSecretOperation(operation)
        return function()
            error("hostile secret rating reached " .. operation, 0)
        end
    end

    local secretRating = setmetatable({}, {
        __add = forbiddenSecretOperation("addition"),
        __concat = forbiddenSecretOperation("concatenation"),
        __eq = forbiddenSecretOperation("comparison"),
        __le = forbiddenSecretOperation("comparison"),
        __lt = forbiddenSecretOperation("comparison"),
        __sub = forbiddenSecretOperation("subtraction"),
        __tostring = forbiddenSecretOperation("formatting"),
        __unm = forbiddenSecretOperation("negation"),
    })
    local restricted = true
    local cleanRatings = {}
    local conversionArgs = {}
    local targetHoverFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(targetHoverFixture, "mythicPlus", "MAGE", "frost",
        { crit = 1000, haste = 600, mastery = 900, versatility = 500 })

    local hoverEnv, hoverAddon, hoverTest = loadStatsPro("enUS", {
        unitClassToken = "MAGE",
        specIndex = 1,
        specID = 64,
        inCombatLockdown = function() return true end,
        statsProDB = {
            displayMode = "flat",
            labelStyle = "full",
            isLocked = false,
            showMainStat = false,
            showStamina = false,
            showOffensive = true,
            showCrit = true,
            showHaste = true,
            showMastery = true,
            showVersatility = true,
            showTertiary = false,
            showDefensive = false,
            showItemLevel = false,
            showDurability = false,
            showRepairCost = false,
            showRating = false,
            showPercentage = true,
            hideZeroOffensive = false,
        },
        statsProArchonTargets = targetHoverFixture,
        getCritChance = function() return 20 end,
        getHaste = function() return 15 end,
        getMasteryEffect = function() return 25 end,
        getCombatRatingBonus = function() return 10 end,
        getVersatilityBonus = function() return 2 end,
        getCombatRating = function(ratingCR)
            if restricted then return secretRating end
            return cleanRatings[ratingCR]
        end,
        getCombatRatingBonusForCombatRatingValue = function(_, value)
            if rawequal(value, secretRating) then
                error("hostile secret rating reached conversion", 0)
            end
            conversionArgs[#conversionArgs + 1] = value
            return value / 100
        end,
        issecretvalue = function(value) return rawequal(value, secretRating) end,
    })
    cleanRatings[hoverEnv.CR_CRIT_MELEE] = 800
    cleanRatings[hoverEnv.CR_HASTE_MELEE] = 500
    cleanRatings[hoverEnv.CR_MASTERY] = 700
    cleanRatings[hoverEnv.CR_VERSATILITY_DAMAGE_DONE] = 400

    local function assertPanelTargets(name, panelName, expectedState)
        local state = hoverTest.panelTooltipState(panelName)
        local targetCount = 0
        for index, meta in ipairs(state.lastTargetRows or {}) do
            if type(meta) == "table" then
                targetCount = targetCount + 1
                eq(name .. ".state." .. index, meta.comparisonState, expectedState)
                eq(name .. ".shown." .. index, state.shown[index], true)
                eq(name .. ".on_enter." .. index, state.hasOnEnter[index], true)
            end
        end
        eq(name .. ".target_count", targetCount, 4)
        return state
    end

    fireEvent("render.target_hover_lifecycle.cold.fire", hoverEnv, "PLAYER_ENTERING_WORLD")
    local savedAfterLoad = deepCopy(hoverEnv.StatsProDB)
    local coldState = assertPanelTargets("render.target_hover_lifecycle.cold", "main", "targetOnly")
    eq("render.target_hover_lifecycle.cold.cache_empty",
        next(hoverTest.archonComparisonCache().entries), nil)
    for index, meta in ipairs(coldState.lastTargetRows) do
        if type(meta) == "table" then
            hoverTest.firePanelTooltipOverlayForSmoke("main", index, "OnEnter")
            eq("render.target_hover_lifecycle.cold.tooltip_lines." .. index,
                #hoverEnv.GameTooltip.lines, 4)
            eq("render.target_hover_lifecycle.cold.tooltip_target." .. index,
                hoverEnv.GameTooltip.lines[2].left, "Target:")
            eq("render.target_hover_lifecycle.cold.tooltip_snapshot." .. index,
                hoverEnv.GameTooltip.lines[3].left, "Snapshot:")
            eq("render.target_hover_lifecycle.cold.tooltip_source." .. index,
                hoverEnv.GameTooltip.lines[4].left, "Source:")
        end
    end

    local ticker = findFrame("render.target_hover_lifecycle.ticker", hoverEnv, function(frame)
        return frame.scripts and type(frame.scripts.OnUpdate) == "function"
    end)
    for tick = 1, 3 do
        callScript("render.target_hover_lifecycle.cold.tick." .. tick, ticker, "OnUpdate", 999)
        assertPanelTargets("render.target_hover_lifecycle.cold.after_tick." .. tick,
            "main", "targetOnly")
        eq("render.target_hover_lifecycle.cold.open_tooltip_survives_tick." .. tick,
            hoverEnv.GameTooltip:IsShown(), true)
    end

    local beforeCombatDrag = hoverTest.panelTooltipState("main")
    hoverTest.firePanelTooltipOverlayForSmoke("main", 1, "OnDragStart")
    callScript("render.target_hover_lifecycle.combat.panel_drag", hoverEnv.StatsProFrame, "OnDragStart")
    hoverTest.firePanelTooltipOverlayForSmoke("main", 1, "OnMouseUp", "RightButton")
    local afterCombatDrag = hoverTest.panelTooltipState("main")
    eq("render.target_hover_lifecycle.combat.overlay_drag_blocked",
        afterCombatDrag.startMovingCalls, beforeCombatDrag.startMovingCalls)
    eq("render.target_hover_lifecycle.combat.panel_drag_blocked",
        hoverEnv.StatsProFrame.startMovingCalls or 0, 0)
    eq("render.target_hover_lifecycle.combat.was_dragging_false", afterCombatDrag.wasDragging, false)
    eq("render.target_hover_lifecycle.combat.settings_blocked", hoverEnv.StatsProConfigFrame, nil)

    restricted = false
    check("render.target_hover_lifecycle.recovery.update", hoverAddon:RunUpdateStatsSafe())
    local exactState = assertPanelTargets("render.target_hover_lifecycle.recovery", "main", "exact")
    local expectedCurrentByStat = {
        crit = 800,
        haste = 500,
        mastery = 700,
        versatility = 400,
    }
    for _, meta in ipairs(exactState.lastTargetRows) do
        if type(meta) == "table" then
            eq("render.target_hover_lifecycle.recovery.current." .. meta.statKey,
                meta.current, expectedCurrentByStat[meta.statKey])
        end
    end

    restricted = true
    for tick = 1, 3 do
        callScript("render.target_hover_lifecycle.last_known.tick." .. tick, ticker, "OnUpdate", 999)
        assertPanelTargets("render.target_hover_lifecycle.last_known.after_tick." .. tick,
            "main", "lastKnown")
    end
    local lastKnownState = hoverTest.panelTooltipState("main")
    for index, meta in ipairs(lastKnownState.lastTargetRows) do
        if type(meta) == "table" then
            hoverTest.firePanelTooltipOverlayForSmoke("main", index, "OnEnter")
            eq("render.target_hover_lifecycle.last_known.tooltip_lines." .. index,
                #hoverEnv.GameTooltip.lines, 7)
            eq("render.target_hover_lifecycle.last_known.notice." .. index,
                hoverEnv.GameTooltip.lines[2].left, "Last known comparison")
        end
    end
    local cachedAfterRestriction = hoverTest.archonComparisonCache()
    for statKey, expectedCurrent in pairs(expectedCurrentByStat) do
        eq("render.target_hover_lifecycle.last_known.cache." .. statKey,
            cachedAfterRestriction.entries[statKey].current, expectedCurrent)
    end

    restricted = false
    for ratingCR, value in pairs(cleanRatings) do cleanRatings[ratingCR] = value + 11 end
    check("render.target_hover_lifecycle.clean_return.update", hoverAddon:RunUpdateStatsSafe())
    local returnedState = assertPanelTargets(
        "render.target_hover_lifecycle.clean_return", "main", "exact")
    for _, meta in ipairs(returnedState.lastTargetRows) do
        if type(meta) == "table" then
            eq("render.target_hover_lifecycle.clean_return.current." .. meta.statKey,
                meta.current, expectedCurrentByStat[meta.statKey] + 11)
        end
    end
    assertDeepEqual("render.target_hover_lifecycle.transient_cache_not_persisted",
        hoverEnv.StatsProDB, savedAfterLoad)
    check("render.target_hover_lifecycle.conversion_exercised",
        #conversionArgs >= 8, "expected target conversion calls from both tooltip states")
    for index, value in ipairs(conversionArgs) do
        check("render.target_hover_lifecycle.clean_conversion_arg." .. index,
            type(value) == "number", "non-numeric conversion argument")
    end

    local settings = activeSettings(hoverEnv)
    settings.displayMode = "sectioned"
    settings.labelStyle = "full"
    hoverTest.cacheSettings()
    check("render.target_hover_routing.sectioned.update", hoverAddon:RunUpdateStatsSafe())
    local sectionedState = assertPanelTargets(
        "render.target_hover_routing.sectioned", "main", "exact")
    eq("render.target_hover_routing.sectioned.header_meta",
        sectionedState.lastTargetRows[1], false)
    eq("render.target_hover_routing.sectioned.header_overlay_hidden",
        sectionedState.shown[1], false)
    eq("render.target_hover_routing.sectioned.header_on_enter_cleared",
        sectionedState.hasOnEnter[1], false)

    settings.labelStyle = "hidden"
    hoverTest.cacheSettings()
    check("render.target_hover_routing.hidden.update", hoverAddon:RunUpdateStatsSafe())
    assertPanelTargets("render.target_hover_routing.hidden", "main", "exact")
    eq("render.target_hover_routing.hidden.labels", hoverTest.panelVisualState().mainLabelText, "")

    settings.displayMode = "split"
    settings.splitOffensive = true
    settings.labelStyle = "full"
    hoverTest.cacheSettings()
    check("render.target_hover_routing.split.update", hoverAddon:RunUpdateStatsSafe())
    local splitState = assertPanelTargets("render.target_hover_routing.split", "side", "exact")
    eq("render.target_hover_routing.split.main_targets",
        hoverTest.panelTooltipState("main").lastTargetRows, nil)
    for index, meta in ipairs(splitState.lastTargetRows) do
        if type(meta) == "table" then
            hoverTest.firePanelTooltipOverlayForSmoke("side", index, "OnEnter")
            eq("render.target_hover_routing.split.tooltip_shown." .. index,
                hoverEnv.GameTooltip:IsShown(), true)
        end
    end

    settings.displayMode = "flat"
    settings.splitOffensive = false
    settings.showRating = true
    settings.showPercentage = false
    hoverTest.cacheSettings()
    check("render.target_hover_routing.rating_only.update", hoverAddon:RunUpdateStatsSafe())
    assertPanelTargets("render.target_hover_routing.rating_only", "main", "exact")
    local ratingOnlyVisual = hoverTest.panelVisualState()
    eq("render.target_hover_routing.rating_only.value_column", ratingOnlyVisual.mainValueText, "")
    check("render.target_hover_routing.rating_only.rating_column",
        ratingOnlyVisual.mainRatingText:find("811", 1, true) ~= nil,
        ratingOnlyVisual.mainRatingText)
end

do
    local leechEnv, _, leechTest = loadStatsPro("enUS", {
        statsProDB = {
            showOffensive = false,
            showTertiary = true,
            showRating = false,
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
    activeSettings(armorEnv).showDefensive = true
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
            showRating = false,
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
            showRating = false,
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
            matchValueColorToStat = false,
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
    local targetOnlyMeta = blocks[2].targetRows[1]
    check("render.versatility_secret_rating_displays_without_meta.target_meta", type(targetOnlyMeta) == "table", targetOnlyMeta)
    eq("render.versatility_secret_rating_displays_without_meta.target_only_state", targetOnlyMeta.comparisonState, "targetOnly")
    eq("render.versatility_secret_rating_displays_without_meta.no_current", targetOnlyMeta.current, nil)
    eq("render.versatility_secret_rating_displays_without_meta.no_delta", targetOnlyMeta.delta, nil)
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
    local ilvlEnv, _, ilvlTest = loadStatsPro("enUS", {
        statsProDB = {
            displayMode = "sectioned",
            panelBackgroundAlpha = 0,
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
    local sectionedBlocks = ilvlTest.buildRenderBlocks()
    local sectionedBucket = ilvlTest.routeRenderBlocks(sectionedBlocks, "sectioned", nil, "full")
    eq("routing.section_header.contrast_color", sectionedBucket.labels[1], "|cffb3bdb8— Gear —|r")
    local transparentState = ilvlTest.panelVisualState()
    eq("routing.section_header.transparent.runtime_text",
        transparentState.mainLabelText:find("|cffb3bdb8— Gear —|r", 1, true) ~= nil, true)
    eq("routing.section_header.transparent.outline", transparentState.mainLabelFlags, "OUTLINE")
    near("routing.section_header.transparent.text_alpha", transparentState.mainLabelAlpha, 1)
    near("routing.section_header.transparent.background_alpha",
        transparentState.mainBackgroundTextureAlpha, 0)

    local maxBackgroundEnv, _, maxBackgroundTest = loadStatsPro("enUS", {
        statsProDB = {
            displayMode = "sectioned",
            textOutlineStyle = "outline",
            panelBackgroundAlpha = 80,
            showOffensive = false,
            showItemLevel = true,
            showDurability = false,
            showRepairCost = false,
        },
        getAverageItemLevel = function() return 273, 271 end,
    })
    fireEvent("routing.section_header.max_background.fire", maxBackgroundEnv, "PLAYER_ENTERING_WORLD")
    local maxBackgroundState = maxBackgroundTest.panelVisualState()
    eq("routing.section_header.max_background.runtime_text",
        maxBackgroundState.mainLabelText:find("|cffb3bdb8— Gear —|r", 1, true) ~= nil, true)
    eq("routing.section_header.max_background.outline", maxBackgroundState.mainLabelFlags, "OUTLINE")
    near("routing.section_header.max_background.background_alpha",
        maxBackgroundState.mainBackgroundTextureAlpha, 0.8)

    local noOutlineEnv, _, noOutlineTest = loadStatsPro("enUS", {
        statsProDB = {
            displayMode = "sectioned",
            textOutlineStyle = "none",
            panelBackgroundAlpha = 30,
            showOffensive = false,
            showItemLevel = true,
            showDurability = false,
            showRepairCost = false,
        },
        getAverageItemLevel = function() return 273, 271 end,
    })
    fireEvent("routing.section_header.no_outline.fire", noOutlineEnv, "PLAYER_ENTERING_WORLD")
    local noOutlineState = noOutlineTest.panelVisualState()
    eq("routing.section_header.no_outline.runtime_text",
        noOutlineState.mainLabelText:find("|cffb3bdb8— Gear —|r", 1, true) ~= nil, true)
    eq("routing.section_header.no_outline.flags", noOutlineState.mainLabelFlags, nil)
    near("routing.section_header.no_outline.background_alpha",
        noOutlineState.mainBackgroundTextureAlpha, 0.3)
end

do
    local overall, equipped = 273, 271
    local reads = 0
    local ilvlEnv, _, ilvlTest = loadStatsPro("enUS", {
        statsProDB = {
            showRating = true,
            showPercentage = true,
            showOffensive = false,
            showTertiary = false,
            showDefensive = false,
            showItemLevel = true,
            showDurability = false,
            showRepairCost = false,
        },
        getAverageItemLevel = function()
            reads = reads + 1
            return overall, equipped
        end,
    })
    fireEvent("lifecycle.item_level_authoritative_update.initial", ilvlEnv, "PLAYER_ENTERING_WORLD")
    local state = ilvlTest.itemLevelState()
    eq("lifecycle.item_level_authoritative_update.initial_overall", state.overall, 273)
    eq("lifecycle.item_level_authoritative_update.initial_equipped", state.equipped, 271)
    eq("lifecycle.item_level_authoritative_update.initial_clean", state.dirty, false)
    eq("lifecycle.item_level_authoritative_update.initial_read", reads, 1)

    local ticker = findFrame("lifecycle.item_level_authoritative_update.ticker", ilvlEnv, function(frame)
        return frame.scripts and type(frame.scripts.OnUpdate) == "function"
    end)
    fireEvent("lifecycle.item_level_authoritative_update.stale_bag_event", ilvlEnv, "BAG_UPDATE_DELAYED")
    callScript("lifecycle.item_level_authoritative_update.stale_bag_tick", ticker, "OnUpdate", 999)
    state = ilvlTest.itemLevelState()
    eq("lifecycle.item_level_authoritative_update.stale_read_clears_dirty", state.dirty, false)
    eq("lifecycle.item_level_authoritative_update.stale_read_count", reads, 2)

    overall, equipped = 281, 279
    fireEvent("lifecycle.item_level_authoritative_update.fire", ilvlEnv, "PLAYER_AVG_ITEM_LEVEL_UPDATE")
    fireEvent("lifecycle.item_level_authoritative_update.coalesced_fire", ilvlEnv, "PLAYER_AVG_ITEM_LEVEL_UPDATE")
    eq("lifecycle.item_level_authoritative_update.marks_dirty", ilvlTest.itemLevelState().dirty, true)
    eq("lifecycle.item_level_authoritative_update.no_immediate_read", reads, 2)
    callScript("lifecycle.item_level_authoritative_update.refresh_tick", ticker, "OnUpdate", 999)
    state = ilvlTest.itemLevelState()
    eq("lifecycle.item_level_authoritative_update.refreshed_overall", state.overall, 281)
    eq("lifecycle.item_level_authoritative_update.refreshed_equipped", state.equipped, 279)
    eq("lifecycle.item_level_authoritative_update.refreshed_clean", state.dirty, false)
    eq("lifecycle.item_level_authoritative_update.coalesced_read_count", reads, 3)
    local visualState = ilvlTest.panelVisualState()
    eq("lifecycle.item_level_authoritative_update.rendered_equipped",
        visualState.mainRatingText:find("279", 1, true) ~= nil, true)
    eq("lifecycle.item_level_authoritative_update.rendered_overall",
        visualState.mainValueText:find("281", 1, true) ~= nil, true)
end

do
    local itemLevelFloorCases = {
        {
            name = "fraction_49",
            overall = 273.49,
            equipped = 271.49,
            expectedOverall = 273,
            expectedEquipped = 271,
            expectedColor = nil,
        },
        {
            name = "fraction_50",
            overall = 273.50,
            equipped = 271.50,
            expectedOverall = 273,
            expectedEquipped = 271,
            expectedColor = nil,
        },
        {
            name = "warn_below_boundary",
            overall = 275.50,
            equipped = 271.49,
            expectedOverall = 275,
            expectedEquipped = 271,
            expectedColor = nil,
        },
        {
            name = "warn_at_boundary",
            overall = 276.00,
            equipped = 271.99,
            expectedOverall = 276,
            expectedEquipped = 271,
            expectedColor = "ffcc33",
        },
        {
            name = "danger_below_boundary",
            overall = 290.50,
            equipped = 271.49,
            expectedOverall = 290,
            expectedEquipped = 271,
            expectedColor = "ffcc33",
        },
        {
            name = "danger_at_boundary",
            overall = 291.00,
            equipped = 271.99,
            expectedOverall = 291,
            expectedEquipped = 271,
            expectedColor = "ff3333",
        },
    }

    for _, case in ipairs(itemLevelFloorCases) do
        local env, _, itemLevelTest = loadStatsPro("enUS", {
            statsProDB = {
                showRating = true,
                showPercentage = true,
                showOffensive = false,
                showTertiary = false,
                showDefensive = false,
                showItemLevel = true,
                showDurability = false,
                showRepairCost = false,
            },
            getAverageItemLevel = function() return case.overall, case.equipped end,
        })
        local prefix = "render.item_level_blizzard_floor." .. case.name
        fireEvent(prefix .. ".fire", env, "PLAYER_ENTERING_WORLD")
        local state = itemLevelTest.itemLevelState()
        eq(prefix .. ".raw_equipped", state.equipped, case.equipped)
        eq(prefix .. ".raw_overall", state.overall, case.overall)
        local itemLevel = findBlockBySplitKey(prefix .. ".block", itemLevelTest.buildRenderBlocks(), "splitItemLevel")
        local ratingText = itemLevel.ratings[1] or ""
        local valueText = itemLevel.values[1] or ""
        local renderedEquipped = tonumber(ratingText:match("^|cff%x%x%x%x%x%x(%d+)|r"))
        local renderedOverall = tonumber(valueText:match("^|cff%x%x%x%x%x%x(%d+)|r"))
        eq(prefix .. ".equipped", renderedEquipped, case.expectedEquipped)
        eq(prefix .. ".overall", renderedOverall, case.expectedOverall)
        eq(prefix .. ".warn_color", ratingText:find("|cffffcc33", 1, true) ~= nil,
            case.expectedColor == "ffcc33")
        eq(prefix .. ".danger_color", ratingText:find("|cffff3333", 1, true) ~= nil,
            case.expectedColor == "ff3333")
    end
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

do
    local launcherKey = "Stats and gear HUD: item level, durability, repair cost and Archon stat targets. Click below to open the full settings window."
    local launcherDescriptionCases = {
        { "enUS", "Stats and gear HUD: item level, durability, repair cost and Archon stat targets. Click below to open the full settings window." },
        { "ruRU", "HUD характеристик и экипировки: уровень предметов, прочность, стоимость ремонта и цели характеристик Archon. Нажмите ниже, чтобы открыть окно настроек." },
        { "deDE", "HUD für Werte und Ausrüstung: Gegenstandsstufe, Haltbarkeit, Reparaturkosten und Archon-Stat-Ziele. Klicke unten, um die vollständigen Einstellungen zu öffnen." },
        { "frFR", "HUD de caractéristiques et d'équipement : niveau d'objet, durabilité, coût de réparation et objectifs de caractéristiques Archon. Cliquez ci-dessous pour ouvrir la fenêtre de paramètres complète." },
        { "esES", "HUD de estadísticas y equipo: nivel de objeto, durabilidad, coste de reparación y objetivos de estadísticas de Archon. Haz clic abajo para abrir la ventana de ajustes." },
        { "esMX", "HUD de estadísticas y equipo: nivel de objeto, durabilidad, costo de reparación y objetivos de estadísticas de Archon. Da clic abajo para abrir la ventana de configuración." },
        { "itIT", "HUD di statistiche ed equipaggiamento: livello oggetto, durabilità, costo di riparazione e obiettivi statistiche Archon. Clicca sotto per aprire le impostazioni complete." },
        { "ptBR", "HUD de atributos e equipamento: nível de item, durabilidade, custo de reparo e metas de atributos do Archon. Clique abaixo para abrir a janela de configurações." },
        { "koKR", "능력치·장비 HUD: 아이템 레벨, 내구도, 수리 비용, Archon 능력치 목표. 아래를 눌러 전체 설정 창을 엽니다." },
        { "zhCN", "属性与装备 HUD：装等、耐久度、修理费用及 Archon 属性目标。点击下方打开完整设置窗口。" },
        { "zhTW", "屬性與裝備 HUD：裝等、耐久度、修理費用及 Archon 屬性目標。點擊下方開啟完整設定視窗。" },
    }
    local labelsByLocale = test.registrySnapshot().labelsByLocale

    for _, case in ipairs(launcherDescriptionCases) do
        local locale, expected = case[1], case[2]
        eq("launcher.copy_registry_" .. locale, labelsByLocale[locale][launcherKey], expected)

        local launcherEnv, _, launcherTest = loadStatsPro("enUS", {
            statsProDB = {
                forceLocale = locale,
                showOffensive = true,
                showTertiary = true,
                showDefensive = true,
                displayMode = "split",
            },
        })
        fireEvent("launcher.localized_" .. locale .. ".fire", launcherEnv, "PLAYER_ENTERING_WORLD")
        eq("launcher.localized_" .. locale .. ".text", launcherTest.launcherDescriptionText(), expected)
    end

    local enGBEnv, _, enGBTest = loadStatsPro("enGB", {
        statsProDB = { forceLocale = "auto" },
    })
    fireEvent("launcher.localized_enGB_fallback.fire", enGBEnv, "PLAYER_ENTERING_WORLD")
    eq("launcher.localized_enGB_fallback.text", enGBTest.launcherDescriptionText(), launcherDescriptionCases[1][2])
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
            dbVersion = test.currentDBVersion() - 1,
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
    eq("fonts.dangling_saved_path.repairs_db", activeSettings(coldEnv).font, "Fonts\\FRIZQT__.TTF")
    eq("fonts.dangling_saved_path.clears_restore_path", activeSettings(coldEnv).fontBeforeAutoSwitch, nil)
    local state = coldTest.panelFontState()
    eq("fonts.dangling_saved_path.main_panel_uses_fallback", state.mainAppliedFont, "Fonts\\FRIZQT__.TTF")
    eq("fonts.dangling_saved_path.side_panel_uses_fallback", state.sideAppliedFont, "Fonts\\FRIZQT__.TTF")

    local ruEnv, _, ruTest = loadStatsPro("enUS", {
        statsProDB = {
            dbVersion = test.currentDBVersion() - 1,
            font = dangling,
            forceLocale = "ruRU",
        },
        setFontResult = function(_, font)
            if font == dangling then error("dangling saved font must never reach SetFont") end
            return true
        end,
    })
    fireEvent("fonts.dangling_saved_path.ru_fallback.pew", ruEnv, "PLAYER_ENTERING_WORLD")
    eq("fonts.dangling_saved_path.ru_fallback.db", activeSettings(ruEnv).font, "Fonts\\ARIALN.TTF")
    eq("fonts.dangling_saved_path.ru_fallback.panel", ruTest.panelFontState().mainAppliedFont, "Fonts\\ARIALN.TTF")
end

do
    local secretPath = "Interface\\AddOns\\SecretMedia\\Secret.ttf"
    local secretSetFontCalls = 0
    local secretDB = {
        dbVersion = test.currentDBVersion() - 1,
        font = secretPath,
        fontBeforeAutoSwitch = secretPath,
    }
    local secretEnv, _, secretTest = loadStatsPro("enUS", {
        statsProDB = secretDB,
        issecretvalue = function(value) return value == secretPath end,
        setFontResult = function(_, font)
            if font == secretPath then secretSetFontCalls = secretSetFontCalls + 1 end
            return true
        end,
    })
    fireEvent("fonts.secret_saved_path.pew", secretEnv, "PLAYER_ENTERING_WORLD")
    eq("fonts.secret_saved_path.never_reaches_set_font", secretSetFontCalls, 0)
    eq("fonts.secret_saved_path.same_root", rawequal(secretEnv.StatsProDB, secretDB), true)
    eq("fonts.secret_saved_path.preserves_font", activeSettings(secretEnv).font, secretPath)
    eq("fonts.secret_saved_path.preserves_saved_font", activeSettings(secretEnv).fontBeforeAutoSwitch, secretPath)
    eq("fonts.secret_saved_path.corrupt_mode", secretTest.dbCompatibilityState().mode, "corrupt")

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
    eq("fonts.invalid_standard_text_font.repairs_db", activeSettings(defaultEnv).font, "Fonts\\FRIZQT__.TTF")
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
    eq("fonts.future_schema_locale_runtime_fallback.panel_uses_safe_default",
        futureTest.panelFontState().mainAppliedFont, "Fonts\\FRIZQT__.TTF")
end

do
    local brokenSaved = "Interface\\AddOns\\BrokenMedia\\Broken.ttf"
    local brokenCalls = 0
    local savedEnv = loadStatsPro("enUS", {
        statsProDB = {
            dbVersion = test.currentDBVersion() - 1,
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
    eq("fonts.cataloged_but_unloadable_saved_path.cleared", activeSettings(savedEnv).fontBeforeAutoSwitch, nil)
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
    accountSettings(lsmEnv).forceLocale = "auto"
    activeSettings(lsmEnv).font = "Fonts\\FRIZQT__.TTF"
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
    eq("fonts.lsm_picker_click_writes_db_font", activeSettings(lsmEnv).font, cjkFontPath)

    local autoEnv = loadStatsPro("enUS", {
        statsProDB = { forceLocale = "zhCN", font = "Fonts\\FRIZQT__.TTF" },
        lsmFonts = {
            { name = "Noto Sans CJK", path = cjkFontPath },
        },
    })
    fireEvent("fonts.lsm_locale_auto_switch.fire", autoEnv, "PLAYER_ENTERING_WORLD")
    eq("fonts.lsm_locale_auto_switch.font", activeSettings(autoEnv).font, cjkFontPath)
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
    eq("fonts.unsupported_flags_fall_back_to_base.db_font", activeSettings(fallbackEnv).font, outlineFallbackPath)
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
    activeSettings(rollbackEnv).fontBeforeAutoSwitch = "Fonts\\ARIALN.TTF"
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
    local baselineDBFont = activeSettings(rollbackEnv).font
    failureMode = "false"
    local applied = rollbackTest.applyCommittedTextStyle(falsePath, 14, true, false)
    eq("fonts.failed_apply_rolls_back.false_result", applied, false)
    eq("fonts.failed_apply_rolls_back.false_db_font", activeSettings(rollbackEnv).font, baselineDBFont)
    eq("fonts.failed_apply_rolls_back.false_saved_font", activeSettings(rollbackEnv).fontBeforeAutoSwitch, "Fonts\\ARIALN.TTF")
    assertPanelState("fonts.failed_apply_rolls_back.false_state", rollbackTest.panelFontState(), baseline)

    failureMode = "pass"
    eq("fonts.failed_apply_rolls_back.error_path_preprobe", rollbackTest.usableFontPath(errorPath), errorPath)
    failureMode = "error"
    applied = rollbackTest.applyCommittedTextStyle(errorPath, 14, true, false)
    eq("fonts.failed_apply_rolls_back.error_result", applied, false)
    eq("fonts.failed_apply_rolls_back.error_db_font", activeSettings(rollbackEnv).font, baselineDBFont)
    eq("fonts.failed_apply_rolls_back.error_saved_font", activeSettings(rollbackEnv).fontBeforeAutoSwitch, "Fonts\\ARIALN.TTF")
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
    local baselineDBFont = activeSettings(configEnv).font
    activeSettings(configEnv).fontBeforeAutoSwitch = "Fonts\\ARIALN.TTF"
    local baselineCaption = configEnv.StatsProFontDropdown.dropdownText
    local baselinePanel = configTest.panelFontState()
    mode = "picker-false"
    callScript("fonts.picker_failed_commit.hover", pickerButton, "OnEnter")
    callScript("fonts.picker_failed_commit.click", pickerButton, "OnClick")
    eq("fonts.picker_failed_commit.db_unchanged", activeSettings(configEnv).font, baselineDBFont)
    eq("fonts.picker_failed_commit.saved_font_unchanged", activeSettings(configEnv).fontBeforeAutoSwitch, "Fonts\\ARIALN.TTF")
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
    eq("fonts.settings_failure_rollback.outline_db", activeSettings(settingsEnv).textOutlineStyle, "outline")
    eq("fonts.settings_failure_rollback.outline_caption", settingsEnv.StatsProTextOutlineDropdown.dropdownText, "Outline")
    eq("fonts.settings_failure_rollback.font_caption", settingsEnv.StatsProFontDropdown.dropdownText, baselineCaption)
    changeSlider("fonts.settings_failure_rollback.font_size", settingsEnv.StatsProFontSlider, 18)
    eq("fonts.settings_failure_rollback.font_size_db", activeSettings(settingsEnv).fontSize, 14)
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
    eq("fonts.runtime_failure_fallback_caption.db_font", activeSettings(staleEnv).font, "Fonts\\FRIZQT__.TTF")
    eq("fonts.runtime_failure_fallback_caption.db_size", activeSettings(staleEnv).fontSize, 18)
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
        futureTest.currentRuntimeFontPath(), "Fonts\\FRIZQT__.TTF")
    eq("fonts.future_schema_picker_baseline.panel_preserved",
        futureTest.panelFontState().mainAppliedFont, "Fonts\\FRIZQT__.TTF")
    eq("fonts.future_schema_picker_baseline.caption_matches_runtime",
        futureEnv.StatsProFontDropdown.dropdownText, "Friz Quadrata TT")
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

    local warningTemplate =
        "|cffffaa44⚠|r The selected font may not render %s correctly. Pick a SharedMedia font with proper coverage."
    local oldWarningTemplate =
        "|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."
    local requirementLabelKeys = {
        "Western European text", "Russian text", "Korean text",
        "Simplified Chinese text", "Traditional Chinese text",
        "text for the selected language",
    }
    for locale in pairs(explicitLocales) do
        local labels = registry.labelsByLocale[locale]
        eq("registry.language_warning.old_key_removed." .. locale,
            labels[oldWarningTemplate], nil)
        check("registry.language_warning.template." .. locale,
            type(labels[warningTemplate]) == "string" and labels[warningTemplate] ~= "")
        for _, key in ipairs(requirementLabelKeys) do
            check("registry.language_warning.label." .. locale .. "." .. key,
                type(labels[key]) == "string" and labels[key] ~= "")
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
    eq("config.invalid_display_mode_recovers.db_unchanged", activeSettings(badDisplayEnv).displayMode, "sideways")
end

do
    local badLocaleEnv, badLocaleAddon, badLocaleTest = loadStatsPro("deDE", {
        statsProDB = { forceLocale = "xxYY" },
    })
    fireEvent("config.invalid_force_locale_recovers.fire", badLocaleEnv, "PLAYER_ENTERING_WORLD")
    eq("config.invalid_force_locale_recovers.label", badLocaleTest.getStyledLabelText("ItemLevel", "full"), "GS:")
    eq("config.invalid_force_locale_recovers.account_normalized", accountSettings(badLocaleEnv).forceLocale, "auto")
    eq("config.invalid_force_locale_recovers.shadow_unchanged", badLocaleEnv.StatsProDB.forceLocale, "xxYY")

    local ok, err = pcall(function() badLocaleAddon:OpenConfigMenu() end)
    check("config.invalid_force_locale_recovers.open", ok, err)
    eq("config.invalid_force_locale_recovers.caption", badLocaleEnv.StatsProLanguageDropdown.dropdownText, "Deutsch")
    local languageEntries = runDropdownInit("config.invalid_force_locale_recovers.dropdown", badLocaleEnv.StatsProLanguageDropdown)
    eq("config.invalid_force_locale_recovers.checked", checkedDropdownValue("config.invalid_force_locale_recovers", languageEntries), "auto")
    eq("config.invalid_force_locale_recovers.account_after_open", accountSettings(badLocaleEnv).forceLocale, "auto")
    eq("config.invalid_force_locale_recovers.shadow_after_open", badLocaleEnv.StatsProDB.forceLocale, "xxYY")
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

        local worstSlotLabel = exists(
            "config.checkbox_label_guard." .. locale .. ".worst_slot_width",
            guardEnv.StatsProWorstDurCheckText)
        eq("config.checkbox_label_guard." .. locale .. ".worst_slot_width.full_row",
            worstSlotLabel:GetWidth(), 400)
        check("config.checkbox_label_guard." .. locale .. ".worst_slot_width.fits_text",
            worstSlotLabel:GetStringWidth() <= worstSlotLabel:GetWidth(),
            "localized Worst Slot label exceeds its full-row width")
        eq("config.checkbox_label_guard." .. locale .. ".two_column_width.offensive",
            guardEnv.StatsProOffensiveCheckText:GetWidth(), 200)
        eq("config.checkbox_label_guard." .. locale .. ".two_column_width.hide_zero",
            guardEnv.StatsProHideZeroOffCheckText:GetWidth(), 200)
    end

    for _, locale in ipairs({
        "enUS", "deDE", "esES", "esMX", "frFR", "itIT",
        "koKR", "ptBR", "ruRU", "zhCN", "zhTW",
    }) do
        assertLocalizedCheckboxGuards(locale)
    end
end

do
    for _, locale in ipairs({
        "enUS", "deDE", "esES", "esMX", "frFR", "itIT",
        "koKR", "ptBR", "ruRU", "zhCN", "zhTW",
    }) do
        local localeEnv, localeAddon, localeTest = loadStatsPro("enUS", {
            statsProDB = { forceLocale = locale },
            uiParentWidth = 500,
            uiParentHeight = 260,
        })
        local prefix = "config.control_locale_matrix." .. locale
        fireEvent(prefix .. ".pew", localeEnv, "PLAYER_ENTERING_WORLD")
        local ok, err = pcall(function() localeAddon:OpenConfigMenu() end)
        check(prefix .. ".open", ok, err)

        local counts = {}
        for _, control in ipairs(localeTest.settingsControlState()) do
            counts[control.kind] = (counts[control.kind] or 0) + 1
            check(prefix .. ".hit_target." .. tostring(control.kind)
                    .. "." .. tostring(control.name or _),
                control.width >= 24 and control.height >= 24,
                "localized control is smaller than 24x24px")
        end
        eq(prefix .. ".checkbox_count", counts.checkbox, 37)
        eq(prefix .. ".swatch_count", counts.swatch, 18)
        eq(prefix .. ".slider_count", counts.slider, 5)
        eq(prefix .. ".dropdown_count", counts.dropdown, 6)
        eq(prefix .. ".button_count", counts.button, 23)
        eq(prefix .. ".footer_signature_text",
            localeEnv.StatsProConfigFrame.settingsShell.footerSignature:GetText(),
            localeTest.registrySnapshot().labelsByLocale[locale]["Made with"])
        check(prefix .. ".footer_signature_fit",
            localeEnv.StatsProConfigFrame.settingsShell.footerSignature:GetStringWidth()
                <= localeEnv.StatsProConfigFrame.settingsShell.footerSignature:GetWidth(),
            "localized footer signature overflows")
        check(prefix .. ".footer_contact_fit",
            localeEnv.StatsProContactLinkButton.statsProText:GetStringWidth()
                <= localeEnv.StatsProContactLinkButton.statsProText:GetWidth(),
            "localized Contact label overflows")
        local presetUI = localeAddon.appearancePresets.ui
        for _, presetID in ipairs({
            "default", "classic", "clean-dark", "midnight", "monochrome", "high-contrast",
        }) do
            local button = presetUI.buttons[presetID]
            check(prefix .. ".preset_card_fit." .. presetID,
                button.statsProText:GetStringWidth() <= button.statsProText:GetWidth(),
                "localized preset card label overflows")
        end
        check(prefix .. ".preset_cancel_fit",
            presetUI.cancel.statsProText:GetStringWidth()
                <= presetUI.cancel:GetWidth() - 16,
            "localized Cancel preview label overflows")
        check(prefix .. ".preset_apply_fit",
            presetUI.apply.statsProText:GetStringWidth()
                <= presetUI.apply:GetWidth() - 16,
            "localized Apply label overflows")
        eq(prefix .. ".preset_note_wrap", presetUI.note.wordWrap, true)
        eq(prefix .. ".preset_note_width", presetUI.note:GetWidth(), 426)
        eq(prefix .. ".preset_note_height", presetUI.note:GetHeight(), 52)
        eq(prefix .. ".preset_warning_width", presetUI.warning:GetWidth(), 426)
        eq(prefix .. ".preset_warning_height", presetUI.warning:GetHeight(), 36)
        local _, _, _, _, compactBodyY = presetUI.lowerBody:GetPoint()
        eq(prefix .. ".preset_compact_body_y", compactBodyY,
            presetUI.compactBodyTop)
        eq(prefix .. ".preset_compact_content_height",
            localeEnv.StatsProConfigFrame.appearanceTab.contentHeight,
            math.abs(compactBodyY) + presetUI.lowerBody.contentHeight)

        for index, frame in ipairs(localeEnv.__frames) do
            local kind = frame.statsProControlKind
            if kind == "checkbox" then
                local text = exists(prefix .. ".checkbox_text." .. index, frame.statsProText)
                check(prefix .. ".checkbox_nonempty." .. index, text:GetText() ~= "")
                eq(prefix .. ".checkbox_one_line." .. index, text.maxLines, 1)
                eq(prefix .. ".checkbox_no_wrap." .. index, text.wordWrap, false)
                if text:GetStringWidth() > text:GetWidth() then
                    local tooltip = frame.statsProTooltipProvider(frame)
                    check(prefix .. ".checkbox_overflow_tooltip." .. index,
                        type(tooltip) == "string" and tooltip ~= "",
                        "overflowing checkbox has no tooltip")
                    if frame:IsEnabled() then
                        eq(prefix .. ".checkbox_overflow_text." .. index,
                            tooltip, text:GetText())
                    end
                end
            elseif kind == "slider" then
                check(prefix .. ".slider_label_nonempty." .. index,
                    frame.statsProLabel:GetText() ~= "")
                check(prefix .. ".slider_value_nonempty." .. index,
                    frame.statsProValueText:GetText() ~= "")
                check(prefix .. ".slider_bounds_nonempty." .. index,
                    frame.statsProLowText:GetText() ~= ""
                        and frame.statsProHighText:GetText() ~= "")
            elseif kind == "dropdown" then
                check(prefix .. ".dropdown_caption_nonempty." .. index,
                    frame.statsProText:GetText() ~= "")
                check(prefix .. ".dropdown_label_nonempty." .. index,
                    frame.statsProDropdown.statsProLabel:GetText() ~= "")
                check(prefix .. ".dropdown_label_cap." .. index,
                    frame.statsProDropdown.statsProLabel:GetWidth() <= 210,
                    "dropdown label exceeds the two-column cap")
                if frame.statsProText:GetStringWidth() > frame.statsProText:GetWidth() then
                    eq(prefix .. ".dropdown_overflow_tooltip." .. index,
                        frame.statsProTooltipProvider(frame), frame.statsProText:GetText())
                end
            elseif kind == "button" and frame.statsProText then
                check(prefix .. ".button_nonempty." .. index,
                    frame.statsProText:GetText() ~= "")
                eq(prefix .. ".button_one_line." .. index,
                    frame.statsProText.maxLines, 1)
                eq(prefix .. ".button_no_wrap." .. index,
                    frame.statsProText.wordWrap, false)
            end
        end

        localeEnv.StatsProOffensiveCheck:SetChecked(false)
        userInteract(prefix .. ".dependency_disable",
            localeEnv.StatsProOffensiveCheck, "OnClick")
        userInteract(prefix .. ".dependency_tooltip",
            localeEnv.StatsProCritCheck, "OnEnter")
        local registry = localeTest.registrySnapshot()
        local labels = registry.labelsByLocale[locale]
        eq(prefix .. ".dependency_tooltip_text",
            localeEnv.GameTooltip.lines[1].left,
            string.format(labels["Requires %s."], labels["Show Offensive Stats"]))
        userInteract(prefix .. ".dependency_tooltip_leave",
            localeEnv.StatsProCritCheck, "OnLeave")

        eq(prefix .. ".min_height", localeEnv.StatsProConfigFrame:GetHeight(), 260)
        check(prefix .. ".warning_reserved_fit",
            localeEnv.StatsProConfigFrame.languageWarning:GetWidth() <= 426,
            "localized warning exceeds minimum viewport width")
    end
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
    eq("config.language_enGB_uses_english.db_stays_auto", accountSettings(enGBEnv).forceLocale, "auto")
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
    eq("config.language_enGB_not_accepted_as_explicit.account_normalized",
        accountSettings(invalidEnv).forceLocale, "auto")
    eq("config.language_enGB_not_accepted_as_explicit.shadow_unchanged",
        invalidEnv.StatsProDB.forceLocale, "enGB")
end

do
    local warningTemplate =
        "|cffffaa44⚠|r The selected font may not render %s correctly. Pick a SharedMedia font with proper coverage."
    local cases = {
        { locale = "ruRU", requirement = "Cyrillic", labelKey = "Russian text" },
        { locale = "koKR", requirement = "Hangul", labelKey = "Korean text" },
        { locale = "zhCN", requirement = "Hans", labelKey = "Simplified Chinese text" },
        { locale = "zhTW", requirement = "Hant", labelKey = "Traditional Chinese text" },
    }
    local registry = test.registrySnapshot()
    local coveredLocales, requiredLocales = {}, {}
    for locale, requirement in pairs(registry.localeGlyphReq) do
        if requirement ~= "Latin" then requiredLocales[locale] = true end
    end
    for _, case in ipairs(cases) do coveredLocales[case.locale] = true end
    for locale in pairs(requiredLocales) do
        eq("config.language_warning_copy.non_latin_matrix.required." .. locale,
            coveredLocales[locale], true)
    end
    for locale in pairs(coveredLocales) do
        eq("config.language_warning_copy.non_latin_matrix.covered." .. locale,
            requiredLocales[locale], true)
    end

    local internalTokens = { "Cyrillic", "Hangul", "Hans", "Hant" }
    for _, case in ipairs(cases) do
        local warningEnv, warningAddon, warningTest = loadStatsPro("enUS", {
            statsProDB = {
                forceLocale = case.locale,
                font = "Fonts\\FRIZQT__.TTF",
            },
        })
        warningTest.cacheSettings()
        eq("config.language_warning_copy.precondition." .. case.locale,
            warningTest.fontSupports("Fonts\\FRIZQT__.TTF", case.requirement), false)
        eq("config.language_warning_copy.mapping." .. case.locale,
            warningAddon.fontRuntime.GlyphRequirementLabelKey(case.requirement), case.labelKey)
        local ok, err = pcall(function() warningAddon:OpenConfigMenu() end)
        check("config.language_warning_copy.open." .. case.locale, ok, err)
        local warning = exists("config.language_warning_copy.warning." .. case.locale,
            warningEnv.StatsProConfigFrame.languageWarning)
        local labels = warningTest.registrySnapshot().labelsByLocale[case.locale]
        local expected = string.format(labels[warningTemplate], labels[case.labelKey])
        eq("config.language_warning_copy.exact." .. case.locale, warning:GetText(), expected)
        eq("config.language_warning_copy.surface." .. case.locale,
            warning.statsProWarningSurface:IsShown(), true)
        eq("config.language_warning_copy.rail." .. case.locale,
            warning.statsProWarningRail:IsShown(), true)
        for _, token in ipairs(internalTokens) do
            eq("config.language_warning_copy.no_internal_token."
                .. case.locale .. "." .. token,
                string.find(warning:GetText(), token, 1, true), nil)
        end
    end
    eq("config.language_warning_copy.unknown_fallback",
        addon.fontRuntime.GlyphRequirementLabelKey("FutureGlyphRequirement"),
        "text for the selected language")
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
    eq("config.language_warning_layout.surface_visible",
        warning.statsProWarningSurface:IsShown(), true)
    eq("config.language_warning_layout.rail_visible",
        warning.statsProWarningRail:IsShown(), true)
    for index, border in ipairs(warning.statsProWarningSurface.statsProBorders) do
        eq("config.language_warning_layout.border_visible." .. index,
            border:IsShown(), true)
    end
    local warningTokens = warningTest.settingsDesignSnapshot()
    assertColor("config.language_warning_layout.rail_color",
        warning.statsProWarningRail.colorTexture,
        warningTokens.colors.warning[1], warningTokens.colors.warning[2],
        warningTokens.colors.warning[3])
    near("config.language_warning_layout.rail_color.a",
        warning.statsProWarningRail.colorTexture.a, warningTokens.colors.warning[4])
    eq("config.language_warning_layout.word_wrap", warning.wordWrap, true)
    eq("config.language_warning_layout.max_lines", warning.maxLines, 2)
    eq("config.language_warning_layout.two_line_height", warning:GetHeight(), 40)
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
    local flatDisplayBefore = rawget(env.StatsProDB, "displayMode")
    local flatLocaleBefore = rawget(env.StatsProDB, "forceLocale")
    local flatIntervalBefore = rawget(env.StatsProDB, "updateInterval")

    local ok, err = pcall(function() addon:OpenConfigMenu() end)
    check("config.open_constructs_frame", ok, err)
    local validationCountBeforeUIWrites = test.dbValidationCount()

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
        local languageHoverRoot = env.StatsProDB
        local languageHoverBefore = deepCopy(languageHoverRoot)

        ok, err = pcall(ruEnter, env.DropDownList1Button1)
        check("config.language_hover_restore.preview_ru", ok, err)
        local afterRuPreview = test.panelFontState()
        check("config.language_hover_restore.ru_swaps_font",
            afterRuPreview.mainLabelFont ~= defaultFont,
            "ruRU hover did not exercise fallback-font preview")
        eq("config.language_hover_restore.ru_snapshot_month_preview", test.formatSnapshotDate("2026-05-15"), "15-май-26")
        assertDeepEqual("config.language_hover_restore.ru_zero_writes",
            env.StatsProDB, languageHoverBefore)
        eq("config.language_hover_restore.ru_root_identity",
            rawequal(env.StatsProDB, languageHoverRoot), true)

        test.setPanelAppliedStyleForSmoke(defaultFont, 14)
        ok, err = pcall(enEnter, env.DropDownList1Button2)
        check("config.language_hover_restore.preview_en", ok, err)
        local afterEnPreview = test.panelFontState()
        eq("config.language_hover_restore.forces_main_font", afterEnPreview.mainLabelFont, defaultFont)
        eq("config.language_hover_restore.forces_side_font", afterEnPreview.sideLabelFont, defaultFont)
        eq("config.language_hover_restore.en_snapshot_month_preview", test.formatSnapshotDate("2026-05-15"), "15-May-26")
        assertDeepEqual("config.language_hover_restore.en_zero_writes",
            env.StatsProDB, languageHoverBefore)

        env.DropDownList1:Hide()
        env.UIDROPDOWNMENU_OPEN_MENU = nil
        assertDeepEqual("config.language_hover_restore.close_zero_writes",
            env.StatsProDB, languageHoverBefore)
    end

    selectDropdownValue("config.dropdown_display_mode_split_writes_db", env.StatsProDisplayModeDropdown, "split")
    eq("config.dropdown_display_mode_split_writes_db.value", activeSettings(env).displayMode, "split")
    eq("config.dropdown_display_mode_split_writes_db.no_flat_write",
        rawget(env.StatsProDB, "displayMode"), flatDisplayBefore)
    eq("config.dropdown_display_mode_split_writes_db.split_check_enabled",
        env.StatsProSplitOffensiveCheck:IsEnabled(), true)

    selectDropdownValue("config.dropdown_target_snapshot_raid_writes_db", env.StatsProTargetSnapshotDropdown, "raid")
    eq("config.dropdown_target_snapshot_raid_writes_db.value", activeSettings(env).targetSnapshot, "raid")
    eq("config.dropdown_target_snapshot_raid_writes_db.cache", test.cachedTargetSnapshot(), "raid")

    selectDropdownValue("config.dropdown_label_style_hidden_writes_db", env.StatsProLabelStyleDropdown, "hidden")
    eq("config.dropdown_label_style_hidden_writes_db.value", activeSettings(env).labelStyle, "hidden")

    selectDropdownValue("config.dropdown_text_outline_none_writes_db", env.StatsProTextOutlineDropdown, "none")
    eq("config.dropdown_text_outline_none_writes_db.value", activeSettings(env).textOutlineStyle, "none")
    do
        local visualState = test.panelVisualState()
        eq("config.dropdown_text_outline_none_writes_db.cache", visualState.textOutlineStyle, "none")
        eq("config.dropdown_text_outline_none_writes_db.main_label_flags", visualState.mainLabelFlags, nil)
        eq("config.dropdown_text_outline_none_writes_db.side_repair_label_flags", visualState.sideRepairLabelFlags, nil)
    end

    selectDropdownValue("config.dropdown_text_outline_thick_writes_db", env.StatsProTextOutlineDropdown, "thick")
    eq("config.dropdown_text_outline_thick_writes_db.value", activeSettings(env).textOutlineStyle, "thick")
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
    eq("config.dropdown_language_ruRU_commits_locale.value", accountSettings(env).forceLocale, "ruRU")
    eq("config.dropdown_language_ruRU_commits_locale.not_profile", rawget(activeSettings(env), "forceLocale"), nil)
    eq("config.dropdown_language_ruRU_commits_locale.no_flat_write",
        rawget(env.StatsProDB, "forceLocale"), flatLocaleBefore)
    eq("config.dropdown_language_ruRU_commits_locale.launcher",
        test.launcherDescriptionText(),
        "HUD характеристик и экипировки: уровень предметов, прочность, стоимость ремонта и цели характеристик Archon. Нажмите ниже, чтобы открыть окно настроек.")

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
    eq("config.checkbox_visible_updates_db.value", activeSettings(env).isVisible, false)
    clickCheckbox("config.checkbox_tertiary_master_enables_dependents", env.StatsProTertiaryCheck, true)
    eq("config.checkbox_tertiary_master_enables_dependents.leech", env.StatsProLeechCheck:IsEnabled(), true)
    clickCheckbox("config.checkbox_tertiary_master_disables_dependents", env.StatsProTertiaryCheck, false)
    eq("config.checkbox_tertiary_master_disables_dependents.leech", env.StatsProLeechCheck:IsEnabled(), false)
    clickCheckbox("config.checkbox_defensive_master_enables_dependents", env.StatsProDefensiveCheck, true)
    eq("config.checkbox_defensive_master_enables_dependents.stagger", env.StatsProStaggerCheck:IsEnabled(), true)
    clickCheckbox("config.checkbox_defensive_master_disables_dependents", env.StatsProDefensiveCheck, false)
    eq("config.checkbox_defensive_master_disables_dependents.stagger", env.StatsProStaggerCheck:IsEnabled(), false)
    clickCheckbox("config.checkbox_repair_cost_updates_db", env.StatsProRepairCostCheck, true)
    eq("config.checkbox_repair_cost_updates_db.value", activeSettings(env).showRepairCost, true)

    local updateBefore = test.cachedUpdateInterval()
    changeSlider("config.slider_refresh_deferred.first", env.StatsProRefreshSlider, 0.2)
    changeSlider("config.slider_refresh_deferred.second", env.StatsProRefreshSlider, 0.8)
    near("config.slider_refresh_deferred.account_write", accountSettings(env).updateInterval, 0.8)
    eq("config.slider_refresh_deferred.not_profile", rawget(activeSettings(env), "updateInterval"), nil)
    eq("config.slider_refresh_deferred.no_flat_write",
        rawget(env.StatsProDB, "updateInterval"), flatIntervalBefore)
    near("config.slider_refresh_deferred.cache_before_timer", test.cachedUpdateInterval(), updateBefore)
    flushTimers("config.slider_refresh_deferred.flush", env, 0.05, 2)
    near("config.slider_refresh_deferred.cache_after_timer", test.cachedUpdateInterval(), 0.8)

    changeSlider("config.slider_text_alpha_immediate", env.StatsProTextAlphaSlider, 55)
    eq("config.slider_text_alpha_immediate.db", activeSettings(env).textAlpha, 55)
    near("config.slider_text_alpha_immediate.cache", test.cachedTextAlpha(), 0.55)

    changeSlider("config.slider_panel_background_immediate", env.StatsProPanelBackgroundSlider, 45)
    eq("config.slider_panel_background_immediate.db", activeSettings(env).panelBackgroundAlpha, 45)
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
    eq("config.font_picker_surface.window", env.StatsProFontPicker.statsProSurfaceRole, "window")
    eq("config.font_picker_surface.viewport",
        env.StatsProFontPicker.statsProViewport.statsProSurfaceRole, "viewport")
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
        local color = frame.statsProDisplayedColor
        return frame.statsProColorKey == "crit" and type(frame.scripts.OnClick) == "function"
            and color and color.r == 1 and color.g == 0 and color.b == 0
    end)
    callScript("config.color_picker.open", critSwatch, "OnClick")
    local colorOptions = exists("config.color_picker.options", env.ColorPickerFrame.colorPickerOptions)
    env.__setColorPickerRGB(0.2, 0.3, 0.4)
    ok, err = pcall(colorOptions.swatchFunc)
    check("config.color_picker.select", ok, err)
    ok, err = pcall(env.__acceptColorPicker)
    check("config.color_picker.select_commit", ok, err)
    assertColor("config.color_picker.select_db", activeSettings(env).colors.crit, 0.2, 0.3, 0.4)
    ok, err = pcall(env.StatsProCloseColorPicker)
    check("config.color_picker.accept_clears_owned_session", ok, err)
    assertColor("config.color_picker.accept_preserves_commit", activeSettings(env).colors.crit, 0.2, 0.3, 0.4)

    callScript("config.color_picker.reopen_for_cancel", critSwatch, "OnClick")
    env.__setColorPickerRGB(0.6, 0.7, 0.8)
    ok, err = pcall(env.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.preview_before_cancel", ok, err)
    env.__cancelColorPicker()
    assertColor("config.color_picker.cancel_restores_snapshot", activeSettings(env).colors.crit, 0.2, 0.3, 0.4)

    activeSettings(env).colors.crit = nil
    callScript("config.color_picker.default_cancel_open", critSwatch, "OnClick")
    env.__setColorPickerRGB(0.7, 0.8, 0.9)
    ok, err = pcall(env.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.default_preview", ok, err)
    env.__cancelColorPicker()
    eq("config.color_picker.default_cancel_preserves_nil", activeSettings(env).colors.crit, nil)

    callScript("config.color_picker.reset_closes_picker.open", critSwatch, "OnClick")
    env.__setColorPickerRGB(0.4, 0.5, 0.6)
    ok, err = pcall(env.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.reset_closes_picker.preview", ok, err)
    assertColor("config.color_picker.reset_closes_picker.preview_db",
        activeSettings(env).colors.crit, 0.4, 0.5, 0.6)
    slash("config.reset_closes_color_picker", env, "reset")
    eq("config.reset_closes_color_picker.hidden", env.ColorPickerFrame:IsShown(), false)
    eq("config.reset_closes_color_picker.restores_unaccepted_preview",
        activeSettings(env).colors.crit, nil)
    eq("config.mutation_gate.reuses_full_validation",
        test.dbValidationCount(), validationCountBeforeUIWrites)
end

do
    local shellEnv, shellAddon, shellTest = loadStatsPro("enUS", {
        uiParentWidth = 1024,
        uiParentHeight = 768,
    })
    fireEvent("config.shell.pew", shellEnv, "PLAYER_ENTERING_WORLD")
    local rootBefore = deepCopy(shellEnv.StatsProDB)
    local rootRef = shellEnv.StatsProDB
    local accountRef = rootRef.account
    local profilesRef = rootRef.profiles
    local charactersRef = rootRef.characters
    local onUpdateBefore = 0
    for _, frame in ipairs(shellEnv.__frames) do
        if type(frame.scripts.OnUpdate) == "function" then onUpdateBefore = onUpdateBefore + 1 end
    end

    shellAddon:OpenConfigMenu()
    local config = exists("config.shell.frame", shellEnv.StatsProConfigFrame)
    local state = exists("config.shell.state", shellTest.settingsShellState())
    local shell = exists("config.shell.surface_registry", state.shell)
    local tokens = shellTest.settingsDesignSnapshot()
    local detached = shellTest.settingsDesignSnapshot()
    tokens.colors.window[1] = 0.99
    near("config.shell.tokens.detached", detached.colors.window[1], 0.018)
    near("config.shell.tokens.window_alpha", detached.colors.window[4], 0.96)
    near("config.shell.tokens.accent_green", detached.colors.accent[2], 0.82)
    eq("config.shell.tokens.window_width", detached.geometry.windowWidth, 500)
    eq("config.shell.tokens.min_hit_target", detached.geometry.minHitTarget, 24)
    eq("config.shell.tokens.equal_tab_width", detached.geometry.tabWidth, 152)

    eq("config.shell.window.role", config.statsProSurfaceRole, "window")
    assertColor("config.shell.window.color", config.backdropColor,
        detached.colors.window[1], detached.colors.window[2], detached.colors.window[3])
    near("config.shell.window.color.a", config.backdropColor.a, detached.colors.window[4])
    eq("config.shell.window.strata", config:GetFrameStrata(), "DIALOG")
    eq("config.shell.window.toplevel", config.toplevel, nil)
    eq("config.shell.window.movable", config:IsMovable(), true)
    eq("config.shell.window.clamped", config:IsClampedToScreen(), true)
    eq("config.shell.window.drag_button", config.dragButtons[1], "LeftButton")
    eq("config.shell.window.width", config:GetWidth(), detached.geometry.windowWidth)
    eq("config.shell.window.height", config:GetHeight(), detached.geometry.maxHeight)

    eq("config.shell.title.role", shell.titleSurface.statsProSurfaceRole, "raised")
    eq("config.shell.profile.role", shell.profileHeader.statsProSurfaceRole, "profile")
    eq("config.shell.viewport.role", shell.viewport.statsProSurfaceRole, "viewport")
    eq("config.shell.footer.role", shell.footer.statsProSurfaceRole, "raised")
    eq("config.shell.title.parent_owned_region", shell.titleSurface:GetParent(), config)
    eq("config.shell.viewport.parent_owned_region", shell.viewport:GetParent(), config)
    eq("config.shell.footer.parent_owned_region", shell.footer:GetParent(), config)
    eq("config.shell.title.region_type", shell.titleSurface.regionType, "Texture")
    eq("config.shell.viewport.region_type", shell.viewport.regionType, "Texture")
    eq("config.shell.footer.region_type", shell.footer.regionType, "Texture")
    eq("config.shell.title.surface_height", shell.titleSurface:GetHeight(),
        detached.geometry.titleSurfaceHeight)
    eq("config.shell.profile.top", shell.profileHeader.points[1][3],
        -detached.geometry.profileTop)
    eq("config.shell.profile.height", shell.profileHeader:GetHeight(),
        detached.geometry.profileHeight)
    eq("config.shell.tabs.top", shell.tabStrip.points[1][3], -detached.geometry.tabTop)
    eq("config.shell.tabs.height", shell.tabStrip:GetHeight(), detached.geometry.tabHeight)
    eq("config.shell.viewport.top", shell.viewport.points[1][3], -detached.geometry.viewportTop)
    eq("config.shell.viewport.bottom", shell.viewport.points[2][3], detached.geometry.viewportBottom)
    eq("config.shell.scroll.top", shell.scroll.points[1][3], -detached.geometry.scrollTop)
    eq("config.shell.scroll.bottom", shell.scroll.points[2][3], detached.geometry.scrollBottom)
    eq("config.shell.footer.height", shell.footer:GetHeight(), detached.geometry.footerSurfaceHeight)
    eq("config.shell.scroll.child", shell.scroll.scrollChild, shell.scrollChild)
    eq("config.shell.scroll.child_width", shell.scrollChild:GetWidth(), detached.geometry.contentWidth)
    eq("config.shell.scroll.styled", shell.scroll.statsProScrollbarStyled, true)
    local scrollBar = shell.scroll.ScrollBar
    local thumb = scrollBar.ThumbTexture
    local scrollUp = scrollBar.ScrollUpButton
    local scrollDown = scrollBar.ScrollDownButton
    exists("config.shell.scroll.thumb_color", thumb.vertexColor)
    near("config.shell.scroll.thumb_normal.r", thumb.vertexColor.r, detached.colors.textMuted[1])
    near("config.shell.scroll.thumb_normal.a", thumb.vertexColor.a, 0.62)
    eq("config.shell.scroll.track_role", shell.scroll.statsProScrollTrack.statsProColorRole,
        "scrollbarTrack")
    eq("config.shell.scroll.track_width", shell.scroll.statsProScrollTrack:GetWidth(),
        detached.geometry.scrollbarTrackWidth)
    eq("config.shell.scroll.up_styled", scrollUp.statsProScrollbarButtonStyled, true)
    eq("config.shell.scroll.down_styled", scrollDown.statsProScrollbarButtonStyled, true)
    eq("config.shell.scroll.up_normal_desaturated", scrollUp:GetNormalTexture().desaturated, true)
    eq("config.shell.scroll.up_highlight_desaturated", scrollUp:GetHighlightTexture().desaturated, true)
    eq("config.shell.scroll.up_pushed_desaturated", scrollUp:GetPushedTexture().desaturated, true)
    eq("config.shell.scroll.up_disabled_desaturated", scrollUp:GetDisabledTexture().desaturated, true)
    runFrameHandlers(scrollBar, "OnEnter")
    near("config.shell.scroll.thumb_hover.g", thumb.vertexColor.g, detached.colors.accent[2])
    near("config.shell.scroll.thumb_hover.a", thumb.vertexColor.a, 0.78)
    runFrameHandlers(scrollBar, "OnMouseDown", "LeftButton")
    eq("config.shell.scroll.thumb_pressed_state", scrollBar.statsProPressed, true)
    runFrameHandlers(scrollBar, "OnMouseUp", "LeftButton")
    eq("config.shell.scroll.thumb_released_state", scrollBar.statsProPressed, false)
    runFrameHandlers(scrollBar, "OnLeave")
    near("config.shell.scroll.thumb_leave.r", thumb.vertexColor.r, detached.colors.textMuted[1])
    eq("config.shell.profile.field_width", shellEnv.StatsProActiveProfileButton:GetWidth(),
        detached.geometry.profileFieldWidth)
    eq("config.shell.profile.manage_width", shellEnv.StatsProManageProfilesButton:GetWidth(),
        detached.geometry.manageWidth)
    eq("config.shell.profile.button_height", shellEnv.StatsProActiveProfileButton:GetHeight(),
        detached.geometry.minHitTarget)
    eq("config.shell.footer.reset_height", shell.resetButton:GetHeight(),
        detached.geometry.shellButtonHeight)
    eq("config.shell.footer.reset_width", shell.resetButton:GetWidth(),
        detached.geometry.resetButtonWidth)
    eq("config.shell.footer.close_height", shell.closeButton:GetHeight(),
        detached.geometry.shellButtonHeight)
    eq("config.shell.footer.close_width", shell.closeButton:GetWidth(),
        detached.geometry.closeButtonWidth)
    eq("config.shell.footer.contact_group_parent", shell.footerContactGroup:GetParent(), config)
    eq("config.shell.footer.contact_group_height", shell.footerContactGroup:GetHeight(),
        detached.geometry.footerSurfaceHeight)
    eq("config.shell.footer.signature_parent", shell.footerSignature:GetParent(),
        shell.footerContactGroup)
    eq("config.shell.footer.signature_text", shell.footerSignature:GetText(), "Made with")
    eq("config.shell.footer.signature_mouse_passthrough",
        shell.footerSignature:IsMouseEnabled(), false)
    eq("config.shell.footer.heart_parent", shell.footerHeart:GetParent(),
        shell.footerContactGroup)
    eq("config.shell.footer.heart_text", shell.footerHeart:GetText(), "♥")
    eq("config.shell.footer.heart_font", shell.footerHeart.font, "Fonts\\ARIALN.TTF")
    assertRGBA("config.shell.footer.heart_color", shell.footerHeart.textColor,
        detached.colors.danger[1], detached.colors.danger[2],
        detached.colors.danger[3], detached.colors.danger[4])
    eq("config.shell.footer.contact_parent", shell.contactButton:GetParent(),
        shell.footerContactGroup)
    eq("config.shell.footer.contact_width", shell.contactButton:GetWidth(), 104)
    eq("config.shell.footer.contact_height", shell.contactButton:GetHeight(),
        detached.geometry.minHitTarget)
    eq("config.shell.footer.contact_role", shell.contactButton.statsProButtonRole, "field")
    eq("config.shell.footer.reset_role", shell.resetButton.statsProButtonRole, "destructive")
    eq("config.shell.footer.close_role", shell.closeButton.statsProButtonRole, "primary")

    local selectedTabs = 0
    for index, tab in ipairs(state.tabs) do
        eq("config.shell.tabs.width." .. index, tab:GetWidth(), detached.geometry.tabWidth)
        eq("config.shell.tabs.height." .. index, tab:GetHeight(), detached.geometry.tabHeight)
        if tab.statsProSelected then selectedTabs = selectedTabs + 1 end
    end
    eq("config.shell.tabs.gap.second", state.tabs[2].points[1][4], detached.geometry.tabGap)
    eq("config.shell.tabs.gap.third", state.tabs[3].points[1][4], detached.geometry.tabGap)
    eq("config.shell.tabs.one_selected.initial", selectedTabs, 1)
    eq("config.shell.tabs.initial_index", config.activeTabIndex, 1)
    eq("config.shell.tabs.second.normal", state.tabs[2].statsProTabState, "normal")
    assertRGBA("config.shell.tabs.second.normal_fill", state.tabs[2].statsProFill.colorTexture,
        detached.colors.raised[1], detached.colors.raised[2], detached.colors.raised[3], 0)
    assertRGBA("config.shell.tabs.second.normal_text", state.tabs[2].statsProText.textColor,
        detached.colors.textSecondary[1], detached.colors.textSecondary[2],
        detached.colors.textSecondary[3], detached.colors.textSecondary[4])
    eq("config.shell.tabs.second.normal_line", state.tabs[2].statsProSelectedLine:IsShown(), false)
    runFrameHandlers(state.tabs[2], "OnEnter")
    eq("config.shell.tabs.second.hover", state.tabs[2].statsProTabState, "hover")
    assertRGBA("config.shell.tabs.second.hover_fill", state.tabs[2].statsProFill.colorTexture,
        detached.colors.hover[1], detached.colors.hover[2], detached.colors.hover[3],
        detached.colors.hover[4])
    runFrameHandlers(state.tabs[2], "OnMouseDown", "LeftButton")
    eq("config.shell.tabs.second.pressed", state.tabs[2].statsProTabState, "pressed")
    assertRGBA("config.shell.tabs.second.pressed_fill", state.tabs[2].statsProFill.colorTexture,
        detached.colors.pressed[1], detached.colors.pressed[2], detached.colors.pressed[3],
        detached.colors.pressed[4])
    runFrameHandlers(state.tabs[2], "OnMouseUp", "LeftButton")
    eq("config.shell.tabs.second.hover_after_up", state.tabs[2].statsProTabState, "hover")
    runFrameHandlers(state.tabs[2], "OnLeave")
    eq("config.shell.tabs.second.normal_after_leave", state.tabs[2].statsProTabState, "normal")
    shell.scroll:SetVerticalScroll(100)
    runFrameHandlers(state.tabs[2], "OnClick")
    eq("config.shell.tabs.second.selected", state.tabs[2].statsProTabState, "selected")
    assertRGBA("config.shell.tabs.second.selected_fill", state.tabs[2].statsProFill.colorTexture,
        detached.colors.accentMuted[1], detached.colors.accentMuted[2],
        detached.colors.accentMuted[3], detached.colors.accentMuted[4])
    eq("config.shell.tabs.second.selected_line", state.tabs[2].statsProSelectedLine:IsShown(), true)
    assertRGBA("config.shell.tabs.second.selected_line_color",
        state.tabs[2].statsProSelectedLine.colorTexture,
        detached.colors.accent[1], detached.colors.accent[2], detached.colors.accent[3],
        detached.colors.accent[4])
    eq("config.shell.tabs.second.active_index", config.activeTabIndex, 2)
    eq("config.shell.tabs.second.scroll_reset", shell.scroll:GetVerticalScroll(), 0)
    selectedTabs = 0
    for _, tab in ipairs(state.tabs) do
        if tab.statsProSelected then selectedTabs = selectedTabs + 1 end
    end
    eq("config.shell.tabs.one_selected.after_click", selectedTabs, 1)
    runFrameHandlers(state.tabs[2], "OnEnter")
    assertRGBA("config.shell.tabs.selected_hover_fill", state.tabs[2].statsProFill.colorTexture,
        detached.colors.hover[1], detached.colors.hover[2], detached.colors.hover[3],
        detached.colors.hover[4])
    runFrameHandlers(state.tabs[2], "OnMouseDown", "LeftButton")
    assertRGBA("config.shell.tabs.selected_pressed_fill", state.tabs[2].statsProFill.colorTexture,
        detached.colors.pressed[1], detached.colors.pressed[2], detached.colors.pressed[3],
        detached.colors.pressed[4])
    runFrameHandlers(state.tabs[2], "OnMouseUp", "LeftButton")
    runFrameHandlers(state.tabs[2], "OnLeave")
    assertRGBA("config.shell.tabs.selected_leave_fill", state.tabs[2].statsProFill.colorTexture,
        detached.colors.accentMuted[1], detached.colors.accentMuted[2],
        detached.colors.accentMuted[3], detached.colors.accentMuted[4])
    eq("config.shell.tabs.selected_leave_line", state.tabs[2].statsProSelectedLine:IsShown(), true)

    local sectionCount = 0
    for tabIndex, sections in ipairs(state.sections) do
        check("config.shell.sections.present." .. tabIndex, #sections > 0)
        for sectionIndex, section in ipairs(sections) do
            sectionCount = sectionCount + 1
            eq("config.shell.sections.role." .. tabIndex .. "." .. sectionIndex,
                section.surface.statsProSurfaceRole, "section")
            eq("config.shell.sections.text_role." .. tabIndex .. "." .. sectionIndex,
                section.text.statsProTextRole, "section")
            check("config.shell.sections.localized_text." .. tabIndex .. "." .. sectionIndex,
                section.text:GetText() ~= "" and not string.find(section.text:GetText(), "|cff", 1, true))
            eq("config.shell.sections.mouse_passthrough." .. tabIndex .. "." .. sectionIndex,
                section.surface:IsMouseEnabled(), false)
        end
    end
    check("config.shell.sections.total", sectionCount >= 8)

    runFrameHandlers(shell.resetButton, "OnEnter")
    eq("config.shell.reset.hover_state", shell.resetButton.statsProButtonState, "hover")
    assertRGBA("config.shell.reset.hover_border", shell.resetButton.backdropBorderColor,
        detached.colors.danger[1], detached.colors.danger[2], detached.colors.danger[3],
        detached.colors.danger[4])
    assertRGBA("config.shell.reset.hover_text", shell.resetButton.statsProText.textColor,
        detached.colors.danger[1], detached.colors.danger[2], detached.colors.danger[3],
        detached.colors.danger[4])
    runFrameHandlers(shell.resetButton, "OnLeave")
    eq("config.shell.reset.normal_state", shell.resetButton.statsProButtonState, "normal")
    assertRGBA("config.shell.reset.normal_border", shell.resetButton.backdropBorderColor,
        detached.colors.borderSoft[1], detached.colors.borderSoft[2],
        detached.colors.borderSoft[3], detached.colors.borderSoft[4])
    runFrameHandlers(shell.closeButton, "OnEnter")
    eq("config.shell.close.hover_state", shell.closeButton.statsProButtonState, "hover")
    assertRGBA("config.shell.close.hover_border", shell.closeButton.backdropBorderColor,
        detached.colors.accent[1], detached.colors.accent[2], detached.colors.accent[3],
        detached.colors.accent[4])
    runFrameHandlers(shell.closeButton, "OnLeave")
    eq("config.shell.close.normal_state", shell.closeButton.statsProButtonState, "normal")
    assertRGBA("config.shell.close.normal_border", shell.closeButton.backdropBorderColor,
        detached.colors.accentMuted[1], detached.colors.accentMuted[2],
        detached.colors.accentMuted[3], detached.colors.accentMuted[4])

    local contactDBBefore = deepCopy(shellEnv.StatsProDB)
    userInteract("config.shell.footer.contact_hover", shell.contactButton, "OnEnter")
    eq("config.shell.footer.contact_tooltip_owner", shellEnv.GameTooltip:GetOwner(),
        shell.contactButton)
    eq("config.shell.footer.contact_tooltip_title", shellEnv.GameTooltip.lines[1].left,
        "Contact")
    eq("config.shell.footer.contact_tooltip_detail", shellEnv.GameTooltip.lines[2].left,
        "Click to copy the project contact link.")
    userInteract("config.shell.footer.contact_leave", shell.contactButton, "OnLeave")
    userInteract("config.shell.footer.contact_click", shell.contactButton, "OnClick")
    local contactPopup = exists("config.shell.footer.contact_popup", shellEnv.__lastStaticPopup)
    eq("config.shell.footer.contact_popup_key", contactPopup.key,
        "STATSPRO_COPY_CONTACT_LINK")
    eq("config.shell.footer.contact_popup_message", contactPopup.textArg1,
        "StatsPro — Contact\nCopy the link below (Ctrl+C).")
    eq("config.shell.footer.contact_popup_url", contactPopup.data.url,
        "https://github.com/Antrakt92/StatsPro/issues")
    eq("config.shell.footer.contact_editbox_url", contactPopup.EditBox:GetText(),
        "https://github.com/Antrakt92/StatsPro/issues")
    eq("config.shell.footer.contact_editbox_selected", contactPopup.EditBox.highlightedText,
        "https://github.com/Antrakt92/StatsPro/issues")
    eq("config.shell.footer.contact_editbox_focus", contactPopup.EditBox:HasFocus(), true)
    eq("config.shell.footer.contact_popup_close_label", contactPopup.definition.button1, "Close")
    contactPopup.definition.EditBoxOnEnterPressed(contactPopup:GetEditBox())
    eq("config.shell.footer.contact_enter_hides_popup", contactPopup:IsShown(), false)
    userInteract("config.shell.footer.contact_reopen", shell.contactButton, "OnClick")
    contactPopup = exists("config.shell.footer.contact_popup_reopened", shellEnv.__lastStaticPopup)
    config:Hide()
    eq("config.shell.footer.contact_config_hide_closes_popup",
        shellEnv.__lastStaticPopup, nil)
    assertDeepEqual("config.shell.footer.contact_zero_writes", shellEnv.StatsProDB,
        contactDBBefore)
    config:Show()

    callScript("config.shell.drag.start", config, "OnDragStart")
    eq("config.shell.drag.start_count", config.startMovingCalls, 1)
    eq("config.shell.drag.moving", config.moving, true)
    callScript("config.shell.drag.stop", config, "OnDragStop")
    eq("config.shell.drag.stop_count", config.stopMovingCalls, 1)
    eq("config.shell.drag.stopped", config.moving, false)

    callScript("config.shell.no_onupdate.font_picker_open",
        shellEnv.StatsProFontDropdownButton, "OnClick")
    shellEnv.StatsProFontPicker:Hide()
    callScript("config.shell.no_onupdate.manager_open",
        shellEnv.StatsProManageProfilesButton, "OnClick")
    eq("config.shell.layering.manager_level",
        shellEnv.StatsProProfileManager:GetFrameLevel(), config:GetFrameLevel() + 20)
    eq("config.shell.layering.operation_level",
        shellEnv.StatsProProfileOperationDialog:GetFrameLevel(),
        shellEnv.StatsProProfileManager:GetFrameLevel() + 10)
    eq("config.shell.layering.font_picker_level",
        shellEnv.StatsProFontPicker:GetFrameLevel(), config:GetFrameLevel() + 50)

    local onUpdateAfter = 0
    for _, frame in ipairs(shellEnv.__frames) do
        if type(frame.scripts.OnUpdate) == "function" then onUpdateAfter = onUpdateAfter + 1 end
    end
    eq("config.shell.no_onupdate_delta", onUpdateAfter, onUpdateBefore)
    assertDeepEqual("config.shell.navigation_zero_writes", shellEnv.StatsProDB, rootBefore)
    eq("config.shell.navigation_root_identity", shellEnv.StatsProDB, rootRef)
    eq("config.shell.navigation_account_identity", rootRef.account, accountRef)
    eq("config.shell.navigation_profiles_identity", rootRef.profiles, profilesRef)
    eq("config.shell.navigation_characters_identity", rootRef.characters, charactersRef)

    config:Hide()
    shellEnv.UIParent:SetSize(1024, 500)
    config:Show()
    eq("config.shell.onshow_resize.medium", config:GetHeight(), 450)
    config:Hide()
    shellEnv.UIParent:SetSize(2560, 1440)
    config:Show()
    eq("config.shell.onshow_resize.high", config:GetHeight(), 600)
    eq("config.shell.onshow_resize.width_stable", config:GetWidth(), detached.geometry.windowWidth)
end

do
    local secretHeight
    local resizeEnv, resizeAddon, resizeTest = loadStatsPro("enUS", {
        uiParentWidth = 1024,
        uiParentHeight = 768,
        issecretvalue = function(value)
            return secretHeight ~= nil and value == secretHeight
        end,
    })
    fireEvent("config.live_resize.pew", resizeEnv, "PLAYER_ENTERING_WORLD")
    local rootBefore = deepCopy(resizeEnv.StatsProDB)
    local rootRef = resizeEnv.StatsProDB
    local accountRef = rootRef.account
    local profilesRef = rootRef.profiles
    local charactersRef = rootRef.characters
    local onUpdateBefore = 0
    for _, frame in ipairs(resizeEnv.__frames) do
        if type(frame.scripts.OnUpdate) == "function" then onUpdateBefore = onUpdateBefore + 1 end
    end

    local preconstructionTimers = #resizeEnv.__timers
    resizeEnv.UIParent:SetSize(1024, 500)
    fireEvent("config.live_resize.preconstruction.display", resizeEnv, "DISPLAY_SIZE_CHANGED")
    fireEvent("config.live_resize.preconstruction.scale", resizeEnv, "UI_SCALE_CHANGED")
    eq("config.live_resize.preconstruction.no_frame", resizeEnv.StatsProConfigFrame, nil)
    eq("config.live_resize.preconstruction.no_timer", #resizeEnv.__timers, preconstructionTimers)

    resizeAddon:OpenConfigMenu()
    local config = exists("config.live_resize.frame", resizeEnv.StatsProConfigFrame)
    local shell = exists("config.live_resize.shell", resizeTest.settingsShellState().shell)
    local geometry = resizeTest.settingsDesignSnapshot().geometry
    eq("config.live_resize.first_open_current_height", config:GetHeight(), 450)

    config.SwitchToTab(3)
    shell.scroll:SetVerticalScroll(87)
    local pointsBefore = deepCopy(config.points)
    local originalSetSize = config.SetSize
    local resizeCalls = 0
    config.SetSize = function(frame, width, height)
        resizeCalls = resizeCalls + 1
        originalSetSize(frame, width, height)
    end

    local burstTimersBefore = #resizeEnv.__timers
    resizeEnv.UIParent:SetSize(1024, 520)
    fireEvent("config.live_resize.burst.display", resizeEnv, "DISPLAY_SIZE_CHANGED")
    resizeEnv.UIParent:SetSize(1024, 480)
    fireEvent("config.live_resize.burst.scale", resizeEnv, "UI_SCALE_CHANGED")
    eq("config.live_resize.burst.deferred", config:GetHeight(), 450)
    eq("config.live_resize.burst.two_callbacks", #resizeEnv.__timers, burstTimersBefore + 2)
    flushTimers("config.live_resize.burst.flush", resizeEnv, 0, 2)
    eq("config.live_resize.burst.one_apply", resizeCalls, 1)
    eq("config.live_resize.burst.latest_height", config:GetHeight(), 432)
    eq("config.live_resize.burst.width_stable", config:GetWidth(), geometry.windowWidth)
    eq("config.live_resize.burst.tab_preserved", config.activeTabIndex, 3)
    eq("config.live_resize.burst.scroll_preserved", shell.scroll:GetVerticalScroll(), 87)
    eq("config.live_resize.burst.scroll_child_preserved", shell.scroll.scrollChild, shell.scrollChild)
    assertDeepEqual("config.live_resize.burst.position_preserved", config.points, pointsBefore)
    eq("config.live_resize.burst.stays_visible", config:IsShown(), true)

    resizeCalls = 0
    resizeEnv.UIParent:SetSize(1024, 280)
    fireEvent("config.live_resize.minimum.display", resizeEnv, "DISPLAY_SIZE_CHANGED")
    flushTimers("config.live_resize.minimum.flush", resizeEnv, 0, 1)
    eq("config.live_resize.minimum.one_apply", resizeCalls, 1)
    eq("config.live_resize.minimum.height", config:GetHeight(), geometry.minHeight)
    check("config.live_resize.minimum.scroll_reachable",
        config:GetHeight() - geometry.scrollTop - geometry.scrollBottom > 0)
    check("config.live_resize.minimum.viewport_reachable",
        config:GetHeight() - geometry.viewportTop - geometry.viewportBottom > 0)
    check("config.live_resize.minimum.footer_reachable",
        geometry.footerSurfaceInset + geometry.footerSurfaceHeight < config:GetHeight())
    local footerTop = geometry.footerSurfaceInset + geometry.footerSurfaceHeight
    local buttonTop = geometry.footerButtonBottom + geometry.shellButtonHeight
    check("config.live_resize.minimum.buttons_inside_footer",
        geometry.footerButtonBottom >= geometry.footerSurfaceInset and buttonTop <= footerTop)
    check("config.live_resize.minimum.scroll_above_footer", geometry.scrollBottom >= footerTop)
    eq("config.live_resize.minimum.footer_parent", shell.footer:GetParent(), config)
    eq("config.live_resize.minimum.reset_parent", shell.resetButton:GetParent(), config)
    eq("config.live_resize.minimum.close_parent", shell.closeButton:GetParent(), config)

    local stableHeight = config:GetHeight()
    resizeEnv.UIParent.height = math.huge
    fireEvent("config.live_resize.invalid_parent.request", resizeEnv, "DISPLAY_SIZE_CHANGED")
    flushTimers("config.live_resize.invalid_parent.flush", resizeEnv, 0, 1)
    eq("config.live_resize.invalid_parent.preserved", config:GetHeight(), stableHeight)

    secretHeight = 777
    resizeEnv.UIParent.height = secretHeight
    fireEvent("config.live_resize.secret_parent.request", resizeEnv, "UI_SCALE_CHANGED")
    flushTimers("config.live_resize.secret_parent.flush", resizeEnv, 0, 1)
    eq("config.live_resize.secret_parent.preserved", config:GetHeight(), stableHeight)
    secretHeight = nil

    config:Hide()
    resizeEnv.UIParent:SetSize(2560, 1440)
    fireEvent("config.live_resize.hidden.request", resizeEnv, "DISPLAY_SIZE_CHANGED")
    flushTimers("config.live_resize.hidden.flush", resizeEnv, 0, 1)
    eq("config.live_resize.hidden.stays_hidden", config:IsShown(), false)
    eq("config.live_resize.hidden.current_height", config:GetHeight(), geometry.maxHeight)
    config:Show()
    eq("config.live_resize.hidden.show_height", config:GetHeight(), geometry.maxHeight)

    local onUpdateAfter = 0
    for _, frame in ipairs(resizeEnv.__frames) do
        if type(frame.scripts.OnUpdate) == "function" then onUpdateAfter = onUpdateAfter + 1 end
    end
    eq("config.live_resize.no_onupdate_delta", onUpdateAfter, onUpdateBefore)
    assertDeepEqual("config.live_resize.zero_writes", resizeEnv.StatsProDB, rootBefore)
    eq("config.live_resize.root_identity", resizeEnv.StatsProDB, rootRef)
    eq("config.live_resize.account_identity", rootRef.account, accountRef)
    eq("config.live_resize.profiles_identity", rootRef.profiles, profilesRef)
    eq("config.live_resize.characters_identity", rootRef.characters, charactersRef)
end

do
    local heightIsSecret = true
    local firstReadEnv, firstReadAddon, firstReadTest = loadStatsPro("enUS", {
        uiParentWidth = 1024,
        uiParentHeight = 777,
        issecretvalue = function(value)
            return heightIsSecret and value == 777
        end,
    })
    fireEvent("config.live_resize.first_secret.pew", firstReadEnv, "PLAYER_ENTERING_WORLD")
    local rootBefore = deepCopy(firstReadEnv.StatsProDB)
    firstReadAddon:OpenConfigMenu()
    local config = exists("config.live_resize.first_secret.frame", firstReadEnv.StatsProConfigFrame)
    local geometry = firstReadTest.settingsDesignSnapshot().geometry
    eq("config.live_resize.first_secret.safe_width", config:GetWidth(), geometry.windowWidth)
    eq("config.live_resize.first_secret.safe_height", config:GetHeight(), geometry.minHeight)
    check("config.live_resize.first_secret.scroll_reachable",
        config:GetHeight() - geometry.scrollTop - geometry.scrollBottom > 0)

    heightIsSecret = false
    firstReadEnv.UIParent:SetSize(1024, 500)
    fireEvent("config.live_resize.first_secret.recover", firstReadEnv, "DISPLAY_SIZE_CHANGED")
    flushTimers("config.live_resize.first_secret.recover_flush", firstReadEnv, 0, 1)
    eq("config.live_resize.first_secret.recovered_height", config:GetHeight(), 450)
    assertDeepEqual("config.live_resize.first_secret.zero_writes", firstReadEnv.StatsProDB, rootBefore)
end

do
    local longEnv, longAddon = loadStatsPro("ruRU", {
        uiParentWidth = 1024,
        uiParentHeight = 768,
    })
    fireEvent("config.shell.long_profile.pew", longEnv, "PLAYER_ENTERING_WORLD")
    local longName = string.rep("Ж", 40)
    local profileID = longEnv.StatsProDB.account.defaultProfileID
    longEnv.StatsProDB.profiles[profileID].name = longName
    longAddon:OpenConfigMenu()
    longAddon.profileUI.RefreshSafe()
    local button = longEnv.StatsProActiveProfileButton
    eq("config.shell.long_profile.text_preserved", button:GetText(), longName)
    eq("config.shell.long_profile.single_line", button.statsProText.wordWrap, false)
    eq("config.shell.long_profile.max_lines", button.statsProText.maxLines, 1)
    eq("config.shell.long_profile.left_inset", button.statsProText.points[1][2], 8)
    eq("config.shell.long_profile.right_inset", button.statsProText.points[2][2], -8)
    eq("config.shell.long_profile.fixed_width", button:GetWidth(), 286)
    eq("config.shell.long_profile.manage_fixed_width",
        longEnv.StatsProManageProfilesButton:GetWidth(), 100)
end

do
    local corruptDB = {
        dbVersion = test.currentDBVersion(),
        isVisible = false,
        point = "CENTER",
        xOfs = 11,
        account = { forceLocale = "auto", updateInterval = 0.5, defaultProfileID = "missing", nextProfileID = 2 },
        roleTemplates = { TANK = "missing", HEALER = "missing", DAMAGER = "missing" },
        characters = {},
        futureUnknown = { keep = true },
    }
    local before = deepCopy(corruptDB)
    local corruptAccountRef = corruptDB.account
    local corruptRolesRef = corruptDB.roleTemplates
    local corruptCharactersRef = corruptDB.characters
    local corruptUnknownRef = corruptDB.futureUnknown
    local corruptEnv, corruptAddon, corruptTest = loadStatsPro("enUS", { statsProDB = corruptDB })
    fireEvent("db_compat.corrupt_registry.pew", corruptEnv, "PLAYER_ENTERING_WORLD")
    local state = corruptTest.dbCompatibilityState()
    eq("db_compat.corrupt_registry.mode", state.mode, "corrupt")
    eq("db_compat.corrupt_registry.read_only", state.readOnly, true)
    local corruptOps = {
        function() return corruptTest.profileOps.create("Blocked") end,
        function() return corruptTest.profileOps.duplicate("p1", "Blocked") end,
        function() return corruptTest.profileOps.rename("p1", "Blocked") end,
        function() return corruptTest.profileOps.copySettings("p1", "p2", "all") end,
        function() return corruptTest.profileOps.assign("guid", 73, "p1") end,
        function() return corruptTest.profileOps.useProfileForKnownSpecs("guid", "p1") end,
        function() return corruptTest.profileOps.makeKnownSpecsIndependent("guid") end,
        function() return corruptTest.profileOps.setRoleTemplate("TANK", "p1") end,
        function() return corruptTest.profileOps.swap(
            { guid = "a", specID = 73 }, { guid = "b", specID = 72 }) end,
        function() return corruptTest.profileOps.resetCurrent("p1") end,
        function() return corruptTest.profileOps.deleteWithReplacement("p1", "p2") end,
        function() return corruptTest.profileOps.forgetCharacter("guid") end,
    }
    for index, invoke in ipairs(corruptOps) do
        local invoked, result, reason = pcall(invoke)
        check("db_compat.corrupt_registry.ops.no_error." .. index, invoked, result)
        eq("db_compat.corrupt_registry.ops.rejected." .. index, result, false)
        eq("db_compat.corrupt_registry.ops.reason." .. index, reason, "read-only")
    end
    local ok, err = pcall(function() corruptAddon:OpenConfigMenu() end)
    check("db_compat.corrupt_registry.config", ok, err)
    slash("db_compat.corrupt_registry.show", corruptEnv, "show")
    slash("db_compat.corrupt_registry.reset", corruptEnv, "reset")
    corruptEnv.StatsProFrame:ClearAllPoints()
    corruptEnv.StatsProFrame:SetPoint("TOPLEFT", corruptEnv.UIParent, "TOPLEFT", 99, -88)
    fireEvent("db_compat.corrupt_registry.logout", corruptEnv, "PLAYER_LOGOUT")
    eq("db_compat.corrupt_registry.same_root", rawequal(corruptEnv.StatsProDB, corruptDB), true)
    eq("db_compat.corrupt_registry.account_identity", rawequal(corruptDB.account, corruptAccountRef), true)
    eq("db_compat.corrupt_registry.roles_identity", rawequal(corruptDB.roleTemplates, corruptRolesRef), true)
    eq("db_compat.corrupt_registry.characters_identity",
        rawequal(corruptDB.characters, corruptCharactersRef), true)
    eq("db_compat.corrupt_registry.unknown_identity",
        rawequal(corruptDB.futureUnknown, corruptUnknownRef), true)
    assertDeepEqual("db_compat.corrupt_registry.no_writes", corruptEnv.StatsProDB, before)
end

do
    local function makeRegistry()
        return {
            dbVersion = test.currentDBVersion(),
            isVisible = false,
            colors = { crit = { r = 0.1, g = 0.2, b = 0.3 } },
            account = {
                forceLocale = "auto",
                updateInterval = 0.5,
                defaultProfileID = "p1",
                nextProfileID = 3,
            },
            profiles = {
                p1 = {
                    name = "Default",
                    settings = {
                        isVisible = false,
                        colors = { crit = { r = 0.4, g = 0.5, b = 0.6 } },
                    },
                },
                p2 = {
                    name = "Other",
                    settings = {
                        isVisible = true,
                        colors = { crit = { r = 0.7, g = 0.8, b = 0.9 } },
                    },
                },
            },
            roleTemplates = { TANK = "p1", HEALER = "p1", DAMAGER = "p2" },
            characters = {},
        }
    end

    local validCharacterDB = makeRegistry()
    validCharacterDB.characters["Player-1-00000001"] = {
        displayName = "Tester-Realm",
        classID = 10,
        lastSeen = 12345,
        defaultProfileID = "p1",
        specProfiles = { [268] = "p2" },
    }
    local validEnv, _, validTest = loadStatsPro("enUS", { statsProDB = validCharacterDB })
    fireEvent("db_compat.registry_validation.valid_character", validEnv, "PLAYER_ENTERING_WORLD")
    eq("db_compat.registry_validation.valid_character_mode",
        validTest.dbCompatibilityState().mode, "current")

    local cases = {
        {
            name = "shadow_alias",
            mutate = function(db) db.profiles.p1.settings.colors = db.colors end,
        },
        {
            name = "profile_nested_alias",
            mutate = function(db)
                db.profiles.p2.settings.colors = db.profiles.p1.settings.colors
            end,
        },
        {
            name = "profile_settings_alias",
            mutate = function(db) db.profiles.p2.settings = db.profiles.p1.settings end,
        },
        {
            name = "account_settings_alias",
            mutate = function(db) db.profiles.p1.settings = db.account end,
        },
        {
            name = "malformed_unreferenced_profile",
            mutate = function(db) db.profiles.p2.name = 42 end,
        },
        {
            name = "next_id_collision",
            mutate = function(db) db.account.nextProfileID = 2 end,
        },
        {
            name = "next_id_scientific_notation",
            mutate = function(db) db.account.nextProfileID = 100000000000000 end,
        },
        {
            name = "invalid_account_interval",
            mutate = function(db) db.account.updateInterval = 7 end,
        },
        {
            name = "missing_character_assignment",
            mutate = function(db)
                db.characters["Player-1-00000001"] = {
                    defaultProfileID = "p1",
                    specProfiles = { [268] = "missing" },
                }
            end,
        },
    }
    for _, case in ipairs(cases) do
        local db = makeRegistry()
        case.mutate(db)
        local before = deepCopy(db)
        local rootRef = db
        local accountRef = db.account
        local profilesRef = db.profiles
        local rolesRef = db.roleTemplates
        local charactersRef = db.characters
        local p2Ref = db.profiles.p2
        local p1SettingsRef = db.profiles.p1.settings
        local p1ColorsRef = db.profiles.p1.settings.colors
        local p2SettingsRef = db.profiles.p2.settings
        local p2ColorsRef = db.profiles.p2.settings.colors
        local shadowColorsRef = db.colors
        local shadowCritRef = db.colors.crit
        local characterKey, characterRef = next(db.characters)
        local specProfilesRef = characterRef and characterRef.specProfiles or nil
        local envCase, _, caseTest = loadStatsPro("enUS", { statsProDB = db })
        local ok, err = pcall(envCase.__fireEvent, "PLAYER_ENTERING_WORLD")
        check("db_compat.registry_validation." .. case.name .. ".no_error", ok, err)
        eq("db_compat.registry_validation." .. case.name .. ".mode",
            caseTest.dbCompatibilityState().mode, "corrupt")
        slash("db_compat.registry_validation." .. case.name .. ".reset", envCase, "reset")
        fireEvent("db_compat.registry_validation." .. case.name .. ".logout",
            envCase, "PLAYER_LOGOUT")
        eq("db_compat.registry_validation." .. case.name .. ".root_identity",
            rawequal(envCase.StatsProDB, rootRef), true)
        eq("db_compat.registry_validation." .. case.name .. ".account_identity",
            rawequal(db.account, accountRef), true)
        eq("db_compat.registry_validation." .. case.name .. ".profiles_identity",
            rawequal(db.profiles, profilesRef), true)
        eq("db_compat.registry_validation." .. case.name .. ".roles_identity",
            rawequal(db.roleTemplates, rolesRef), true)
        eq("db_compat.registry_validation." .. case.name .. ".characters_identity",
            rawequal(db.characters, charactersRef), true)
        eq("db_compat.registry_validation." .. case.name .. ".other_profile_identity",
            rawequal(db.profiles.p2, p2Ref), true)
        eq("db_compat.registry_validation." .. case.name .. ".settings_identity",
            rawequal(db.profiles.p1.settings, p1SettingsRef), true)
        eq("db_compat.registry_validation." .. case.name .. ".p1_colors_identity",
            rawequal(db.profiles.p1.settings.colors, p1ColorsRef), true)
        eq("db_compat.registry_validation." .. case.name .. ".p2_settings_identity",
            rawequal(db.profiles.p2.settings, p2SettingsRef), true)
        eq("db_compat.registry_validation." .. case.name .. ".p2_colors_identity",
            rawequal(db.profiles.p2.settings.colors, p2ColorsRef), true)
        eq("db_compat.registry_validation." .. case.name .. ".shadow_colors_identity",
            rawequal(db.colors, shadowColorsRef), true)
        eq("db_compat.registry_validation." .. case.name .. ".shadow_crit_identity",
            rawequal(db.colors.crit, shadowCritRef), true)
        if characterRef then
            eq("db_compat.registry_validation." .. case.name .. ".character_identity",
                rawequal(db.characters[characterKey], characterRef), true)
            eq("db_compat.registry_validation." .. case.name .. ".spec_profiles_identity",
                rawequal(characterRef.specProfiles, specProfilesRef), true)
        end
        assertDeepEqual("db_compat.registry_validation." .. case.name .. ".no_writes", db, before)
    end

    local boundaryCases = {
        {
            name = "account",
            mutate = function(db) db.account = deepCopy(db.account) end,
        },
        {
            name = "profiles",
            mutate = function(db) db.profiles = deepCopy(db.profiles) end,
        },
        {
            name = "roles",
            mutate = function(db) db.roleTemplates = deepCopy(db.roleTemplates) end,
        },
        {
            name = "characters",
            mutate = function(db) db.characters = deepCopy(db.characters) end,
        },
        {
            name = "default_profile",
            mutate = function(db) db.profiles.p1 = deepCopy(db.profiles.p1) end,
        },
        {
            name = "active_settings",
            mutate = function(db)
                db.profiles.p1.settings = deepCopy(db.profiles.p1.settings)
            end,
        },
    }
    for _, boundary in ipairs(boundaryCases) do
        local db = makeRegistry()
        local boundaryEnv, _, boundaryTest = loadStatsPro("enUS", { statsProDB = db })
        fireEvent("db_compat.validation_cache." .. boundary.name .. ".pew",
            boundaryEnv, "PLAYER_ENTERING_WORLD")
        local countBefore = boundaryTest.dbValidationCount()
        boundary.mutate(db)
        local state = boundaryTest.dbCompatibilityState()
        eq("db_compat.validation_cache." .. boundary.name .. ".revalidated",
            boundaryTest.dbValidationCount(), countBefore + 1)
        eq("db_compat.validation_cache." .. boundary.name .. ".current",
            state.mode, "current")
        boundaryTest.dbCompatibilityState()
        eq("db_compat.validation_cache." .. boundary.name .. ".recached",
            boundaryTest.dbValidationCount(), countBefore + 1)
    end

    local malformedDB = makeRegistry()
    local malformedEnv, _, malformedTest = loadStatsPro("enUS", { statsProDB = malformedDB })
    fireEvent("db_compat.validation_cache.malformed.pew", malformedEnv, "PLAYER_ENTERING_WORLD")
    local malformedCount = malformedTest.dbValidationCount()
    malformedDB.roleTemplates = { TANK = "missing", HEALER = "p1", DAMAGER = "p2" }
    local malformedBeforeWrite = deepCopy(malformedDB)
    slash("db_compat.validation_cache.malformed.write", malformedEnv, "show")
    eq("db_compat.validation_cache.malformed.revalidated",
        malformedTest.dbValidationCount(), malformedCount + 1)
    eq("db_compat.validation_cache.malformed.corrupt",
        malformedTest.dbCompatibilityState().mode, "corrupt")
    assertDeepEqual("db_compat.validation_cache.malformed.write_blocked",
        malformedDB, malformedBeforeWrite)

    local secretLocale = "secret-locale"
    local secretAccountDB = makeRegistry()
    secretAccountDB.account.forceLocale = secretLocale
    local secretAccountBefore = deepCopy(secretAccountDB)
    local secretAccountRef = secretAccountDB.account
    local secretAccountProfilesRef = secretAccountDB.profiles
    local secretAccountSettingsRef = secretAccountDB.profiles.p1.settings
    local secretAccountColorsRef = secretAccountDB.profiles.p1.settings.colors
    local secretAccountRolesRef = secretAccountDB.roleTemplates
    local secretAccountCharactersRef = secretAccountDB.characters
    local secretAccountEnv, _, secretAccountTest = loadStatsPro("enUS", {
        statsProDB = secretAccountDB,
        issecretvalue = function(value) return value == secretLocale end,
    })
    local ok, err = pcall(secretAccountEnv.__fireEvent, "PLAYER_ENTERING_WORLD")
    check("db_compat.registry_validation.secret_account.no_error", ok, err)
    eq("db_compat.registry_validation.secret_account.mode",
        secretAccountTest.dbCompatibilityState().mode, "corrupt")
    eq("db_compat.registry_validation.secret_account.account_identity",
        rawequal(secretAccountDB.account, secretAccountRef), true)
    eq("db_compat.registry_validation.secret_account.profiles_identity",
        rawequal(secretAccountDB.profiles, secretAccountProfilesRef), true)
    eq("db_compat.registry_validation.secret_account.settings_identity",
        rawequal(secretAccountDB.profiles.p1.settings, secretAccountSettingsRef), true)
    eq("db_compat.registry_validation.secret_account.colors_identity",
        rawequal(secretAccountDB.profiles.p1.settings.colors, secretAccountColorsRef), true)
    eq("db_compat.registry_validation.secret_account.roles_identity",
        rawequal(secretAccountDB.roleTemplates, secretAccountRolesRef), true)
    eq("db_compat.registry_validation.secret_account.characters_identity",
        rawequal(secretAccountDB.characters, secretAccountCharactersRef), true)
    assertDeepEqual("db_compat.registry_validation.secret_account.no_writes",
        secretAccountDB, secretAccountBefore)

    local secretColors = {}
    local secretNestedDB = makeRegistry()
    secretNestedDB.profiles.p1.settings.colors = secretColors
    local secretNestedBefore = deepCopy(secretNestedDB)
    local secretNestedAccountRef = secretNestedDB.account
    local secretNestedProfilesRef = secretNestedDB.profiles
    local secretNestedSettingsRef = secretNestedDB.profiles.p1.settings
    local secretNestedRolesRef = secretNestedDB.roleTemplates
    local secretNestedCharactersRef = secretNestedDB.characters
    local secretNestedEnv, _, secretNestedTest = loadStatsPro("enUS", {
        statsProDB = secretNestedDB,
        issecrettable = function(value) return value == secretColors end,
    })
    ok, err = pcall(secretNestedEnv.__fireEvent, "PLAYER_ENTERING_WORLD")
    check("db_compat.registry_validation.secret_nested.no_error", ok, err)
    eq("db_compat.registry_validation.secret_nested.mode",
        secretNestedTest.dbCompatibilityState().mode, "corrupt")
    eq("db_compat.registry_validation.secret_nested.account_identity",
        rawequal(secretNestedDB.account, secretNestedAccountRef), true)
    eq("db_compat.registry_validation.secret_nested.profiles_identity",
        rawequal(secretNestedDB.profiles, secretNestedProfilesRef), true)
    eq("db_compat.registry_validation.secret_nested.settings_identity",
        rawequal(secretNestedDB.profiles.p1.settings, secretNestedSettingsRef), true)
    eq("db_compat.registry_validation.secret_nested.colors_identity",
        rawequal(secretNestedDB.profiles.p1.settings.colors, secretColors), true)
    eq("db_compat.registry_validation.secret_nested.roles_identity",
        rawequal(secretNestedDB.roleTemplates, secretNestedRolesRef), true)
    eq("db_compat.registry_validation.secret_nested.characters_identity",
        rawequal(secretNestedDB.characters, secretNestedCharactersRef), true)
    assertDeepEqual("db_compat.registry_validation.secret_nested.no_writes",
        secretNestedDB, secretNestedBefore)
end

do
    local readOnlyMessage = "Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."
    local futureDB = {
        dbVersion = test.currentDBVersion() + 5,
        isVisible = true,
        isLocked = false,
        displayMode = "sectioned",
        labelStyle = "full",
        targetSnapshot = "mythicPlus",
        scale = 1,
        updateInterval = 0.5,
        font = "Fonts\\ARIALN.TTF",
        fontSize = 14,
        textAlpha = 100,
        panelBackgroundAlpha = 0,
        textOutlineStyle = "outline",
        forceLocale = "ruRU",
        point = "CENTER",
        relativePoint = "CENTER",
        xOfs = 0,
        yOfs = 0,
        defensive_point = "CENTER",
        defensive_relativePoint = "CENTER",
        defensive_xOfs = 0,
        defensive_yOfs = -100,
        account = {
            forceLocale = "deDE",
            updateInterval = 0.2,
            defaultProfileID = "future-p7",
            nextProfileID = 8,
            futureAccountField = { keep = true },
        },
        profiles = {
            ["future-p7"] = {
                name = "Future",
                settings = {
                    isVisible = false,
                    colors = { crit = { r = 0.9, g = 0.8, b = 0.7 } },
                    futureProfileField = { keep = true },
                },
            },
        },
        roleTemplates = { TANK = "future-p7", HEALER = "future-p7", DAMAGER = "future-p7" },
        characters = { ["future-guid"] = { specProfiles = { [268] = "future-p7" } } },
        futureOnly = { nested = { keep = true }, revision = 42 },
    }
    local before = deepCopy(futureDB)
    local futureAccountRef = futureDB.account
    local futureAccountFieldRef = futureDB.account.futureAccountField
    local futureProfilesRef = futureDB.profiles
    local futureProfileRef = futureDB.profiles["future-p7"]
    local futureSettingsRef = futureProfileRef.settings
    local futureColorsRef = futureSettingsRef.colors
    local futureCritRef = futureColorsRef.crit
    local futureProfileFieldRef = futureSettingsRef.futureProfileField
    local futureRolesRef = futureDB.roleTemplates
    local futureCharactersRef = futureDB.characters
    local futureCharacterRef = futureDB.characters["future-guid"]
    local futureSpecProfilesRef = futureCharacterRef.specProfiles
    local futureOnlyRef = futureDB.futureOnly
    local futureOnlyNestedRef = futureDB.futureOnly.nested
    local futureEnv, futureAddon, futureTest = loadStatsPro("enUS", {
        statsProDB = futureDB,
        swiftStatsDB = { fontSize = 17 },
    })
    local function assertRootUnchanged(name)
        eq(name .. ".same_root", rawequal(futureEnv.StatsProDB, futureDB), true)
        eq(name .. ".account_identity", rawequal(futureDB.account, futureAccountRef), true)
        eq(name .. ".account_nested_identity",
            rawequal(futureDB.account.futureAccountField, futureAccountFieldRef), true)
        eq(name .. ".profiles_identity", rawequal(futureDB.profiles, futureProfilesRef), true)
        eq(name .. ".profile_identity",
            rawequal(futureDB.profiles["future-p7"], futureProfileRef), true)
        eq(name .. ".settings_identity", rawequal(futureProfileRef.settings, futureSettingsRef), true)
        eq(name .. ".colors_identity", rawequal(futureSettingsRef.colors, futureColorsRef), true)
        eq(name .. ".crit_identity", rawequal(futureColorsRef.crit, futureCritRef), true)
        eq(name .. ".profile_nested_identity",
            rawequal(futureSettingsRef.futureProfileField, futureProfileFieldRef), true)
        eq(name .. ".roles_identity", rawequal(futureDB.roleTemplates, futureRolesRef), true)
        eq(name .. ".characters_identity", rawequal(futureDB.characters, futureCharactersRef), true)
        eq(name .. ".character_identity",
            rawequal(futureDB.characters["future-guid"], futureCharacterRef), true)
        eq(name .. ".spec_profiles_identity",
            rawequal(futureCharacterRef.specProfiles, futureSpecProfilesRef), true)
        eq(name .. ".future_only_identity", rawequal(futureDB.futureOnly, futureOnlyRef), true)
        eq(name .. ".future_only_nested_identity",
            rawequal(futureDB.futureOnly.nested, futureOnlyNestedRef), true)
        assertDeepEqual(name .. ".deep", futureEnv.StatsProDB, before)
    end
    fireEvent("db_compat.future_read_only.pew", futureEnv, "PLAYER_ENTERING_WORLD")
    assertRootUnchanged("db_compat.future_read_only.pew_unchanged")
    local compatibility = futureTest.dbCompatibilityState()
    eq("db_compat.future_read_only.state", compatibility.readOnly, true)
    eq("db_compat.future_read_only.version", compatibility.version, before.dbVersion)

    local ok, err = pcall(function() futureAddon:OpenConfigMenu() end)
    check("db_compat.future_read_only.config_open", ok, err)
    local disabledMutationControls = 0
    for index, control in ipairs(futureTest.settingsControlState()) do
        if control.mutatesSettings then
            disabledMutationControls = disabledMutationControls + 1
            eq("db_compat.future_read_only.control_disabled." .. index,
                control.enabled, false)
            eq("db_compat.future_read_only.control_state." .. index,
                control.state, "disabled")
        end
    end
    check("db_compat.future_read_only.mutation_controls_registered",
        disabledMutationControls >= 60, "mutating controls were not centrally disabled")
    userInteract("db_compat.future_read_only.dropdown_tooltip",
        futureEnv.StatsProDisplayModeDropdownButton, "OnEnter")
    eq("db_compat.future_read_only.dropdown_tooltip_text",
        futureEnv.GameTooltip.lines[1].left,
        "Compatibility mode - profiles are read-only.")
    userInteract("db_compat.future_read_only.dropdown_tooltip_leave",
        futureEnv.StatsProDisplayModeDropdownButton, "OnLeave")
    assertRootUnchanged("db_compat.future_read_only.config_open_unchanged")
    ok, err = pcall(function() futureAddon:OpenConfigMenu() end)
    check("db_compat.future_read_only.config_close", ok, err)
    assertRootUnchanged("db_compat.future_read_only.config_close_unchanged")
    futureAddon:OpenConfigMenu()

    clickCheckbox("db_compat.future_read_only.checkbox", futureEnv.StatsProVisibleCheck, false)
    changeSlider("db_compat.future_read_only.slider", futureEnv.StatsProScaleSlider, 1.7)
    selectDropdownValue("db_compat.future_read_only.display_mode", futureEnv.StatsProDisplayModeDropdown, "split")
    selectDropdownValue("db_compat.future_read_only.target_snapshot", futureEnv.StatsProTargetSnapshotDropdown, "raid")
    selectDropdownValue("db_compat.future_read_only.label_style", futureEnv.StatsProLabelStyleDropdown, "hidden")
    selectDropdownValue("db_compat.future_read_only.outline", futureEnv.StatsProTextOutlineDropdown, "none")
    selectDropdownValue("db_compat.future_read_only.language", futureEnv.StatsProLanguageDropdown, "deDE")
    assertRootUnchanged("db_compat.future_read_only.controls_unchanged")

    runScript("db_compat.future_read_only.font_picker_open", futureEnv.StatsProFontDropdownButton,
        "OnClick", futureEnv.StatsProFontDropdownButton)
    local fontButton = findFrame("db_compat.future_read_only.font_button", futureEnv, function(frame)
        return frame.fontPath and frame.fontPath ~= before.font and type(frame.scripts.OnClick) == "function"
    end)
    callScript("db_compat.future_read_only.font_commit", fontButton, "OnClick")
    futureEnv.StatsProFontPicker:Hide()
    assertRootUnchanged("db_compat.future_read_only.font_modal_unchanged")

    local critSwatch = findFrame("db_compat.future_read_only.crit_swatch", futureEnv, function(frame)
        return frame.statsProColorKey == "crit"
    end)
    callScript("db_compat.future_read_only.color_open", critSwatch, "OnClick")
    eq("db_compat.future_read_only.color_modal_blocked", futureEnv.ColorPickerFrame:IsShown(), false)
    assertRootUnchanged("db_compat.future_read_only.color_open_unchanged")

    slash("db_compat.future_read_only.slash_show", futureEnv, "show")
    slash("db_compat.future_read_only.slash_hide", futureEnv, "hide")
    slash("db_compat.future_read_only.slash_toggle", futureEnv, "toggle")
    slash("db_compat.future_read_only.slash_reset", futureEnv, "reset")
    slash("db_compat.future_read_only.slash_reset_all", futureEnv, "reset all")
    slash("db_compat.future_read_only.slash_wipe", futureEnv, "wipe")
    slash("db_compat.future_read_only.slash_import", futureEnv, "import")
    eq("db_compat.future_read_only.import_no_popup", futureEnv.__staticPopupShows, 0)
    assertRootUnchanged("db_compat.future_read_only.slash_unchanged")

    for name, invoke in pairs({
        import = function() return futureTest.profileOps.importAndAssign({}) end,
        reset = function() return futureTest.profileOps.resetCurrent("future-p7") end,
        wipe = function() return futureTest.profileOps.fullWipe() end,
    }) do
        local invoked, result, reason = pcall(invoke)
        check("db_compat.future_read_only.direct." .. name .. ".call", invoked, result)
        eq("db_compat.future_read_only.direct." .. name .. ".rejected", result, false)
        eq("db_compat.future_read_only.direct." .. name .. ".reason", reason, "read-only")
        assertRootUnchanged("db_compat.future_read_only.direct." .. name .. ".unchanged")
    end

    futureEnv.StatsProFrame:ClearAllPoints()
    futureEnv.StatsProFrame:SetPoint("TOPLEFT", futureEnv.UIParent, "TOPLEFT", 41, -42)
    futureEnv.StatsProDefensiveFrame:ClearAllPoints()
    futureEnv.StatsProDefensiveFrame:SetPoint("BOTTOMRIGHT", futureEnv.UIParent, "BOTTOMRIGHT", -17, 23)
    fireEvent("db_compat.future_read_only.logout", futureEnv, "PLAYER_LOGOUT")
    assertRootUnchanged("db_compat.future_read_only.logout_unchanged")
    eq("db_compat.future_read_only.safe_default_guidance",
        printContains(futureEnv, readOnlyMessage), true)

    local labelsByLocale = futureTest.registrySnapshot().labelsByLocale
    for locale, labels in pairs(labelsByLocale) do
        check("db_compat.future_read_only.localized_key." .. locale,
            type(labels[readOnlyMessage]) == "string" and labels[readOnlyMessage] ~= "",
            "missing localized read-only guidance")
    end
end

do
    local secretVersion = setmetatable({}, {
        __tostring = function() error("secret dbVersion inspected", 2) end,
    })
    local secretDB = {
        dbVersion = secretVersion,
        isVisible = true,
        futureOnly = { keep = true },
    }
    local before = deepCopy(secretDB)
    local secretFutureOnlyRef = secretDB.futureOnly
    local secretEnv = loadStatsPro("enUS", {
        statsProDB = secretDB,
        issecretvalue = function(value) return value == secretVersion end,
    })
    fireEvent("db_compat.secret_version.pew", secretEnv, "PLAYER_ENTERING_WORLD")
    clearPrints(secretEnv)
    slash("db_compat.secret_version.debug", secretEnv, "debug")
    eq("db_compat.secret_version.debug_redacted",
        printContains(secretEnv, "dbVer <unavailable>"), true)
    eq("db_compat.secret_version.debug_read_only",
        printContains(secretEnv, "dbMode=read-only"), true)
    eq("db_compat.secret_version.same_root", rawequal(secretEnv.StatsProDB, secretDB), true)
    eq("db_compat.secret_version.future_only_identity",
        rawequal(secretEnv.StatsProDB.futureOnly, secretFutureOnlyRef), true)
    assertDeepEqual("db_compat.secret_version.unchanged", secretEnv.StatsProDB, before)
end

do
    local transitionDB = {
        dbVersion = test.currentDBVersion() - 1,
        colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } },
    }
    local transitionEnv = loadStatsPro("enUS", { statsProDB = transitionDB })
    fireEvent("db_compat.modal_transition.pew", transitionEnv, "PLAYER_ENTERING_WORLD")
    slash("db_compat.modal_transition.config", transitionEnv, "")
    local critSwatch = findFrame("db_compat.modal_transition.crit_swatch", transitionEnv, function(frame)
        return frame.statsProColorKey == "crit"
    end)
    callScript("db_compat.modal_transition.open", critSwatch, "OnClick")
    transitionEnv.__setColorPickerRGB(0.6, 0.7, 0.8)
    local ok, err = pcall(transitionEnv.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("db_compat.modal_transition.preview", ok, err)
    transitionDB.dbVersion = test.currentDBVersion() + 1
    local beforeCancel = deepCopy(transitionDB)
    transitionEnv.__cancelColorPicker()
    assertDeepEqual("db_compat.modal_transition.cancel_unchanged", transitionDB, beforeCancel)
end

do
    local colorEnv = loadStatsPro("enUS", {
        statsProDB = { colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } } },
    })
    fireEvent("config.color_picker.config_hide.fire", colorEnv, "PLAYER_ENTERING_WORLD")
    slash("config.color_picker.config_hide.open_config", colorEnv, "")
    local critSwatch = findFrame("config.color_picker.config_hide.crit_swatch", colorEnv, function(frame)
        return frame.statsProColorKey == "crit"
    end)
    callScript("config.color_picker.config_hide.open_picker", critSwatch, "OnClick")
    colorEnv.__setColorPickerRGB(0.6, 0.7, 0.8)
    local ok, err = pcall(colorEnv.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.config_hide.preview", ok, err)
    colorEnv.StatsProConfigFrame:Hide()
    eq("config.color_picker.config_hide_closes_owned_picker.hidden", colorEnv.ColorPickerFrame:IsShown(), false)
    assertColor("config.color_picker.config_hide_cancels_preview.crit", activeSettings(colorEnv).colors.crit, 0.2, 0.3, 0.4)
end

do
    local rawHideEnv = loadStatsPro("enUS", {
        statsProDB = { colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } } },
    })
    fireEvent("config.color_picker.raw_hide.fire", rawHideEnv, "PLAYER_ENTERING_WORLD")
    slash("config.color_picker.raw_hide.open_config", rawHideEnv, "")
    local critSwatch = findFrame("config.color_picker.raw_hide.crit_swatch", rawHideEnv, function(frame)
        return frame.statsProColorKey == "crit"
    end)
    callScript("config.color_picker.raw_hide.open_picker", critSwatch, "OnClick")
    rawHideEnv.__setColorPickerRGB(0.6, 0.7, 0.8)
    local options = rawHideEnv.ColorPickerFrame.colorPickerOptions
    local ok, err = pcall(options.swatchFunc)
    check("config.color_picker.raw_hide.preview", ok, err)
    rawHideEnv.ColorPickerFrame:Hide()
    assertColor("config.color_picker.raw_hide_restores_snapshot.crit",
        activeSettings(rawHideEnv).colors.crit, 0.2, 0.3, 0.4)
    ok, err = pcall(options.swatchFunc)
    check("config.color_picker.raw_hide.stale_callback_call", ok, err)
    assertColor("config.color_picker.raw_hide.stale_callback_noop.crit",
        activeSettings(rawHideEnv).colors.crit, 0.2, 0.3, 0.4)

    activeSettings(rawHideEnv).colors.crit = nil
    callScript("config.color_picker.raw_hide_default.open_picker", critSwatch, "OnClick")
    rawHideEnv.__setColorPickerRGB(0.7, 0.8, 0.9)
    ok, err = pcall(rawHideEnv.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.raw_hide_default.preview", ok, err)
    rawHideEnv.ColorPickerFrame:Hide()
    eq("config.color_picker.raw_hide_default_restores_nil", activeSettings(rawHideEnv).colors.crit, nil)
end

do
    local fallbackEnv = loadStatsPro("enUS", {
        statsProDB = { colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } } },
    })
    fireEvent("config.color_picker.accept_boundary_fallback.fire", fallbackEnv, "PLAYER_ENTERING_WORLD")
    slash("config.color_picker.accept_boundary_fallback.open_config", fallbackEnv, "")
    local critSwatch = findFrame("config.color_picker.accept_boundary_fallback.crit_swatch", fallbackEnv, function(frame)
        return frame.statsProColorKey == "crit"
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
        activeSettings(fallbackEnv).colors.crit, 0.6, 0.7, 0.8)
end

do
    local takeoverEnv = loadStatsPro("enUS", {
        statsProDB = { colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } } },
    })
    fireEvent("config.color_picker.takeover.fire", takeoverEnv, "PLAYER_ENTERING_WORLD")
    slash("config.color_picker.takeover.open_config", takeoverEnv, "")
    local critSwatch = findFrame("config.color_picker.takeover.crit_swatch", takeoverEnv, function(frame)
        return frame.statsProColorKey == "crit"
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
        activeSettings(takeoverEnv).colors.crit, 0.2, 0.3, 0.4)
    eq("config.color_picker.takeover_immediate.foreign_stays_open",
        takeoverEnv.ColorPickerFrame:IsShown(), true)
    takeoverEnv.__acceptColorPicker()
    eq("config.color_picker.takeover.foreign_accept_called", foreignAccepted, 1)
    eq("config.color_picker.takeover.foreign_not_canceled", foreignCanceled, false)
    assertColor("config.color_picker.takeover_foreign_hide_restores_statspro.crit",
        activeSettings(takeoverEnv).colors.crit, 0.2, 0.3, 0.4)

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
        activeSettings(takeoverEnv).colors.crit, 0.2, 0.3, 0.4)
end

do
    local colorEnv = loadStatsPro("enUS")
    fireEvent("config.color_picker.switch_swatch.fire", colorEnv, "PLAYER_ENTERING_WORLD")
    slash("config.color_picker.switch_swatch.open_config", colorEnv, "")
    local critSwatch = findFrame("config.color_picker.switch_swatch.crit_swatch", colorEnv, function(frame)
        return frame.statsProColorKey == "crit"
    end)
    local hasteSwatch = findFrame("config.color_picker.switch_swatch.haste_swatch", colorEnv, function(frame)
        return frame.statsProColorKey == "haste"
    end)
    activeSettings(colorEnv).colors.crit = nil
    callScript("config.color_picker.switch_swatch.open_crit", critSwatch, "OnClick")
    colorEnv.__setColorPickerRGB(0.2, 0.3, 0.4)
    local oldCritOptions = colorEnv.ColorPickerFrame.colorPickerOptions
    local ok, err = pcall(oldCritOptions.swatchFunc)
    check("config.color_picker.switch_swatch.preview_crit", ok, err)
    callScript("config.color_picker.switch_swatch.open_haste", hasteSwatch, "OnClick")
    eq("config.color_picker.switch_swatch_cancels_previous_preview.crit", activeSettings(colorEnv).colors.crit, nil)
    eq("config.color_picker.switch_swatch_cancels_previous_preview.shown", colorEnv.ColorPickerFrame:IsShown(), true)
    colorEnv.__setColorPickerRGB(0.6, 0.7, 0.8)
    ok, err = pcall(colorEnv.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.switch_swatch.preview_haste", ok, err)
    ok, err = pcall(oldCritOptions.swatchFunc)
    check("config.color_picker.switch_swatch.stale_swatch_call", ok, err)
    ok, err = pcall(oldCritOptions.cancelFunc, oldCritOptions)
    check("config.color_picker.switch_swatch.stale_cancel_call", ok, err)
    eq("config.color_picker.switch_swatch.stale_callbacks_keep_crit_nil", activeSettings(colorEnv).colors.crit, nil)
    assertColor("config.color_picker.switch_swatch.stale_callbacks_keep_haste_preview",
        activeSettings(colorEnv).colors.haste, 0.6, 0.7, 0.8)
end

do
    local foreignEnv = loadStatsPro("enUS")
    fireEvent("config.color_picker.foreign.fire", foreignEnv, "PLAYER_ENTERING_WORLD")
    slash("config.color_picker.foreign.open_config", foreignEnv, "")
    local critSwatch = findFrame("config.color_picker.foreign.crit_swatch", foreignEnv, function(frame)
        return frame.statsProColorKey == "crit"
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
        return frame.statsProColorKey == "crit"
    end)
    callScript("config.color_picker.stale.open_crit", critSwatch, "OnClick")
    local oldOptions = staleEnv.ColorPickerFrame.colorPickerOptions
    slash("config.color_picker.stale.reset", staleEnv, "reset")
    staleEnv.__setColorPickerRGB(0.2, 0.3, 0.4)
    local ok, err = pcall(oldOptions.swatchFunc)
    check("config.color_picker.stale_callbacks_noop_after_reset.call", ok, err)
    assertColor("config.color_picker.stale_callbacks_noop_after_reset.crit", activeSettings(staleEnv).colors.crit, 1, 0, 0)
end

do
    local function openCritPicker(prefix, env)
        slash(prefix .. ".open_config", env, "")
        local swatch = findFrame(prefix .. ".crit_swatch", env, function(frame)
            return frame.statsProColorKey == "crit"
        end)
        callScript(prefix .. ".open_picker", swatch, "OnClick")
        return swatch
    end

    local explicitEnv = loadStatsPro("enUS", {
        statsProDB = { colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } } },
    })
    fireEvent("config.color_picker.logout_explicit.fire", explicitEnv, "PLAYER_ENTERING_WORLD")
    openCritPicker("config.color_picker.logout_explicit", explicitEnv)
    explicitEnv.__setColorPickerRGB(0.6, 0.7, 0.8)
    local ok, err = pcall(explicitEnv.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.logout_explicit.preview", ok, err)
    explicitEnv.StatsProFrame:ClearAllPoints()
    explicitEnv.StatsProFrame:SetPoint("TOPLEFT", explicitEnv.UIParent, "TOPLEFT", 111, -222)
    explicitEnv.StatsProDefensiveFrame:ClearAllPoints()
    explicitEnv.StatsProDefensiveFrame:SetPoint("BOTTOMRIGHT", explicitEnv.UIParent, "BOTTOMRIGHT", -333, 444)
    fireEvent("config.color_picker.logout_explicit.logout", explicitEnv, "PLAYER_LOGOUT")
    local explicitSettings = activeSettings(explicitEnv)
    assertColor("config.color_picker.logout_explicit.restores_snapshot",
        explicitSettings.colors.crit, 0.2, 0.3, 0.4)
    eq("config.color_picker.logout_explicit.closes_owned", explicitEnv.ColorPickerFrame:IsShown(), false)
    eq("config.color_picker.logout_explicit.main_point", explicitSettings.point, "TOPLEFT")
    eq("config.color_picker.logout_explicit.main_relative", explicitSettings.relativePoint, "TOPLEFT")
    eq("config.color_picker.logout_explicit.main_x", explicitSettings.xOfs, 111)
    eq("config.color_picker.logout_explicit.main_y", explicitSettings.yOfs, -222)
    eq("config.color_picker.logout_explicit.side_point", explicitSettings.defensive_point, "BOTTOMRIGHT")
    eq("config.color_picker.logout_explicit.side_relative", explicitSettings.defensive_relativePoint, "BOTTOMRIGHT")
    eq("config.color_picker.logout_explicit.side_x", explicitSettings.defensive_xOfs, -333)
    eq("config.color_picker.logout_explicit.side_y", explicitSettings.defensive_yOfs, 444)

    local defaultEnv = loadStatsPro("enUS")
    fireEvent("config.color_picker.logout_default.fire", defaultEnv, "PLAYER_ENTERING_WORLD")
    activeSettings(defaultEnv).colors.crit = nil
    openCritPicker("config.color_picker.logout_default", defaultEnv)
    defaultEnv.__setColorPickerRGB(0.7, 0.8, 0.9)
    ok, err = pcall(defaultEnv.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.logout_default.preview", ok, err)
    fireEvent("config.color_picker.logout_default.logout", defaultEnv, "PLAYER_LOGOUT")
    eq("config.color_picker.logout_default.restores_nil", activeSettings(defaultEnv).colors.crit, nil)
    eq("config.color_picker.logout_default.closes_owned", defaultEnv.ColorPickerFrame:IsShown(), false)

    local acceptedEnv = loadStatsPro("enUS", {
        statsProDB = { colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } } },
    })
    fireEvent("config.color_picker.logout_accepted.fire", acceptedEnv, "PLAYER_ENTERING_WORLD")
    openCritPicker("config.color_picker.logout_accepted", acceptedEnv)
    acceptedEnv.__setColorPickerRGB(0.6, 0.7, 0.8)
    ok, err = pcall(acceptedEnv.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.logout_accepted.preview", ok, err)
    acceptedEnv.__acceptColorPicker()
    fireEvent("config.color_picker.logout_accepted.logout", acceptedEnv, "PLAYER_LOGOUT")
    assertColor("config.color_picker.logout_accepted.preserves_commit",
        activeSettings(acceptedEnv).colors.crit, 0.6, 0.7, 0.8)
    eq("config.color_picker.logout_accepted.stays_closed", acceptedEnv.ColorPickerFrame:IsShown(), false)

    local noHideHookEnv = loadStatsPro("enUS", {
        statsProDB = { colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } } },
    })
    noHideHookEnv.ColorPickerFrame.HookScript = nil
    fireEvent("config.color_picker.logout_accepted_no_hide_hook.fire",
        noHideHookEnv, "PLAYER_ENTERING_WORLD")
    openCritPicker("config.color_picker.logout_accepted_no_hide_hook", noHideHookEnv)
    noHideHookEnv.__setColorPickerRGB(0.6, 0.7, 0.8)
    ok, err = pcall(noHideHookEnv.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.logout_accepted_no_hide_hook.preview", ok, err)
    noHideHookEnv.__acceptColorPicker()
    eq("config.color_picker.logout_accepted_no_hide_hook.hidden",
        noHideHookEnv.ColorPickerFrame:IsShown(), false)
    fireEvent("config.color_picker.logout_accepted_no_hide_hook.logout",
        noHideHookEnv, "PLAYER_LOGOUT")
    assertColor("config.color_picker.logout_accepted_no_hide_hook.preserves_commit",
        activeSettings(noHideHookEnv).colors.crit, 0.6, 0.7, 0.8)

    local foreignEnv = loadStatsPro("enUS")
    fireEvent("config.color_picker.logout_foreign.fire", foreignEnv, "PLAYER_ENTERING_WORLD")
    local foreignCanceled = false
    local foreignToken = {}
    foreignEnv.ColorPickerFrame:SetupColorPickerAndShow({
        r = 0.1, g = 0.2, b = 0.3,
        extraInfo = foreignToken,
        cancelFunc = function() foreignCanceled = true end,
    })
    foreignEnv.StatsProFrame:ClearAllPoints()
    foreignEnv.StatsProFrame:SetPoint("CENTER", foreignEnv.UIParent, "CENTER", 555, -666)
    fireEvent("config.color_picker.logout_foreign.logout", foreignEnv, "PLAYER_LOGOUT")
    eq("config.color_picker.logout_foreign.owner", foreignEnv.ColorPickerFrame:GetExtraInfo(), foreignToken)
    eq("config.color_picker.logout_foreign.stays_open", foreignEnv.ColorPickerFrame:IsShown(), true)
    eq("config.color_picker.logout_foreign.not_canceled", foreignCanceled, false)
    eq("config.color_picker.logout_foreign.position_saved", activeSettings(foreignEnv).xOfs, 555)

    local takeoverEnv = loadStatsPro("enUS", {
        statsProDB = { colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } } },
    })
    fireEvent("config.color_picker.logout_takeover.fire", takeoverEnv, "PLAYER_ENTERING_WORLD")
    openCritPicker("config.color_picker.logout_takeover", takeoverEnv)
    takeoverEnv.__setColorPickerRGB(0.6, 0.7, 0.8)
    ok, err = pcall(takeoverEnv.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.logout_takeover.preview", ok, err)
    local takeoverCanceled = false
    takeoverEnv.ColorPickerFrame.swatchFunc = function() end
    takeoverEnv.ColorPickerFrame.cancelFunc = function() takeoverCanceled = true end
    fireEvent("config.color_picker.logout_takeover.logout", takeoverEnv, "PLAYER_LOGOUT")
    assertColor("config.color_picker.logout_takeover.restores_snapshot",
        activeSettings(takeoverEnv).colors.crit, 0.2, 0.3, 0.4)
    eq("config.color_picker.logout_takeover.foreign_stays_open",
        takeoverEnv.ColorPickerFrame:IsShown(), true)
    eq("config.color_picker.logout_takeover.foreign_not_canceled", takeoverCanceled, false)

    local pendingEnv, _, pendingTest = loadStatsPro("enUS", {
        statsProDB = { colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } } },
    })
    fireEvent("config.color_picker.logout_pending.fire", pendingEnv, "PLAYER_ENTERING_WORLD")
    openCritPicker("config.color_picker.logout_pending", pendingEnv)
    pendingEnv.__setColorPickerRGB(0.6, 0.7, 0.8)
    ok, err = pcall(pendingEnv.ColorPickerFrame.colorPickerOptions.swatchFunc)
    check("config.color_picker.logout_pending.preview", ok, err)
    pendingTest.setSettingsContextBlockedForSmoke(true)
    fireEvent("config.color_picker.logout_pending.logout", pendingEnv, "PLAYER_LOGOUT")
    assertColor("config.color_picker.logout_pending.restores_same_settings",
        activeSettings(pendingEnv).colors.crit, 0.2, 0.3, 0.4)
    eq("config.color_picker.logout_pending.closes_owned", pendingEnv.ColorPickerFrame:IsShown(), false)
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

do
    -- Character/spec profile activation is exercised against one shared SavedVariables
    -- root so switches have the same identity and aliasing hazards as real relogs.
    local seedEnv = loadStatsPro("enUS")
    fireEvent("profiles.context.seed", seedEnv, "PLAYER_ENTERING_WORLD")
    local root = seedEnv.StatsProDB
    root.profiles.p2 = { name = "Tank template", settings = deepCopy(root.profiles.p1.settings) }
    root.profiles.p2.settings.showDefensive = true
    root.profiles.p2.settings.isVisible = true
    root.profiles.p3 = { name = "Damage template", settings = deepCopy(root.profiles.p1.settings) }
    root.profiles.p3.settings.showDefensive = false
    root.profiles.p3.settings.isVisible = true
    root.account.nextProfileID = 4
    root.roleTemplates = { TANK = "p2", HEALER = "p1", DAMAGER = "p3" }

    local identity = {
        guid = "Player-1-AAA",
        name = "Alpha",
        specIndex = 1,
        specID = 73,
        specName = "Protection",
        role = "TANK",
        combat = false,
    }
    local env, addonContext, contextTest = loadStatsPro("enUS", {
        statsProDB = root,
        unitGUID = function() return identity.guid end,
        unitFullName = function() return identity.name, "Realm" end,
        getSpecialization = function() return identity.specIndex end,
        getSpecializationInfo = function()
            return identity.specID, identity.specName, nil, nil, identity.role, 1
        end,
        inCombatLockdown = function() return identity.combat end,
    })
    fireEvent("profiles.context.first_visit", env, "PLAYER_ENTERING_WORLD")
    local state = contextTest.profileState()
    local runtime = contextTest.profileRuntimeState()
    local alpha = root.characters[identity.guid]
    eq("profiles.context.first_visit.active_guid", runtime.activeGUID, identity.guid)
    eq("profiles.context.first_visit.active_spec", runtime.activeSpecID, 73)
    eq("profiles.context.first_visit.default_profile", alpha.defaultProfileID, "p4")
    eq("profiles.context.first_visit.spec_profile", alpha.specProfiles[73], "p5")
    eq("profiles.context.first_visit.active_profile", state.profileID, "p5")
    eq("profiles.context.first_visit.role_template_copy", state.settings.showDefensive, true)
    eq("profiles.context.first_visit.next_id", root.account.nextProfileID, 6)
    eq("profiles.context.first_visit.default_independent",
        rawequal(root.profiles.p4.settings, root.profiles.p1.settings), false)
    eq("profiles.context.first_visit.spec_independent",
        rawequal(root.profiles.p5.settings, root.profiles.p2.settings), false)
    eq("profiles.context.first_visit.nested_independent",
        rawequal(root.profiles.p5.settings.colors, root.profiles.p2.settings.colors), false)

    local beforeNoop = deepCopy(root)
    local accountRef, profilesRef, charactersRef = root.account, root.profiles, root.characters
    local noOpRuntime = contextTest.profileRuntimeState()
    fireEvent("profiles.context.same_event", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    eq("profiles.context.same_event.scheduled", contextTest.profileRuntimeState().scheduled, true)
    env.__flushTimers(0)
    local afterNoop = contextTest.profileRuntimeState()
    assertDeepEqual("profiles.context.same_event.no_writes", root, beforeNoop)
    eq("profiles.context.same_event.account_identity", rawequal(root.account, accountRef), true)
    eq("profiles.context.same_event.profiles_identity", rawequal(root.profiles, profilesRef), true)
    eq("profiles.context.same_event.characters_identity", rawequal(root.characters, charactersRef), true)
    eq("profiles.context.same_event.no_activation", afterNoop.activationCount, noOpRuntime.activationCount)
    eq("profiles.context.same_event.no_apply", afterNoop.applyCount, noOpRuntime.applyCount)
    eq("profiles.context.same_event.no_render", afterNoop.updateCount, noOpRuntime.updateCount)

    local timersBeforeForeign = #env.__timers
    fireEvent("profiles.context.foreign_spec_event", env, "PLAYER_SPECIALIZATION_CHANGED", "party1")
    eq("profiles.context.foreign_spec_event.no_timer", #env.__timers, timersBeforeForeign)

    env.StatsProFrame:ClearAllPoints()
    env.StatsProFrame:SetPoint("TOPLEFT", env.UIParent, "TOPLEFT", 111, -112)
    identity.specID, identity.specName, identity.role = 71, "Arms", "DAMAGER"
    fireEvent("profiles.context.tank_to_dps", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    slash("profiles.context.scheduled_write_block", env, "hide")
    eq("profiles.context.scheduled_write_block.keeps_tank", root.profiles.p5.settings.isVisible, true)
    env.__flushTimers(0)
    state = contextTest.profileState()
    eq("profiles.context.dps_profile_created", root.characters["Player-1-AAA"].specProfiles[71], "p6")
    eq("profiles.context.dps_active", state.profileID, "p6")
    eq("profiles.context.dps_template_copy", state.settings.showDefensive, false)
    eq("profiles.context.tank_position_saved", root.profiles.p5.settings.xOfs, 111)
    env.StatsProFrame:ClearAllPoints()
    env.StatsProFrame:SetPoint("BOTTOMRIGHT", env.UIParent, "BOTTOMRIGHT", -221, 222)
    identity.specID, identity.specName, identity.role = 73, "Protection", "TANK"
    fireEvent("profiles.context.dps_to_tank", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)
    eq("profiles.context.tank_restored", contextTest.profileState().profileID, "p5")
    eq("profiles.context.tank_position_restored", env.StatsProFrame.points[1][4], 111)
    eq("profiles.context.dps_position_saved", root.profiles.p6.settings.xOfs, -221)

    identity.guid, identity.name = "Player-1-BBB", "Bravo"
    fireEvent("profiles.context.character_b", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)
    local bravo = root.characters[identity.guid]
    local bravoTankID = bravo.specProfiles[73]
    check("profiles.context.character_b.separate_profile",
        bravoTankID ~= root.characters["Player-1-AAA"].specProfiles[73])
    contextTest.profileState().settings.showDefensive = false
    identity.guid, identity.name = "Player-1-AAA", "Alpha"
    fireEvent("profiles.context.character_a_restore", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)
    eq("profiles.context.character_a_isolated", contextTest.profileState().settings.showDefensive, true)
    identity.guid, identity.name = "Player-1-BBB", "Bravo"
    fireEvent("profiles.context.character_b_restore", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)
    eq("profiles.context.character_b_isolated", contextTest.profileState().settings.showDefensive, false)

    local noSpecBefore = deepCopy(root)
    local activeBeforeNoSpec = contextTest.profileState().profileID
    identity.specIndex = nil
    fireEvent("profiles.context.no_spec", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)
    eq("profiles.context.no_spec.keeps_active", contextTest.profileState().profileID, activeBeforeNoSpec)
    eq("profiles.context.no_spec.pending", contextTest.profileRuntimeState().pendingResolution, true)
    assertDeepEqual("profiles.context.no_spec.no_writes", root, noSpecBefore)
    identity.specIndex = 1

    identity.combat = true
    identity.specID, identity.specName, identity.role = 71, "Arms", "DAMAGER"
    fireEvent("profiles.context.combat_defer", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)
    eq("profiles.context.combat_defer.keeps_active", contextTest.profileState().profileID, bravoTankID)
    eq("profiles.context.combat_defer.pending", contextTest.profileRuntimeState().pendingResolution, true)
    local outgoingVisible = contextTest.profileState().settings.isVisible
    slash("profiles.context.combat_defer.blocks_write", env, "hide")
    eq("profiles.context.combat_defer.write_unchanged",
        contextTest.profileState().settings.isVisible, outgoingVisible)
    env.StatsProFrame:ClearAllPoints()
    env.StatsProFrame:SetPoint("TOP", env.UIParent, "TOP", 333, -334)
    fireEvent("profiles.context.pending_logout", env, "PLAYER_LOGOUT")
    eq("profiles.context.pending_logout.active_scope", root.profiles[bravoTankID].settings.xOfs, 333)
    identity.combat = false
    fireEvent("profiles.context.combat_resume", env, "PLAYER_REGEN_ENABLED")
    eq("profiles.context.combat_resume.latest_spec", contextTest.profileRuntimeState().activeSpecID, 71)
    eq("profiles.context.combat_resume.one_apply", contextTest.profileRuntimeState().pendingResolution, false)

    addonContext:OpenConfigMenu()
    identity.specID, identity.specName, identity.role = 73, "Protection", "TANK"
    fireEvent("profiles.context.open_settings_switch", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)
    eq("profiles.context.open_settings.control_refresh",
        env.StatsProDefensiveCheck:GetChecked(), root.profiles[bravoTankID].settings.showDefensive)
    local validationBeforeRefreshWrite = contextTest.dbValidationCount()
    callScript("profiles.context.open_settings.write", env.StatsProDefensiveCheck, "OnClick")
    eq("profiles.context.open_settings.write_targets_active",
        root.profiles[bravoTankID].settings.showDefensive, env.StatsProDefensiveCheck:GetChecked())
    eq("profiles.context.open_settings.cached_validation",
        contextTest.dbValidationCount(), validationBeforeRefreshWrite)

    local bravoDpsID = root.characters["Player-1-BBB"].specProfiles[71]
    root.profiles[bravoDpsID].settings.font = "Fonts\\ARIALN.TTF"
    callScript("profiles.context.font_modal.open", env.StatsProFontDropdownButton, "OnClick")
    eq("profiles.context.font_modal.shown", env.StatsProFontPicker:IsShown(), true)
    contextTest.previewFontForSmoke("Fonts\\MORPHEUS.TTF")
    identity.specID, identity.specName, identity.role = 71, "Arms", "DAMAGER"
    fireEvent("profiles.context.font_modal.switch", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)
    eq("profiles.context.font_modal.closed", env.StatsProFontPicker:IsShown(), false)
    eq("profiles.context.font_modal.target_font_applied",
        contextTest.panelFontState().mainAppliedFont, "Fonts\\ARIALN.TTF")
    identity.specID, identity.specName, identity.role = 73, "Protection", "TANK"
    fireEvent("profiles.context.font_modal.restore_tank", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)

    env.UIDROPDOWNMENU_OPEN_MENU = env.StatsProLanguageDropdown
    env.DropDownList1:Show()
    contextTest.previewLanguageForSmoke("ruRU")
    identity.specID, identity.specName, identity.role = 71, "Arms", "DAMAGER"
    fireEvent("profiles.context.language_modal.switch", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)
    eq("profiles.context.language_modal.closed", env.DropDownList1:IsShown(), false)
    eq("profiles.context.language_modal.account_locale_unchanged", root.account.forceLocale, "auto")
    eq("profiles.context.language_modal.restored_copy",
        contextTest.launcherDescriptionText(),
        "Stats and gear HUD: item level, durability, repair cost and Archon stat targets. Click below to open the full settings window.")
    identity.specID, identity.specName, identity.role = 73, "Protection", "TANK"
    fireEvent("profiles.context.language_modal.restore_tank", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)

    contextTest.addConfigRefresherForSmoke(function() error("injected settings refresh failure") end)
    contextTest.addPersistentLocalizedLabelForSmoke(function()
        error("injected launcher refresh failure")
    end)
    identity.specID, identity.specName, identity.role = 71, "Arms", "DAMAGER"
    fireEvent("profiles.context.settings_refresh_failure", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)
    eq("profiles.context.settings_refresh_failure.context_survives",
        contextTest.profileRuntimeState().activeSpecID, 71)
    eq("profiles.context.settings_refresh_failure.profile_survives",
        contextTest.profileState().profileID, root.characters["Player-1-BBB"].specProfiles[71])
    identity.specID, identity.specName, identity.role = 73, "Protection", "TANK"
    fireEvent("profiles.context.settings_refresh_failure.restore_tank", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)

    local critSwatch = findFrame("profiles.context.modal.crit", env, function(frame)
        return frame.statsProColorKey == "crit" and type(frame.scripts.OnClick) == "function"
    end)
    local tankCrit = deepCopy(root.profiles[bravoTankID].settings.colors.crit)
    callScript("profiles.context.modal.open_color", critSwatch, "OnClick")
    local staleColorOptions = env.ColorPickerFrame.colorPickerOptions
    env.__setColorPickerRGB(0.2, 0.3, 0.4)
    staleColorOptions.swatchFunc()
    identity.specID, identity.specName, identity.role = 71, "Arms", "DAMAGER"
    fireEvent("profiles.context.modal.switch", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)
    eq("profiles.context.modal.color_closed", env.ColorPickerFrame:IsShown(), false)
    assertColor("profiles.context.modal.outgoing_restored",
        root.profiles[bravoTankID].settings.colors.crit, tankCrit.r, tankCrit.g, tankCrit.b)
    local newCritBefore = deepCopy(contextTest.profileState().settings.colors.crit)
    staleColorOptions.cancelFunc()
    assertColor("profiles.context.modal.stale_callback_noop",
        contextTest.profileState().settings.colors.crit,
        newCritBefore.r, newCritBefore.g, newCritBefore.b)

    env.SwiftStatsDB = { fontSize = 17 }
    slash("profiles.context.modal.import_open", env, "import")
    check("profiles.context.modal.import_visible", env.__lastStaticPopup ~= nil)
    identity.specID, identity.specName, identity.role = 73, "Protection", "TANK"
    fireEvent("profiles.context.modal.import_switch", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)
    eq("profiles.context.modal.import_closed", env.__lastStaticPopup, nil)

    local burstBefore = contextTest.profileRuntimeState()
    local timersBeforeBurst = #env.__timers
    identity.specID, identity.specName, identity.role = 71, "Arms", "DAMAGER"
    fireEvent("profiles.context.burst.first", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    identity.specID, identity.specName, identity.role = 73, "Protection", "TANK"
    fireEvent("profiles.context.burst.middle", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    identity.specID, identity.specName, identity.role = 71, "Arms", "DAMAGER"
    fireEvent("profiles.context.burst.last", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    eq("profiles.context.burst.one_timer", #env.__timers, timersBeforeBurst + 1)
    env.__flushTimers(0)
    local burstAfter = contextTest.profileRuntimeState()
    eq("profiles.context.burst.latest_context", burstAfter.activeSpecID, 71)
    eq("profiles.context.burst.one_activation", burstAfter.activationCount, burstBefore.activationCount + 1)
    eq("profiles.context.burst.one_apply", burstAfter.applyCount, burstBefore.applyCount + 1)

    local foreignMenu = makeFrame("OtherAddonDropdown")
    env.UIDROPDOWNMENU_OPEN_MENU = foreignMenu
    local closedBeforeForeign = env.__closedDropdowns
    identity.specID, identity.specName, identity.role = 73, "Protection", "TANK"
    fireEvent("profiles.context.foreign_modal_switch", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)
    eq("profiles.context.foreign_modal_preserved", env.__closedDropdowns, closedBeforeForeign)

    local relogEnv, _, relogTest = loadStatsPro("enUS", {
        statsProDB = root,
        unitGUID = function() return "Player-1-BBB" end,
        unitFullName = function() return "BravoRenamed", "Realm" end,
        getServerTime = function() return 1770001000 end,
        getSpecialization = function() return 1 end,
        getSpecializationInfo = function() return 73, "Protection", nil, nil, "TANK", 1 end,
    })
    fireEvent("profiles.context.relog_metadata", relogEnv, "PLAYER_ENTERING_WORLD")
    eq("profiles.context.relog_metadata.active", relogTest.profileRuntimeState().activeSpecID, 73)
    eq("profiles.context.relog_metadata.name",
        root.characters["Player-1-BBB"].displayName, "BravoRenamed-Realm")
    eq("profiles.context.relog_metadata.last_seen",
        root.characters["Player-1-BBB"].lastSeen, 1770001000)
end

do
    local seed = loadStatsPro("enUS")
    fireEvent("profiles.context.invalid.seed", seed, "PLAYER_ENTERING_WORLD")
    local cleanRoot = deepCopy(seed.StatsProDB)
    local secretGUID = {}
    local invalidEnv, _, invalidTest = loadStatsPro("enUS", {
        statsProDB = cleanRoot,
        unitGUID = function() return secretGUID end,
        getSpecialization = function() return 1 end,
        getSpecializationInfo = function() return 73, "Protection", nil, nil, "TANK", 1 end,
        issecretvalue = function(value) return value == secretGUID end,
    })
    local before = deepCopy(cleanRoot)
    fireEvent("profiles.context.invalid.secret_guid", invalidEnv, "PLAYER_ENTERING_WORLD")
    assertDeepEqual("profiles.context.invalid.secret_guid.no_writes", cleanRoot, before)
    eq("profiles.context.invalid.secret_guid.no_activation",
        invalidTest.profileRuntimeState().activationCount, 0)
    slash("profiles.context.invalid.secret_guid.block_write", invalidEnv, "hide")
    fireEvent("profiles.context.invalid.secret_guid.logout", invalidEnv, "PLAYER_LOGOUT")
    assertDeepEqual("profiles.context.invalid.secret_guid.pending_blocks_all_writes", cleanRoot, before)

    local noSpecRoot = deepCopy(seed.StatsProDB)
    local noSpecBefore = deepCopy(noSpecRoot)
    local noSpecEnv, _, noSpecTest = loadStatsPro("enUS", {
        statsProDB = noSpecRoot,
        unitGUID = function() return "Player-1-NOSPEC" end,
        getSpecialization = function() return nil end,
    })
    fireEvent("profiles.context.invalid.no_spec_initial", noSpecEnv, "PLAYER_ENTERING_WORLD")
    eq("profiles.context.invalid.no_spec_initial.no_character",
        noSpecRoot.characters["Player-1-NOSPEC"], nil)
    eq("profiles.context.invalid.no_spec_initial.default_profile",
        noSpecTest.profileState().profileID, noSpecRoot.account.defaultProfileID)
    slash("profiles.context.invalid.no_spec_initial.block_write", noSpecEnv, "hide")
    assertDeepEqual("profiles.context.invalid.no_spec_initial.no_writes",
        noSpecRoot, noSpecBefore)
    fireEvent("profiles.context.invalid.no_spec_initial.second_event",
        noSpecEnv, "PLAYER_SPECIALIZATION_CHANGED", "player")
    eq("profiles.context.invalid.no_spec_initial.second_event_coalesced",
        noSpecEnv.__flushTimers(0), 1)
    local readsBeforeNoSpecRetry = noSpecTest.profileRuntimeState().contextReadCount
    eq("profiles.context.invalid.no_spec_initial.stale_and_latest_timers",
        noSpecEnv.__flushTimers(0.1), 2)
    eq("profiles.context.invalid.no_spec_initial.only_latest_retries",
        noSpecTest.profileRuntimeState().contextReadCount, readsBeforeNoSpecRetry + 1)
    eq("profiles.context.invalid.no_spec_initial.settled",
        noSpecTest.profileRuntimeState().pendingResolution, false)
    slash("profiles.context.invalid.no_spec_initial.fallback_write", noSpecEnv, "hide")
    eq("profiles.context.invalid.no_spec_initial.fallback_unlocked",
        noSpecTest.profileState().settings.isVisible, false)

    local exhaustedRoot = deepCopy(seed.StatsProDB)
    exhaustedRoot.account.nextProfileID = 99999999999999
    local exhaustedBefore = deepCopy(exhaustedRoot)
    local exhaustedEnv, _, exhaustedTest = loadStatsPro("enUS", {
        statsProDB = exhaustedRoot,
        unitGUID = function() return "Player-1-FULL" end,
        getSpecialization = function() return 1 end,
        getSpecializationInfo = function() return 73, "Protection", nil, nil, "TANK", 1 end,
    })
    fireEvent("profiles.context.invalid.exhausted", exhaustedEnv, "PLAYER_ENTERING_WORLD")
    assertDeepEqual("profiles.context.invalid.exhausted.no_writes", exhaustedRoot, exhaustedBefore)
    eq("profiles.context.invalid.exhausted.pending",
        exhaustedTest.profileRuntimeState().pendingResolution, true)

    local futureRoot = deepCopy(seed.StatsProDB)
    futureRoot.dbVersion = invalidTest.currentDBVersion() + 1
    futureRoot.characters = "future-shape"
    local futureBefore = deepCopy(futureRoot)
    local futureEnv = loadStatsPro("enUS", {
        statsProDB = futureRoot,
        unitGUID = function() return "Player-1-FUTURE" end,
        getSpecialization = function() return 1 end,
        getSpecializationInfo = function() return 73, "Protection", nil, nil, "TANK", 1 end,
    })
    local ok, err = pcall(futureEnv.__fireEvent, "PLAYER_ENTERING_WORLD")
    check("profiles.context.invalid.future.no_error", ok, err)
    assertDeepEqual("profiles.context.invalid.future.no_writes", futureRoot, futureBefore)

    local corruptRoot = deepCopy(seed.StatsProDB)
    corruptRoot.characters = "corrupt-shape"
    local corruptBefore = deepCopy(corruptRoot)
    local corruptEnv = loadStatsPro("enUS", {
        statsProDB = corruptRoot,
        unitGUID = function() return "Player-1-CORRUPT" end,
        getSpecialization = function() return 1 end,
        getSpecializationInfo = function() return 73, "Protection", nil, nil, "TANK", 1 end,
    })
    ok, err = pcall(corruptEnv.__fireEvent, "PLAYER_ENTERING_WORLD")
    check("profiles.context.invalid.corrupt.no_error", ok, err)
    assertDeepEqual("profiles.context.invalid.corrupt.no_writes", corruptRoot, corruptBefore)

    local secretSpecID = {}
    local secretSpecRoot = deepCopy(seed.StatsProDB)
    local secretSpecBefore = deepCopy(secretSpecRoot)
    local secretSpecEnv = loadStatsPro("enUS", {
        statsProDB = secretSpecRoot,
        unitGUID = function() return "Player-1-SECRET-SPEC" end,
        getSpecialization = function() return 1 end,
        getSpecializationInfo = function() return secretSpecID, "Protection", nil, nil, "TANK", 1 end,
        issecretvalue = function(value) return value == secretSpecID end,
    })
    ok, err = pcall(secretSpecEnv.__fireEvent, "PLAYER_ENTERING_WORLD")
    check("profiles.context.invalid.secret_spec.no_error", ok, err)
    assertDeepEqual("profiles.context.invalid.secret_spec.no_writes",
        secretSpecRoot, secretSpecBefore)

    local secretIndex = {}
    local invalidSpecCases = {
        {
            name = "secret_index",
            getIndex = function() return secretIndex end,
            isSecret = function(value) return value == secretIndex end,
        },
        {
            name = "index_error",
            getIndex = function() error("spec index unavailable") end,
        },
        {
            name = "info_error",
            getIndex = function() return 1 end,
            getInfo = function() error("spec info unavailable") end,
        },
        {
            name = "nan_id",
            getIndex = function() return 1 end,
            getInfo = function() return 0 / 0, "Spec", nil, nil, "TANK", 1 end,
        },
        {
            name = "fractional_id",
            getIndex = function() return 1 end,
            getInfo = function() return 73.5, "Spec", nil, nil, "TANK", 1 end,
        },
        {
            name = "string_id",
            getIndex = function() return 1 end,
            getInfo = function() return "73", "Spec", nil, nil, "TANK", 1 end,
        },
    }
    for _, case in ipairs(invalidSpecCases) do
        local caseRoot = deepCopy(seed.StatsProDB)
        local caseBefore = deepCopy(caseRoot)
        local caseEnv, _, caseTest = loadStatsPro("enUS", {
            statsProDB = caseRoot,
            unitGUID = function() return "Player-1-" .. case.name end,
            getSpecialization = case.getIndex,
            getSpecializationInfo = case.getInfo or function()
                return 73, "Protection", nil, nil, "TANK", 1
            end,
            issecretvalue = case.isSecret,
        })
        ok, err = pcall(caseEnv.__fireEvent, "PLAYER_ENTERING_WORLD")
        check("profiles.context.invalid." .. case.name .. ".no_error", ok, err)
        assertDeepEqual("profiles.context.invalid." .. case.name .. ".no_writes",
            caseRoot, caseBefore)
        eq("profiles.context.invalid." .. case.name .. ".pending",
            caseTest.profileRuntimeState().pendingResolution, true)
    end

    local secretRole = "secret-tank-role"
    local secretRoleRoot = deepCopy(seed.StatsProDB)
    secretRoleRoot.profiles.p1.settings.showDefensive = false
    secretRoleRoot.profiles.p2 = {
        name = "Tank template",
        settings = deepCopy(secretRoleRoot.profiles.p1.settings),
    }
    secretRoleRoot.profiles.p2.settings.showDefensive = true
    secretRoleRoot.account.nextProfileID = 3
    secretRoleRoot.roleTemplates = { TANK = "p2", HEALER = "p1", DAMAGER = "p1" }
    local secretRoleEnv, _, secretRoleTest = loadStatsPro("enUS", {
        statsProDB = secretRoleRoot,
        unitGUID = function() return "Player-1-SECRET-ROLE" end,
        getSpecialization = function() return 1 end,
        getSpecializationInfo = function()
            return 73, "Protection", nil, nil, secretRole, 1
        end,
        issecretvalue = function(value) return value == secretRole end,
    })
    fireEvent("profiles.context.invalid.secret_role", secretRoleEnv, "PLAYER_ENTERING_WORLD")
    eq("profiles.context.invalid.secret_role.account_fallback",
        secretRoleTest.profileState().settings.showDefensive, false)
end

do
    local seed = loadStatsPro("enUS")
    fireEvent("profiles.context.rollback.seed", seed, "PLAYER_ENTERING_WORLD")
    local root = deepCopy(seed.StatsProDB)
    local identity = { specID = 73 }
    local env, _, rollbackTest = loadStatsPro("enUS", {
        statsProDB = root,
        unitGUID = function() return "Player-1-ROLLBACK" end,
        getSpecialization = function() return 1 end,
        getSpecializationInfo = function()
            return identity.specID, "Spec", nil, nil, "TANK", 1
        end,
    })
    fireEvent("profiles.context.rollback.first", env, "PLAYER_ENTERING_WORLD")
    local oldProfileID = rollbackTest.profileState().profileID
    local nextID = root.account.nextProfileID
    local rootBefore = deepCopy(root)
    local accountRef = root.account
    local profilesRef = root.profiles
    local charactersRef = root.characters
    local rolesRef = root.roleTemplates
    local oldSettingsRef = root.profiles[oldProfileID].settings
    local oldColorsRef = oldSettingsRef.colors
    local oldSetPoint = env.StatsProFrame.SetPoint
    local oldPoint = deepCopy(env.StatsProFrame.points)
    local failNextSetPoint = true
    env.StatsProFrame.SetPoint = function(frame, ...)
        if failNextSetPoint then
            failNextSetPoint = false
            error("injected profile apply failure")
        end
        return oldSetPoint(frame, ...)
    end
    identity.specID = 999
    fireEvent("profiles.context.rollback.switch", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)
    env.StatsProFrame.SetPoint = oldSetPoint
    eq("profiles.context.rollback.active_restored", rollbackTest.profileState().profileID, oldProfileID)
    eq("profiles.context.rollback.assignment_removed",
        root.characters["Player-1-ROLLBACK"].specProfiles[999], nil)
    eq("profiles.context.rollback.next_id_restored", root.account.nextProfileID, nextID)
    eq("profiles.context.rollback.pending", rollbackTest.profileRuntimeState().pendingResolution, true)
    assertDeepEqual("profiles.context.rollback.position_restored", env.StatsProFrame.points, oldPoint)
    assertDeepEqual("profiles.context.rollback.full_root_restored", root, rootBefore)
    eq("profiles.context.rollback.account_identity", rawequal(root.account, accountRef), true)
    eq("profiles.context.rollback.profiles_identity", rawequal(root.profiles, profilesRef), true)
    eq("profiles.context.rollback.characters_identity", rawequal(root.characters, charactersRef), true)
    eq("profiles.context.rollback.roles_identity", rawequal(root.roleTemplates, rolesRef), true)
    eq("profiles.context.rollback.settings_identity",
        rawequal(root.profiles[oldProfileID].settings, oldSettingsRef), true)
    eq("profiles.context.rollback.colors_identity",
        rawequal(root.profiles[oldProfileID].settings.colors, oldColorsRef), true)
    eq("profiles.context.rollback.no_orphan_profile", root.profiles["p" .. tostring(nextID)], nil)
    eq("profiles.context.rollback.registry_current", rollbackTest.dbCompatibilityState().mode, "current")
end

do
    -- A metadata-only registry transaction can target an already existing profile.
    -- If applying that target fails after touching its payload, both structures and
    -- payload values must roll back rather than leaking a partial switch.
    local seed = loadStatsPro("enUS")
    fireEvent("profiles.context.metadata_rollback.seed", seed, "PLAYER_ENTERING_WORLD")
    local root = deepCopy(seed.StatsProDB)
    root.profiles.p2 = {
        name = "Existing target",
        settings = deepCopy(root.profiles.p1.settings),
    }
    root.profiles.p2.settings.showDefensive = true
    root.account.nextProfileID = 3
    root.roleTemplates = { TANK = "p1", HEALER = "p1", DAMAGER = "p1" }
    root.characters = {
        ["Player-1-META-A"] = {
            displayName = "Alpha-Realm",
            lastSeen = 1,
            defaultProfileID = "p1",
            specProfiles = { [73] = "p1" },
        },
        ["Player-1-META-B"] = {
            displayName = "Old-Bravo",
            lastSeen = 1,
            defaultProfileID = "p1",
            specProfiles = { [73] = "p2" },
        },
    }
    local identity = { guid = "Player-1-META-A", name = "Alpha" }
    local env, _, profileTest = loadStatsPro("enUS", {
        statsProDB = root,
        unitGUID = function() return identity.guid end,
        unitFullName = function() return identity.name, "Realm" end,
        getServerTime = function() return 1 end,
        getSpecialization = function() return 1 end,
        getSpecializationInfo = function()
            return 73, "Protection", nil, nil, "TANK", 1
        end,
    })
    fireEvent("profiles.context.metadata_rollback.activate", env, "PLAYER_ENTERING_WORLD")
    local rootBefore = deepCopy(root)
    local targetProfileRef = root.profiles.p2
    local targetSettingsRef = targetProfileRef.settings
    local runtimeBefore = profileTest.profileRuntimeState()
    local oldSetPoint = env.StatsProFrame.SetPoint
    local failNextApply = true
    env.StatsProFrame.SetPoint = function(frame, ...)
        if failNextApply then
            failNextApply = false
            root.profiles.p2.settings.showDefensive = false
            root.profiles.p2.settings.colors.crit.r = 0.123
            error("injected existing-target apply failure")
        end
        return oldSetPoint(frame, ...)
    end
    identity.guid, identity.name = "Player-1-META-B", "NewBravo"
    fireEvent("profiles.context.metadata_rollback.switch",
        env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)
    env.StatsProFrame.SetPoint = oldSetPoint
    assertDeepEqual("profiles.context.metadata_rollback.full_root", root, rootBefore)
    eq("profiles.context.metadata_rollback.profile_identity",
        rawequal(root.profiles.p2, targetProfileRef), true)
    eq("profiles.context.metadata_rollback.settings_identity",
        rawequal(root.profiles.p2.settings, targetSettingsRef), true)
    eq("profiles.context.metadata_rollback.active_guid",
        profileTest.profileRuntimeState().activeGUID, runtimeBefore.activeGUID)
    eq("profiles.context.metadata_rollback.active_profile",
        profileTest.profileState().profileID, "p1")
    eq("profiles.context.metadata_rollback.pending",
        profileTest.profileRuntimeState().pendingResolution, true)
end

do
    -- The profile manager shell is intentionally read-only until transactional profile
    -- operations land. This block proves that navigation cannot mutate the
    -- registry while active/pending/compatibility state stays live on every tab.
    local seedEnv = loadStatsPro("enUS")
    fireEvent("profiles.ui.seed", seedEnv, "PLAYER_ENTERING_WORLD")
    local root = deepCopy(seedEnv.StatsProDB)
    local baseSettings = deepCopy(root.profiles.p1.settings)
    root.profiles.p1.name = "Account default"
    root.profiles.p2 = { name = "Tank shared", settings = deepCopy(baseSettings) }
    root.profiles.p3 = { name = "Damage solo", settings = deepCopy(baseSettings) }
    root.account.defaultProfileID = "p1"
    root.account.nextProfileID = 4
    root.roleTemplates = { TANK = "p1", HEALER = "p1", DAMAGER = "p1" }
    root.characters = {
        ["Player-1-ALPHA"] = {
            displayName = "Alpha-Realm",
            lastSeen = 100,
            defaultProfileID = "p1",
            specProfiles = { [73] = "p2", [71] = "p3" },
        },
        ["Player-1-BRAVO"] = {
            displayName = "Bravo-Realm",
            lastSeen = 300,
            defaultProfileID = "p1",
            specProfiles = { [73] = "p2", [72] = "p1" },
        },
        ["Player-1-CHARLIE"] = {
            displayName = "Charlie-Realm",
            lastSeen = 200,
            defaultProfileID = "p1",
            specProfiles = { [72] = "p1" },
        },
    }

    local identity = {
        specID = 73,
        specName = "Protection",
        role = "TANK",
        combat = false,
    }
    local env, addonContext, profileTest = loadStatsPro("enUS", {
        statsProDB = root,
        uiParentWidth = 1024,
        uiParentHeight = 768,
        unitGUID = function() return "Player-1-ALPHA" end,
        unitFullName = function() return "Alpha", "Realm" end,
        getServerTime = function() return 5000 end,
        getSpecialization = function() return 1 end,
        getSpecializationInfo = function()
            return identity.specID, identity.specName, nil, nil, identity.role, 1
        end,
        inCombatLockdown = function() return identity.combat end,
    })
    fireEvent("profiles.ui.activate", env, "PLAYER_ENTERING_WORLD")

    local model = profileTest.profileViewModel()
    eq("profiles.ui.model.mode", model.mode, "current")
    eq("profiles.ui.model.mutable", model.canMutate, true)
    eq("profiles.ui.model.character_count", #model.characters, 3)
    eq("profiles.ui.model.current_pinned", model.characters[1].guid, "Player-1-ALPHA")
    eq("profiles.ui.model.recent_second", model.characters[2].guid, "Player-1-BRAVO")
    eq("profiles.ui.model.recent_third", model.characters[3].guid, "Player-1-CHARLIE")
    eq("profiles.ui.model.alpha_observed_specs", #model.characters[1].specs, 2)
    eq("profiles.ui.model.bravo_observed_specs", #model.characters[2].specs, 2)
    eq("profiles.ui.model.charlie_observed_specs", #model.characters[3].specs, 1)
    eq("profiles.ui.model.active_spec_first", model.characters[1].specs[1].specID, 73)
    eq("profiles.ui.model.active_spec_marked", model.characters[1].specs[1].isActive, true)
    eq("profiles.ui.model.shared_count", model.characters[1].specs[1].sharedCount, 2)
    eq("profiles.ui.model.active_shared_count", model.activeSharedCount, 2)
    eq("profiles.ui.model.default_shared_count", model.characters[1].defaultSharedCount, 2)
    eq("profiles.ui.model.offline_spec_fallback", model.characters[3].specs[1].specName, nil)
    eq("profiles.ui.model.active_display_name", model.activeDisplayName, "Alpha-Realm")
    eq("profiles.ui.model.active_spec_name", model.activeSpecName, "Protection")

    local beforeUI = deepCopy(root)
    local accountRef = root.account
    local profilesRef = root.profiles
    local charactersRef = root.characters
    local alphaRef = root.characters["Player-1-ALPHA"]
    local alphaSpecsRef = alphaRef.specProfiles
    local bravoRef = root.characters["Player-1-BRAVO"]
    local bravoSpecsRef = bravoRef.specProfiles
    local sharedProfileRef = root.profiles.p2
    local sharedSettingsRef = sharedProfileRef.settings
    local validationBeforeUI = profileTest.dbValidationCount()
    addonContext:OpenConfigMenu()
    local config = exists("profiles.ui.config", env.StatsProConfigFrame)
    local header = exists("profiles.ui.header", env.StatsProProfileHeader)
    local manager = exists("profiles.ui.manager", env.StatsProProfileManager)
    eq("profiles.ui.manager.surface", manager.statsProSurfaceRole, "window")
    eq("profiles.ui.operation_dialog.surface",
        env.StatsProProfileOperationDialog.statsProSurfaceRole, "window")
    eq("profiles.ui.minimum.config_width", config:GetWidth(), 500)
    eq("profiles.ui.minimum.config_height", config:GetHeight(), 600)
    eq("profiles.ui.minimum.manager_width", manager:GetWidth(), 620)
    eq("profiles.ui.minimum.manager_height", manager:GetHeight(), 440)
    eq("profiles.ui.minimum.header_top", header.points[1][3], -44)
    eq("profiles.ui.minimum.header_height", header:GetHeight(), 48)
    eq("profiles.ui.minimum.tab_top", config.tabStrip.points[1][3], -100)
    eq("profiles.ui.minimum.scroll_top", env.StatsProConfigScroll.points[1][3], -140)
    check("profiles.ui.minimum.scroll_viewport_positive",
        config:GetHeight() - 140 - 66 > 0)

    local state = profileTest.profileUIState()
    eq("profiles.ui.header.label", state.headerLabel, "Profile:")
    eq("profiles.ui.header.profile", state.headerProfile, "Tank shared")
    eq("profiles.ui.header.shared", state.headerSubtitle, "Shared by 2 specs")
    assertColor("profiles.ui.header.shared_color", state.headerSubtitleColor, 0.70, 0.74, 0.72)
    for tabIndex = 1, 3 do
        config.SwitchToTab(tabIndex)
        eq("profiles.ui.tabs.active." .. tabIndex, config.activeTabIndex, tabIndex)
        eq("profiles.ui.tabs.header_visible." .. tabIndex, header:IsShown(), true)
        for contentIndex, content in ipairs(config.tabContents) do
            eq("profiles.ui.tabs.content." .. tabIndex .. "." .. contentIndex,
                content:IsShown(), contentIndex == tabIndex)
        end
    end

    callScript("profiles.ui.manager.open", env.StatsProManageProfilesButton, "OnClick")
    state = profileTest.profileUIState()
    eq("profiles.ui.manager.shown", state.managerShown, true)
    eq("profiles.ui.manager.strata", state.managerFrameStrata, "DIALOG")
    eq("profiles.ui.manager.list_surface_role", state.managerListSurfaceRole, "viewport")
    eq("profiles.ui.manager.list_surface_parent_owned", state.managerListSurfaceParentOwned, true)
    eq("profiles.ui.manager.detail_surface_role", state.managerDetailSurfaceRole, "raised")
    eq("profiles.ui.manager.detail_surface_parent_owned", state.managerDetailSurfaceParentOwned, true)
    check("profiles.ui.manager.level", manager:GetFrameLevel() > config:GetFrameLevel())
    check("profiles.ui.manager.special_frame",
        contains(env.UISpecialFrames, "StatsProProfileManager"))
    eq("profiles.ui.manager.current_row", state.rows[1].context.guid, "Player-1-ALPHA")
    eq("profiles.ui.manager.current_badge", state.rows[1].badge, "Current")
    eq("profiles.ui.manager.active_row", state.rows[2].context.specID, 73)
    eq("profiles.ui.manager.active_badge", state.rows[2].badge, "Active")
    local shownRows = 0
    for _, row in ipairs(state.rows) do
        if row.shown then shownRows = shownRows + 1 end
    end
    eq("profiles.ui.manager.observed_row_storage", #state.rows, 8)
    eq("profiles.ui.manager.observed_rows_shown", shownRows, 8)
    eq("profiles.ui.manager.detail_character", state.detailCharacter, "Alpha-Realm")
    eq("profiles.ui.manager.detail_context", state.detailContext, "Protection")
    eq("profiles.ui.manager.detail_profile", state.detailProfile, "Tank shared")
    eq("profiles.ui.manager.detail_shared", state.detailSharing, "Shared by 2 specs")
    callScript("profiles.ui.header_button.assign", env.StatsProActiveProfileButton, "OnClick")
    state = profileTest.profileUIState()
    eq("profiles.ui.header_button.manager_open", manager:IsShown(), true)
    eq("profiles.ui.header_button.dialog_open", state.operationDialogShown, true)
    eq("profiles.ui.header_button.kind", state.operationKind, "assign-profile")
    eq("profiles.ui.header_button.blocker", state.operationBlockerShown, true)
    check("profiles.ui.header_button.blocker_level",
        state.operationBlockerLevel < state.operationDialogLevel)
    callScript("profiles.ui.header_button.cancel",
        env.StatsProProfileOperationCancelButton, "OnClick")
    eq("profiles.ui.header_button.dialog_closed",
        profileTest.profileUIState().operationDialogShown, false)
    flushTimers("profiles.ui.header_button.restore_manager", env, 0, 1)

    eq("profiles.ui.escape.manager_only.config_removed",
        countValue(env.UISpecialFrames, "StatsProConfigFrame"), 0)
    eq("profiles.ui.escape.manager_only.manager_once",
        countValue(env.UISpecialFrames, "StatsProProfileManager"), 1)
    callScript("profiles.ui.escape.dialog.open", env.StatsProActiveProfileButton, "OnClick")
    eq("profiles.ui.escape.dialog_only.manager_removed",
        countValue(env.UISpecialFrames, "StatsProProfileManager"), 0)
    eq("profiles.ui.escape.dialog_only.dialog_once",
        countValue(env.UISpecialFrames, "StatsProProfileOperationDialog"), 1)
    local foreignSpecial = env.CreateFrame(
        "Frame", "StatsProEscapeForeignSpecialFrame", env.UIParent)
    foreignSpecial:Show()
    table.insert(env.UISpecialFrames, "StatsProEscapeForeignSpecialFrame")
    eq("profiles.ui.escape.dialog.close", closeSpecialWindows(env), true)
    eq("profiles.ui.escape.dialog.closed",
        profileTest.profileUIState().operationDialogShown, false)
    eq("profiles.ui.escape.dialog.manager_preserved", manager:IsShown(), true)
    eq("profiles.ui.escape.dialog.config_preserved", config:IsShown(), true)
    eq("profiles.ui.escape.dialog.manager_not_restored_inside_live_walk",
        countValue(env.UISpecialFrames, "StatsProProfileManager"), 0)
    eq("profiles.ui.escape.dialog.config_not_restored_inside_live_walk",
        countValue(env.UISpecialFrames, "StatsProConfigFrame"), 0)
    flushTimers("profiles.ui.escape.dialog.restore_manager", env, 0, 1)
    eq("profiles.ui.escape.dialog.manager_restored_once",
        countValue(env.UISpecialFrames, "StatsProProfileManager"), 1)
    eq("profiles.ui.escape.dialog.config_still_suspended",
        countValue(env.UISpecialFrames, "StatsProConfigFrame"), 0)
    eq("profiles.ui.escape.manager.close", closeSpecialWindows(env), true)
    eq("profiles.ui.escape.manager.closed", manager:IsShown(), false)
    eq("profiles.ui.escape.manager.config_preserved", config:IsShown(), true)
    eq("profiles.ui.escape.manager.config_not_restored_inside_live_walk",
        countValue(env.UISpecialFrames, "StatsProConfigFrame"), 0)
    flushTimers("profiles.ui.escape.manager.restore_config", env, 0, 1)
    eq("profiles.ui.escape.config_only.config_once",
        countValue(env.UISpecialFrames, "StatsProConfigFrame"), 1)
    eq("profiles.ui.escape.config.close", closeSpecialWindows(env), true)
    eq("profiles.ui.escape.config.closed", config:IsShown(), false)
    addonContext:OpenConfigMenu()
    callScript("profiles.ui.escape.reopen_manager", env.StatsProManageProfilesButton, "OnClick")
    eq("profiles.ui.escape.reopen_config", config:IsShown(), true)
    eq("profiles.ui.escape.reopen_manager_shown", manager:IsShown(), true)

    local alphaCharacterRow = findFrame("profiles.ui.manager.alpha_character_row", env, function(frame)
        return type(frame.profileContext) == "table"
            and frame.profileContext.guid == "Player-1-ALPHA"
            and frame.profileContext.specID == nil
    end)
    callScript("profiles.ui.manager.select_character_default", alphaCharacterRow, "OnClick")
    state = profileTest.profileUIState()
    eq("profiles.ui.manager.default_context", state.detailContext, "Character default")
    eq("profiles.ui.manager.default_profile", state.detailProfile, "Account default")
    eq("profiles.ui.manager.default_shared", state.detailSharing, "Shared by 2 specs")

    local bravoSpecRow = findFrame("profiles.ui.manager.bravo_spec_row", env, function(frame)
        return type(frame.profileContext) == "table"
            and frame.profileContext.guid == "Player-1-BRAVO"
            and frame.profileContext.specID == 73
    end)
    callScript("profiles.ui.manager.select_other", bravoSpecRow, "OnClick")
    state = profileTest.profileUIState()
    eq("profiles.ui.manager.selection_guid", state.selectedGUID, "Player-1-BRAVO")
    eq("profiles.ui.manager.selection_spec", state.selectedSpecID, 73)
    eq("profiles.ui.manager.selection_detail", state.detailCharacter, "Bravo-Realm")
    eq("profiles.ui.manager.selection_profile", state.detailProfile, "Tank shared")
    assertDeepEqual("profiles.ui.navigation.no_writes", root, beforeUI)
    eq("profiles.ui.navigation.account_identity", rawequal(root.account, accountRef), true)
    eq("profiles.ui.navigation.profiles_identity", rawequal(root.profiles, profilesRef), true)
    eq("profiles.ui.navigation.characters_identity", rawequal(root.characters, charactersRef), true)
    eq("profiles.ui.navigation.alpha_identity",
        rawequal(root.characters["Player-1-ALPHA"], alphaRef), true)
    eq("profiles.ui.navigation.alpha_specs_identity",
        rawequal(root.characters["Player-1-ALPHA"].specProfiles, alphaSpecsRef), true)
    eq("profiles.ui.navigation.bravo_identity",
        rawequal(root.characters["Player-1-BRAVO"], bravoRef), true)
    eq("profiles.ui.navigation.bravo_specs_identity",
        rawequal(root.characters["Player-1-BRAVO"].specProfiles, bravoSpecsRef), true)
    eq("profiles.ui.navigation.shared_profile_identity", rawequal(root.profiles.p2, sharedProfileRef), true)
    eq("profiles.ui.navigation.shared_settings_identity",
        rawequal(root.profiles.p2.settings, sharedSettingsRef), true)
    eq("profiles.ui.navigation.cached_validation",
        profileTest.dbValidationCount(), validationBeforeUI)

    identity.specID, identity.specName, identity.role = 71, "Arms", "DAMAGER"
    fireEvent("profiles.ui.live_switch", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)
    state = profileTest.profileUIState()
    eq("profiles.ui.live_switch.header", state.headerProfile, "Damage solo")
    eq("profiles.ui.live_switch.subtitle", state.headerSubtitle,
        "Automatic - Alpha-Realm / Arms")
    eq("profiles.ui.live_switch.manager_stays_open", state.managerShown, true)
    eq("profiles.ui.live_switch.selection_preserved", state.selectedGUID, "Player-1-BRAVO")
    eq("profiles.ui.live_switch.selection_spec_preserved", state.selectedSpecID, 73)
    eq("profiles.ui.live_switch.active_spec", profileTest.profileViewModel().activeSpecID, 71)

    identity.combat = true
    identity.specID, identity.specName, identity.role = 73, "Protection", "TANK"
    fireEvent("profiles.ui.combat_pending", env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)
    state = profileTest.profileUIState()
    model = profileTest.profileViewModel()
    eq("profiles.ui.combat_pending.header_keeps_old", state.headerProfile, "Damage solo")
    eq("profiles.ui.combat_pending.subtitle", state.headerSubtitle,
        "Switch pending until combat ends")
    assertColor("profiles.ui.combat_pending.subtitle_color",
        state.headerSubtitleColor, 1, 0.68, 0.22)
    eq("profiles.ui.combat_pending.read_only", model.canMutate, false)
    eq("profiles.ui.combat_pending.active_kept", model.activeSpecID, 71)
    eq("profiles.ui.combat_pending.notice", state.detailNotice,
        "Profile changes are unavailable during combat.")
    identity.combat = false
    fireEvent("profiles.ui.combat_resume", env, "PLAYER_REGEN_ENABLED")
    state = profileTest.profileUIState()
    eq("profiles.ui.combat_resume.header", state.headerProfile, "Tank shared")
    eq("profiles.ui.combat_resume.subtitle", state.headerSubtitle, "Shared by 2 specs")
    eq("profiles.ui.combat_resume.mutable", profileTest.profileViewModel().canMutate, true)

    config:Hide()
    eq("profiles.ui.config_hide.closes_manager", manager:IsShown(), false)
    addonContext:OpenConfigMenu()
    eq("profiles.ui.reopen.first_tab", config.activeTabIndex, 1)
    eq("profiles.ui.reopen.header_visible", header:IsShown(), true)
end

do
    local seed = loadStatsPro("enUS")
    fireEvent("profiles.ui.late_metadata.seed", seed, "PLAYER_ENTERING_WORLD")
    local root = deepCopy(seed.StatsProDB)
    root.characters = {
        ["Player-1-LATE"] = {
            displayName = "Character",
            lastSeen = 1,
            defaultProfileID = "p1",
            specProfiles = { [73] = "p1" },
        },
    }
    local metadata = { available = false }
    local env, addonContext, profileTest = loadStatsPro("enUS", {
        statsProDB = root,
        unitGUID = function() return "Player-1-LATE" end,
        unitFullName = function()
            if metadata.available then return "Late", "Realm" end
            return nil, nil
        end,
        getServerTime = function() return 1 end,
        getSpecialization = function() return 1 end,
        getSpecializationInfo = function()
            return 73, metadata.available and "Protection" or nil,
                nil, nil, "TANK", 1
        end,
    })
    fireEvent("profiles.ui.late_metadata.activate", env, "PLAYER_ENTERING_WORLD")
    addonContext:OpenConfigMenu()
    eq("profiles.ui.late_metadata.persisted_character_header",
        profileTest.profileUIState().headerSubtitle, "Automatic - Character / Spec 73")
    local runtimeBefore = profileTest.profileRuntimeState()
    metadata.available = true
    fireEvent("profiles.ui.late_metadata.refresh", env,
        "PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)
    local state = profileTest.profileUIState()
    local runtimeAfter = profileTest.profileRuntimeState()
    eq("profiles.ui.late_metadata.header", state.headerSubtitle,
        "Automatic - Late-Realm / Protection")
    eq("profiles.ui.late_metadata.character_record",
        root.characters["Player-1-LATE"].displayName, "Late-Realm")
    eq("profiles.ui.late_metadata.no_activation",
        runtimeAfter.activationCount, runtimeBefore.activationCount)
    eq("profiles.ui.late_metadata.no_reapply", runtimeAfter.applyCount, runtimeBefore.applyCount)
    callScript("profiles.ui.late_metadata.open_manager",
        env.StatsProManageProfilesButton, "OnClick")
    state = profileTest.profileUIState()
    check("profiles.ui.late_metadata.manager_row",
        state.rows[1].text:find("Late-Realm", 1, true) ~= nil)
    eq("profiles.ui.late_metadata.spec_name", state.detailContext, "Protection")
end

do
    local seed = loadStatsPro("enUS")
    fireEvent("profiles.ui.unknown_combat.seed", seed, "PLAYER_ENTERING_WORLD")
    local root = deepCopy(seed.StatsProDB)
    local before = deepCopy(root)
    local secretCombat = {}
    local env, addonContext, profileTest = loadStatsPro("enUS", {
        statsProDB = root,
        unitGUID = function() return "Player-1-UNKNOWN-COMBAT" end,
        getSpecialization = function() return 1 end,
        getSpecializationInfo = function()
            return 73, "Protection", nil, nil, "TANK", 1
        end,
        inCombatLockdown = function() return secretCombat end,
        issecretvalue = function(value) return value == secretCombat end,
    })
    fireEvent("profiles.ui.unknown_combat.activate", env, "PLAYER_ENTERING_WORLD")
    addonContext:OpenConfigMenu()
    local shellState = profileTest.settingsShellState()
    runFrameHandlers(shellState.tabs[2], "OnEnter")
    runFrameHandlers(shellState.tabs[2], "OnMouseDown", "LeftButton")
    runFrameHandlers(shellState.tabs[2], "OnMouseUp", "LeftButton")
    runFrameHandlers(shellState.tabs[2], "OnLeave")
    runFrameHandlers(shellState.tabs[2], "OnClick")
    callScript("profiles.ui.unknown_combat.open_manager",
        env.StatsProManageProfilesButton, "OnClick")
    local model = profileTest.profileViewModel()
    local state = profileTest.profileUIState()
    eq("profiles.ui.unknown_combat.gated", model.canMutate, false)
    eq("profiles.ui.unknown_combat.pending", model.pending, true)
    eq("profiles.ui.unknown_combat.notice", state.detailNotice,
        "Waiting for a safe profile context.")
    eq("profiles.ui.unknown_combat.root_identity", rawequal(env.StatsProDB, root), true)
    assertDeepEqual("profiles.ui.unknown_combat.no_writes", env.StatsProDB, before)
end

do
    local seed = loadStatsPro("enUS")
    fireEvent("profiles.ui.compat.seed", seed, "PLAYER_ENTERING_WORLD")
    local futureRoot = {
        dbVersion = seed.StatsProDB.dbVersion + 1,
        opaque = { keep = "exactly" },
        account = "not inspected",
        profiles = 42,
        characters = { secret = true },
    }
    local before = deepCopy(futureRoot)
    local env, addonContext, profileTest = loadStatsPro("enUS", {
        statsProDB = futureRoot,
        unitGUID = function() return "Player-1-FUTURE-UI" end,
        getSpecialization = function() return 1 end,
        getSpecializationInfo = function()
            return 73, "Protection", nil, nil, "TANK", 1
        end,
    })
    fireEvent("profiles.ui.compat.activate", env, "PLAYER_ENTERING_WORLD")
    addonContext:OpenConfigMenu()
    local shellState = profileTest.settingsShellState()
    for _, tab in ipairs(shellState.tabs) do
        runFrameHandlers(tab, "OnEnter")
        runFrameHandlers(tab, "OnMouseDown", "LeftButton")
        runFrameHandlers(tab, "OnMouseUp", "LeftButton")
        runFrameHandlers(tab, "OnLeave")
        runFrameHandlers(tab, "OnClick")
    end
    local state = profileTest.profileUIState()
    local model = profileTest.profileViewModel()
    eq("profiles.ui.compat.read_only", model.readOnly, true)
    eq("profiles.ui.compat.no_characters", #model.characters, 0)
    eq("profiles.ui.compat.header", state.headerSubtitle,
        "Compatibility mode - profiles are read-only.")
    assertColor("profiles.ui.compat.header_color", state.headerSubtitleColor, 1, 0.68, 0.22)
    callScript("profiles.ui.compat.open_manager", env.StatsProManageProfilesButton, "OnClick")
    state = profileTest.profileUIState()
    eq("profiles.ui.compat.manager_open", state.managerShown, true)
    eq("profiles.ui.compat.no_rows", #state.rows, 0)
    eq("profiles.ui.compat.empty_detail", state.detailCharacter, "No visited characters")
    eq("profiles.ui.compat.notice", state.detailNotice,
        "Compatibility mode - profiles are read-only.")
    eq("profiles.ui.compat.root_identity", rawequal(env.StatsProDB, futureRoot), true)
    assertDeepEqual("profiles.ui.compat.no_writes", env.StatsProDB, before)
end

do
    local seed = loadStatsPro("enUS")
    fireEvent("profiles.ui.no_spec.seed", seed, "PLAYER_ENTERING_WORLD")
    local root = deepCopy(seed.StatsProDB)
    root.characters = {}
    local before = deepCopy(root)
    local env, addonContext, profileTest = loadStatsPro("enUS", {
        statsProDB = root,
        unitGUID = function() return "Player-1-NO-SPEC-UI" end,
        getSpecialization = function() return nil end,
    })
    fireEvent("profiles.ui.no_spec.activate", env, "PLAYER_ENTERING_WORLD")
    addonContext:OpenConfigMenu()
    eq("profiles.ui.no_spec.pending", profileTest.profileUIState().headerSubtitle,
        "Switch pending until combat ends")
    env.__flushTimers(0.1)
    eq("profiles.ui.no_spec.fallback", profileTest.profileUIState().headerSubtitle,
        "Account default profile")
    callScript("profiles.ui.no_spec.open_manager", env.StatsProManageProfilesButton, "OnClick")
    eq("profiles.ui.no_spec.no_rows", #profileTest.profileUIState().rows, 0)
    eq("profiles.ui.no_spec.root_identity", rawequal(env.StatsProDB, root), true)
    assertDeepEqual("profiles.ui.no_spec.no_writes", env.StatsProDB, before)
end

do
    local registryEnv, _, registryTest = loadStatsPro("enUS")
    local labelsByLocale = registryTest.registrySnapshot().labelsByLocale
    local locales = { "enUS", "ruRU", "deDE", "frFR", "esES", "esMX",
        "itIT", "ptBR", "koKR", "zhCN", "zhTW" }
    local formatCases = {
        ["%s Copy"] = { "Profile" },
        ["Profile names can contain at most %d characters."] = { 40 },
        ["%d assigned specs, %d other references"] = { 2, 3 },
        ["Delete profile \"%s\" and replace all references with \"%s\"? This affects %d assigned specs and %d other references."] = { "A", "B", 2, 3 },
        ["Swap \"%s\" and \"%s\"? Their profile settings stay unchanged."] = { "A", "B" },
        ["Rename shared profile \"%s\" to \"%s\"? This affects %d assigned specs and %d other references."] = { "A", "B", 2, 3 },
        ["Copy settings from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = { "A", "B", 2, 3 },
        ["Copy %s from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = { "Stats", "A", "B", 2, 3 },
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = { "A", 2, 3 },
        ["Delete unused profile \"%s\"?"] = { "A" },
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = { "A" },
        ["%s - %d known specs"] = { "A", 3 },
        ["Tank: %s"] = { "A" },
        ["Healer: %s"] = { "A" },
        ["Damage: %s"] = { "A" },
        ["Use \"%s\" for all %d known specs of \"%s\"? Existing profiles and settings will be kept."] = { "A", 3, "B" },
        ["Make %d shared specs of \"%s\" independent? Each affected spec receives a separate copy; existing profiles stay unchanged."] = { 2, "A" },
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = { "A" },
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = { "A" },
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = { "A" },
    }
    local requiredOperationKeys = {
        "Profile to manage:", "Choose a profile", "Assign to selected context",
        "New from defaults...", "Duplicate profile...", "Rename profile...",
        "Copy settings to assigned profile...", "Swap assignments...",
        "Reset active profile...", "Delete profile...", "Forget character...",
        "Confirm", "Unused", "Unused profile", "New Profile",
        "Choose a replacement profile", "Choose a context",
        "All settings", "Stat and gear settings", "Layout settings",
        "Appearance settings", "Choose settings to copy",
        "Profile changes saved.", "Enter a valid profile name.",
        "A profile with this name already exists.",
        "Profiles changed; review and try again.",
        "The last profile cannot be deleted.", "Choose a replacement profile.",
        "The current character cannot be forgotten.", "Nothing changed.",
        "Profile operation failed. Review the selection and try again.",
        "Selected character", "Future new contexts", "Tank", "Healer", "Damage",
        "Use profile for all known specs...", "Make shared specs independent...",
        "Set future role template...", "Choose a role",
    }
    local function placeholderCount(value, token)
        local _, count = value:gsub("%%" .. token, "")
        return count
    end
    fireEvent("profiles.ui.locales.seed", registryEnv, "PLAYER_ENTERING_WORLD")
    local seedRoot = deepCopy(registryEnv.StatsProDB)
    for _, locale in ipairs(locales) do
        local root = deepCopy(seedRoot)
        root.profiles.p2 = { name = "Танк 配置", settings = deepCopy(root.profiles.p1.settings) }
        root.profiles.p3 = { name = "Solo", settings = deepCopy(root.profiles.p1.settings) }
        root.account.forceLocale = locale
        root.account.nextProfileID = 4
        root.roleTemplates = { TANK = "p1", HEALER = "p1", DAMAGER = "p1" }
        root.characters = {
            ["Player-1-LOCALE"] = {
                displayName = "Alpha-Realm",
                lastSeen = 1,
                defaultProfileID = "p1",
                specProfiles = { [73] = "p2", [71] = "p3" },
            },
            ["Player-1-LOCALE-OTHER"] = {
                displayName = "Bravo-Realm",
                lastSeen = 0,
                defaultProfileID = "p1",
                specProfiles = { [73] = "p2" },
            },
        }
        local localeIdentity = { specID = 73, specName = "Protection", role = "TANK" }
        local env, addonContext, profileTest = loadStatsPro("enUS", {
            statsProDB = root,
            uiParentWidth = 1024,
            uiParentHeight = 768,
            unitGUID = function() return "Player-1-LOCALE" end,
            unitFullName = function() return "Alpha", "Realm" end,
            getSpecialization = function() return 1 end,
            getSpecializationInfo = function()
                return localeIdentity.specID, localeIdentity.specName,
                    nil, nil, localeIdentity.role, 1
            end,
        })
        fireEvent("profiles.ui.locales.activate." .. locale, env, "PLAYER_ENTERING_WORLD")
        addonContext:OpenConfigMenu()
        eq("profiles.ui.locales.minimum_config_height." .. locale,
            env.StatsProConfigFrame:GetHeight(), 600)
        eq("profiles.ui.locales.minimum_manager_width." .. locale,
            env.StatsProProfileManager:GetWidth(), 620)
        local labels = labelsByLocale[locale]
        local shellState = exists("profiles.ui.locales.shell." .. locale,
            profileTest.settingsShellState())
        eq("profiles.ui.locales.tab_count." .. locale, #shellState.tabs, 3)
        for tabIndex, tab in ipairs(shellState.tabs) do
            eq("profiles.ui.locales.tab_width." .. locale .. "." .. tabIndex,
                tab:GetWidth(), 152)
            check("profiles.ui.locales.tab_text." .. locale .. "." .. tabIndex,
                tab.statsProText:GetText() ~= "")
            check("profiles.ui.locales.tab_text_fit." .. locale .. "." .. tabIndex,
                tab.statsProText:GetStringWidth() <= tab:GetWidth() - 24,
                "tab label exceeds its inset text region")
        end
        check("profiles.ui.locales.title_metadata." .. locale,
            string.find(shellState.shell.titleMetadata:GetText(), labels["Settings"], 1, true) ~= nil)
        check("profiles.ui.locales.title_metadata_fit." .. locale,
            shellState.shell.titleMetadata:GetStringWidth() <= 320,
            "title metadata approaches the close button")
        eq("profiles.ui.locales.reset_text." .. locale,
            shellState.shell.resetButton:GetText(), labels["Reset active profile..."])
        eq("profiles.ui.locales.close_text." .. locale,
            shellState.shell.closeButton:GetText(), labels["Close"])
        check("profiles.ui.locales.manage_fit." .. locale,
            env.StatsProManageProfilesButton.statsProText:GetStringWidth()
                <= env.StatsProManageProfilesButton:GetWidth() - 16,
            "Manage label exceeds its inset text region")
        check("profiles.ui.locales.reset_fit." .. locale,
            shellState.shell.resetButton.statsProText:GetStringWidth()
                <= shellState.shell.resetButton:GetWidth() - 16,
            "Reset label exceeds its inset text region")
        check("profiles.ui.locales.close_fit." .. locale,
            shellState.shell.closeButton.statsProText:GetStringWidth()
                <= shellState.shell.closeButton:GetWidth() - 16,
            "Close label exceeds its inset text region")
        local profileLabelFrame = findFontString(
            "profiles.ui.locales.profile_label_frame." .. locale, env,
            function(fontString)
                return fontString:GetParent() == env.StatsProProfileHeader
                    and fontString:GetText() == labels["Profile:"]
            end)
        check("profiles.ui.locales.profile_label_fit." .. locale,
            profileLabelFrame:GetStringWidth() <= profileLabelFrame:GetWidth(),
            "Profile label exceeds its fixed header region")
        for tabIndex, sections in ipairs(shellState.sections) do
            for sectionIndex, section in ipairs(sections) do
                eq("profiles.ui.locales.section_casing." .. locale .. "."
                    .. tabIndex .. "." .. sectionIndex,
                    section.text:GetText(), labels[section.key])
            end
        end
        for _, key in ipairs(requiredOperationKeys) do
            check("profiles.ui.locales.required_key." .. locale .. "." .. key,
                type(labels[key]) == "string" and labels[key] ~= "")
        end
        for key, args in pairs(formatCases) do
            eq("profiles.ui.locales.format_s_count." .. locale .. "." .. key,
                placeholderCount(labels[key], "s"),
                placeholderCount(labelsByLocale.enUS[key], "s"))
            eq("profiles.ui.locales.format_d_count." .. locale .. "." .. key,
                placeholderCount(labels[key], "d"),
                placeholderCount(labelsByLocale.enUS[key], "d"))
            local formatted, result = pcall(string.format, labels[key], unpack(args))
            check("profiles.ui.locales.format_valid." .. locale .. "." .. key,
                formatted, result)
        end
        local state = profileTest.profileUIState()
        eq("profiles.ui.locales.header_label." .. locale,
            state.headerLabel, labels["Profile:"])
        eq("profiles.ui.locales.manage." .. locale,
            env.StatsProManageProfilesButton:GetText(), labels["Manage"])
        eq("profiles.ui.locales.utf8_profile." .. locale,
            state.headerProfile, "Танк 配置")
        eq("profiles.ui.locales.shared_subtitle." .. locale,
            state.headerSubtitle,
            string.format(labels["Shared by %d specs"], 2))
        callScript("profiles.ui.locales.open_manager." .. locale,
            env.StatsProManageProfilesButton, "OnClick")
        state = profileTest.profileUIState()
        eq("profiles.ui.locales.manager_title." .. locale,
            state.managerTitle, labels["Profile Manager"])
        eq("profiles.ui.locales.manager_utf8." .. locale,
            state.detailProfile, "Танк 配置")
        local actionKeys = {
            assign = "Assign to selected context", create = "New from defaults...",
            duplicate = "Duplicate profile...", rename = "Rename profile...",
            copy = "Copy settings to assigned profile...", swap = "Swap assignments...",
            reset = "Reset active profile...", delete = "Delete profile...",
            forget = "Forget character...",
            useAllSpecs = "Use profile for all known specs...",
            independent = "Make shared specs independent...",
            roleTemplate = "Set future role template...",
        }
        for action, key in pairs(actionKeys) do
            eq("profiles.ui.locales.action." .. locale .. "." .. action,
                state.actions[action].text, labels[key])
        end
        eq("profiles.ui.locales.character_summary." .. locale,
            state.selectedCharacterSummary,
            string.format(labels["%s - %d known specs"], "Alpha-Realm", 2))
        local characterSummaryFrame = findFontString(
            "profiles.ui.locales.character_summary_frame." .. locale, env,
            function(fontString)
                return fontString:GetText() == state.selectedCharacterSummary
                    and fontString.wordWrap == false and fontString.maxLines == 1
            end)
        eq("profiles.ui.locales.character_summary_nowrap." .. locale,
            characterSummaryFrame.wordWrap, false)
        eq("profiles.ui.locales.character_summary_one_line." .. locale,
            characterSummaryFrame.maxLines, 1)
        eq("profiles.ui.locales.role_tank." .. locale,
            state.roleTemplateSummary.TANK,
            string.format(labels["Tank: %s"], "Default"))
        eq("profiles.ui.locales.role_healer." .. locale,
            state.roleTemplateSummary.HEALER,
            string.format(labels["Healer: %s"], "Default"))
        eq("profiles.ui.locales.role_damage." .. locale,
            state.roleTemplateSummary.DAMAGER,
            string.format(labels["Damage: %s"], "Default"))
        for role in pairs(state.roleTemplateSummary) do
            local roleSummaryFrame = findFontString(
                "profiles.ui.locales.role_summary_frame." .. locale .. "." .. role,
                env, function(fontString)
                    return fontString:GetText() == state.roleTemplateSummary[role]
                        and fontString.wordWrap == false and fontString.maxLines == 1
                end)
            eq("profiles.ui.locales.role_summary_nowrap." .. locale .. "." .. role,
                roleSummaryFrame.wordWrap, false)
            eq("profiles.ui.locales.role_summary_one_line." .. locale .. "." .. role,
                roleSummaryFrame.maxLines, 1)
        end
        localeIdentity.specID, localeIdentity.specName, localeIdentity.role = 71, "Arms", "DAMAGER"
        fireEvent("profiles.ui.locales.switch." .. locale,
            env, "PLAYER_SPECIALIZATION_CHANGED", "player")
        env.__flushTimers(0)
        state = profileTest.profileUIState()
        eq("profiles.ui.locales.automatic_subtitle." .. locale,
            state.headerSubtitle,
            string.format(labels["Automatic - %s / %s"], "Alpha-Realm", "Arms"))
    end
end

local function makeProfileOpsFixture(options)
    options = options or {}
    local seed = loadStatsPro("enUS")
    fireEvent("profiles.ops.fixture.seed", seed, "PLAYER_ENTERING_WORLD")
    local root = deepCopy(seed.StatsProDB)
    local base = deepCopy(root.profiles.p1.settings)
    root.profiles.p1.name = "Default"
    root.profiles.p2 = { name = "Tank shared", settings = deepCopy(base) }
    root.profiles.p2.settings.showDefensive = true
    root.profiles.p2.settings.scale = 1.1
    root.profiles.p2.settings.xOfs = 21
    root.profiles.p2.settings.yOfs = -22
    root.profiles.p3 = { name = "Damage solo", settings = deepCopy(base) }
    root.profiles.p3.settings.showDefensive = false
    root.profiles.p3.settings.scale = 1.25
    root.profiles.p3.settings.xOfs = 301
    root.profiles.p3.settings.yOfs = -302
    root.profiles.p3.settings.colors.crit = { r = 0.31, g = 0.32, b = 0.33 }
    root.profiles.p4 = { name = "Offline only", settings = deepCopy(base) }
    root.profiles.p4.settings.showTertiary = true
    root.account.defaultProfileID = "p1"
    root.account.nextProfileID = 5
    root.roleTemplates = { TANK = "p2", HEALER = "p1", DAMAGER = "p3" }
    root.characters = {
        ["Player-1-OPS-A"] = {
            displayName = "Alpha-Realm",
            lastSeen = 100,
            defaultProfileID = "p1",
            specProfiles = { [73] = "p2", [71] = "p3" },
        },
        ["Player-1-OPS-B"] = {
            displayName = "Bravo-Realm",
            lastSeen = 90,
            defaultProfileID = "p2",
            specProfiles = { [73] = "p2", [72] = "p4" },
        },
        ["Player-1-OPS-C"] = {
            displayName = "Charlie-Realm",
            lastSeen = 80,
            defaultProfileID = "p1",
            specProfiles = { [65] = "p2" },
        },
    }
    if options.mutateRoot then options.mutateRoot(root) end

    local identity = {
        guid = "Player-1-OPS-A",
        name = "Alpha",
        specID = 73,
        specName = "Protection",
        role = "TANK",
        combat = false,
        combatValue = nil,
    }
    local env, addonContext, test = loadStatsPro("enUS", {
        statsProDB = root,
        uiParentWidth = 1024,
        uiParentHeight = 768,
        unitGUID = function() return identity.guid end,
        unitFullName = function() return identity.name, "Realm" end,
        getServerTime = function() return 100 end,
        getSpecialization = function() return 1 end,
        getSpecializationInfo = function()
            return identity.specID, identity.specName, nil, nil, identity.role, 1
        end,
        statsProArchonTargets = options.statsProArchonTargets,
        swiftStatsDB = options.swiftStatsDB,
        swiftStatsLocalDB = options.swiftStatsLocalDB,
        getCombatRating = options.getCombatRating,
        inCombatLockdown = function()
            if identity.combatValue ~= nil then return identity.combatValue end
            return identity.combat
        end,
        issecretvalue = options.issecretvalue,
    })
    fireEvent("profiles.ops.fixture.activate", env, "PLAYER_ENTERING_WORLD")
    return env, addonContext, test, root, identity
end

do
    local restricted = false
    local targetFixture = makeArchonV2Fixture("2026-05-15")
    setArchonFixtureTargets(targetFixture, "mythicPlus", "WARRIOR", "protection",
        { crit = 1000, haste = 600, mastery = 900, versatility = 500 })
    local env, _, profileTest = makeProfileOpsFixture({
        statsProArchonTargets = targetFixture,
        getCombatRating = function() return restricted and -1 or 700 end,
        issecretvalue = function(value) return value == -1 end,
    })
    local exactMeta = profileTest.buildArchonTargetMeta("crit", 700, env.CR_CRIT_MELEE, 20)
    eq("profiles.ops.archon_cache_invalidation.prime_state",
        exactMeta.comparisonState, "exact")
    eq("profiles.ops.archon_cache_invalidation.prime_current",
        profileTest.archonComparisonCache().entries.crit.current, 700)

    restricted = true
    local ok, reason = profileTest.profileOps.assign("Player-1-OPS-A", 73, "p3")
    eq("profiles.ops.archon_cache_invalidation.assign", ok, true)
    eq("profiles.ops.archon_cache_invalidation.assigned_profile", reason, "p3")
    local restrictedMeta = profileTest.buildArchonTargetMeta(
        "crit", -1, env.CR_CRIT_MELEE, 20)
    eq("profiles.ops.archon_cache_invalidation.restricted_state",
        restrictedMeta.comparisonState, "targetOnly")
    eq("profiles.ops.archon_cache_invalidation.no_stale_current",
        restrictedMeta.current, nil)
end

local function captureRegistryIdentities(root)
    local snapshot = {
        root = root,
        account = root.account,
        profiles = root.profiles,
        roleTemplates = root.roleTemplates,
        characters = root.characters,
        profileEntries = {},
        profileSettings = {},
        profileColors = {},
        characterEntries = {},
        characterSpecs = {},
    }
    for profileID, profile in pairs(root.profiles or {}) do
        snapshot.profileEntries[profileID] = profile
        snapshot.profileSettings[profileID] = profile.settings
        snapshot.profileColors[profileID] = profile.settings and profile.settings.colors
    end
    for guid, character in pairs(root.characters or {}) do
        snapshot.characterEntries[guid] = character
        snapshot.characterSpecs[guid] = character.specProfiles
    end
    return snapshot
end

local function assertRegistryIdentities(name, root, snapshot)
    eq(name .. ".root", rawequal(root, snapshot.root), true)
    eq(name .. ".account", rawequal(root.account, snapshot.account), true)
    eq(name .. ".profiles", rawequal(root.profiles, snapshot.profiles), true)
    eq(name .. ".roles", rawequal(root.roleTemplates, snapshot.roleTemplates), true)
    eq(name .. ".characters", rawequal(root.characters, snapshot.characters), true)
    for profileID, profile in pairs(snapshot.profileEntries) do
        eq(name .. ".profile." .. profileID,
            rawequal(root.profiles[profileID], profile), true)
        eq(name .. ".settings." .. profileID,
            rawequal(root.profiles[profileID].settings, snapshot.profileSettings[profileID]), true)
        eq(name .. ".colors." .. profileID,
            rawequal(root.profiles[profileID].settings.colors, snapshot.profileColors[profileID]), true)
    end
    for guid, character in pairs(snapshot.characterEntries) do
        eq(name .. ".character." .. guid,
            rawequal(root.characters[guid], character), true)
        eq(name .. ".specs." .. guid,
            rawequal(root.characters[guid].specProfiles, snapshot.characterSpecs[guid]), true)
    end
end

do
    local env, addonContext, test, root = makeProfileOpsFixture()
    addonContext:OpenConfigMenu()
    local footerReset = findFrame("profiles.compat.reset.footer_button", env, function(frame)
        return frame:GetParent() == env.StatsProConfigFrame
            and frame:GetName() == nil
            and frame:GetText() == "Reset active profile..."
            and type(frame.scripts.OnClick) == "function"
    end)
    local before = deepCopy(root)
    callScript("profiles.compat.reset.footer_request", footerReset, "OnClick")
    eq("profiles.compat.reset.footer_popup", env.__lastStaticPopup.key,
        "STATSPRO_RESET_ACTIVE_PROFILE")
    local labels = test.registrySnapshot().labelsByLocale.enUS
    eq("profiles.compat.reset.footer_shared_warning",
        env.__lastStaticPopup.definition.text,
        string.format(
            labels["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."],
            "Tank shared", 3, 2))
    assertDeepEqual("profiles.compat.reset.footer_request_zero_writes", root, before)
    env.__cancelStaticPopup()
    assertDeepEqual("profiles.compat.reset.footer_cancel_zero_writes", root, before)
end

do
    local source = {
        fontSize = 19,
        point = "TOPLEFT", relativePoint = "TOPLEFT", xOfs = 123, yOfs = -234,
        colors = { crit = { r = 0.41, g = 0.42, b = 0.43 } },
    }
    local env, _, test, root = makeProfileOpsFixture({ swiftStatsDB = source })
    local oldActive = test.profileState()
    local oldProfileID = oldActive.profileID
    local oldProfileRef = root.profiles[oldProfileID]
    local oldSettingsRef = oldProfileRef.settings
    local oldSettings = deepCopy(oldSettingsRef)
    local oldRolesRef = root.roleTemplates
    local oldRoles = deepCopy(root.roleTemplates)
    local oldCharacters = deepCopy(root.characters)
    local oldAccountDefault = root.account.defaultProfileID
    local oldLocale = root.account.forceLocale
    local oldInterval = root.account.updateInterval
    local nextBefore = root.account.nextProfileID
    local runtimeBefore = test.profileRuntimeState()
    local requestBefore = deepCopy(root)
    local requestIdentities = captureRegistryIdentities(root)

    slash("profiles.compat.import.cancel.request", env, "import")
    eq("profiles.compat.import.cancel.popup", env.__lastStaticPopup.key,
        "STATSPRO_IMPORT_SWIFTSTATS")
    eq("profiles.compat.import.cancel.pending",
        test.destructivePromptState().importPending, true)
    assertDeepEqual("profiles.compat.import.cancel.request_zero_writes", root, requestBefore)
    assertRegistryIdentities(
        "profiles.compat.import.cancel.request_identities", root, requestIdentities)
    env.__cancelStaticPopup()
    eq("profiles.compat.import.cancel.pending_cleared",
        test.destructivePromptState().importPending, false)
    assertDeepEqual("profiles.compat.import.cancel.zero_writes", root, requestBefore)
    assertRegistryIdentities(
        "profiles.compat.import.cancel.identities", root, requestIdentities)

    slash("profiles.compat.import.accept.request", env, "import")
    source.fontSize = 8
    source.xOfs = 999
    source.colors.crit.r = 0.99
    env.__acceptStaticPopup()
    local imported = test.profileState()
    eq("profiles.compat.import.accept.id", imported.profileID, "p5")
    eq("profiles.compat.import.accept.name", root.profiles.p5.name, "SwiftStats Import")
    eq("profiles.compat.import.accept.next", root.account.nextProfileID, nextBefore + 1)
    eq("profiles.compat.import.accept.current_assignment",
        root.characters["Player-1-OPS-A"].specProfiles[73], "p5")
    eq("profiles.compat.import.accept.current_other_spec",
        root.characters["Player-1-OPS-A"].specProfiles[71],
        oldCharacters["Player-1-OPS-A"].specProfiles[71])
    eq("profiles.compat.import.accept.current_default",
        root.characters["Player-1-OPS-A"].defaultProfileID,
        oldCharacters["Player-1-OPS-A"].defaultProfileID)
    assertDeepEqual("profiles.compat.import.accept.other_character_b",
        root.characters["Player-1-OPS-B"], oldCharacters["Player-1-OPS-B"])
    assertDeepEqual("profiles.compat.import.accept.other_character_c",
        root.characters["Player-1-OPS-C"], oldCharacters["Player-1-OPS-C"])
    eq("profiles.compat.import.accept.old_profile_identity",
        rawequal(root.profiles[oldProfileID], oldProfileRef), true)
    eq("profiles.compat.import.accept.old_settings_identity",
        rawequal(root.profiles[oldProfileID].settings, oldSettingsRef), true)
    assertDeepEqual("profiles.compat.import.accept.old_profile_unchanged",
        root.profiles[oldProfileID].settings, oldSettings)
    eq("profiles.compat.import.accept.roles_identity",
        rawequal(root.roleTemplates, oldRolesRef), true)
    assertDeepEqual("profiles.compat.import.accept.roles", root.roleTemplates, oldRoles)
    eq("profiles.compat.import.accept.account_default",
        root.account.defaultProfileID, oldAccountDefault)
    eq("profiles.compat.import.accept.account_locale", root.account.forceLocale, oldLocale)
    near("profiles.compat.import.accept.account_interval",
        root.account.updateInterval, oldInterval)
    eq("profiles.compat.import.accept.snapshot_font", imported.settings.fontSize, 19)
    eq("profiles.compat.import.accept.snapshot_x", imported.settings.xOfs, 123)
    assertColor("profiles.compat.import.accept.snapshot_color",
        imported.settings.colors.crit, 0.41, 0.42, 0.43)
    assertNoSharedTables("profiles.compat.import.accept.source_detached",
        source, imported.settings)
    assertNoSharedTables("profiles.compat.import.accept.old_profile_detached",
        oldSettingsRef, imported.settings)
    eq("profiles.compat.import.accept.no_reload", env.__reloadUICalls, 0)
    eq("profiles.compat.import.accept.apply_count",
        test.profileRuntimeState().applyCount, runtimeBefore.applyCount + 1)
    eq("profiles.compat.import.accept.commit_count",
        test.profileRuntimeState().structuralCommitCount,
        runtimeBefore.structuralCommitCount + 1)
    eq("profiles.compat.import.accept.main_position",
        env.StatsProFrame.points[1][1], "TOPLEFT")
    eq("profiles.compat.import.accept.main_position_x",
        env.StatsProFrame.points[1][4], 123)

    source.fontSize = 21
    slash("profiles.compat.import.unique.request", env, "import")
    env.__acceptStaticPopup()
    eq("profiles.compat.import.unique.id", test.profileState().profileID, "p6")
    eq("profiles.compat.import.unique.name", root.profiles.p6.name, "SwiftStats Import 2")
    eq("profiles.compat.import.unique.previous_kept", root.profiles.p5.settings.fontSize, 19)
    eq("profiles.compat.import.unique.current_assignment",
        root.characters["Player-1-OPS-A"].specProfiles[73], "p6")
end

for _, stage in ipairs({ "validate", "commit", "apply" }) do
    local env, _, test, root = makeProfileOpsFixture()
    local settings = test.copyDefaults()
    settings.fontSize = 22
    settings.point = "TOPLEFT"
    settings.relativePoint = "TOPLEFT"
    settings.xOfs = 222
    settings.yOfs = -223
    settings.colors.crit = { r = 0.8, g = 0.7, b = 0.6 }
    local before = deepCopy(root)
    local identities = captureRegistryIdentities(root)
    local runtime = test.profileRuntimeState()
    local point = deepCopy(env.StatsProFrame.points[1])
    test.profileOps.setFailureStage(stage)
    local ok, reason = test.profileOps.importAndAssign(settings)
    eq("profiles.compat.import.failure." .. stage .. ".ok", ok, false)
    eq("profiles.compat.import.failure." .. stage .. ".reason",
        reason, stage .. "-failed")
    assertDeepEqual("profiles.compat.import.failure." .. stage .. ".root", root, before)
    assertRegistryIdentities(
        "profiles.compat.import.failure." .. stage .. ".identities", root, identities)
    eq("profiles.compat.import.failure." .. stage .. ".active",
        test.profileState().profileID, "p2")
    eq("profiles.compat.import.failure." .. stage .. ".guid",
        test.profileRuntimeState().activeGUID, runtime.activeGUID)
    eq("profiles.compat.import.failure." .. stage .. ".spec",
        test.profileRuntimeState().activeSpecID, runtime.activeSpecID)
    assertDeepEqual("profiles.compat.import.failure." .. stage .. ".live_position",
        env.StatsProFrame.points[1], point)
    eq("profiles.compat.import.failure." .. stage .. ".not_busy",
        test.profileOps.state().inProgress, false)
end

do
    local _, _, test, root = makeProfileOpsFixture()
    root.account.nextProfileID = 99999999999999
    local before = deepCopy(root)
    local identities = captureRegistryIdentities(root)
    local ok, reason = test.profileOps.importAndAssign(test.copyDefaults())
    eq("profiles.compat.import.id_exhausted.ok", ok, false)
    eq("profiles.compat.import.id_exhausted.reason", reason, "id-exhausted")
    assertDeepEqual("profiles.compat.import.id_exhausted.root", root, before)
    assertRegistryIdentities(
        "profiles.compat.import.id_exhausted.identities", root, identities)
end

do
    local source = { fontSize = 19 }
    local env, _, test, root = makeProfileOpsFixture({ swiftStatsDB = source })
    slash("profiles.compat.import.stale.request", env, "import")
    local staleAccept = env.__lastStaticPopup.definition.OnAccept
    local ok = test.profileOps.setRoleTemplate("HEALER", "p4")
    eq("profiles.compat.import.stale.setup", ok, true)
    local afterSetup = deepCopy(root)
    eq("profiles.compat.import.stale.pending_cleared",
        test.destructivePromptState().importPending, false)
    staleAccept()
    assertDeepEqual("profiles.compat.import.stale.callback_zero_writes", root, afterSetup)
    eq("profiles.compat.import.stale.no_new_profile", root.profiles.p5, nil)
end

for _, stage in ipairs({ "validate", "commit", "apply" }) do
    local env, _, test, root = makeProfileOpsFixture()
    local before = deepCopy(root)
    local identities = captureRegistryIdentities(root)
    local point = deepCopy(env.StatsProFrame.points[1])
    test.profileOps.setFailureStage(stage)
    local ok, reason = test.profileOps.resetCurrent("p2")
    eq("profiles.compat.reset.failure." .. stage .. ".ok", ok, false)
    eq("profiles.compat.reset.failure." .. stage .. ".reason",
        reason, stage .. "-failed")
    assertDeepEqual("profiles.compat.reset.failure." .. stage .. ".root", root, before)
    assertRegistryIdentities(
        "profiles.compat.reset.failure." .. stage .. ".identities", root, identities)
    eq("profiles.compat.reset.failure." .. stage .. ".active",
        test.profileState().profileID, "p2")
    assertDeepEqual("profiles.compat.reset.failure." .. stage .. ".live_position",
        env.StatsProFrame.points[1], point)
end

do
    local swiftSource = { fontSize = 18, colors = { crit = { r = 0.2, g = 0.3, b = 0.4 } } }
    local env, _, test, root = makeProfileOpsFixture({ swiftStatsDB = swiftSource })
    root.shadowSetting = { child = { keepUntilWipe = true } }
    root.fontSize = 37
    local before = deepCopy(root)
    local identities = captureRegistryIdentities(root)
    slash("profiles.compat.wipe.cancel.request", env, "wipe")
    eq("profiles.compat.wipe.cancel.popup", env.__lastStaticPopup.key,
        "STATSPRO_WIPE_ALL_DATA")
    eq("profiles.compat.wipe.cancel.pending",
        test.destructivePromptState().wipePending, true)
    assertDeepEqual("profiles.compat.wipe.cancel.request_zero_writes", root, before)
    env.__cancelStaticPopup()
    assertDeepEqual("profiles.compat.wipe.cancel.zero_writes", root, before)
    assertRegistryIdentities("profiles.compat.wipe.cancel.identities", root, identities)

    slash("profiles.compat.wipe.accept.request", env, "reset all")
    env.__acceptStaticPopup()
    local freshRoot = env.StatsProDB
    local freshState = test.profileState()
    eq("profiles.compat.wipe.accept.root_replaced", rawequal(freshRoot, root), false)
    eq("profiles.compat.wipe.accept.current_version",
        freshRoot.dbVersion, test.currentDBVersion())
    eq("profiles.compat.wipe.accept.account_default", freshRoot.account.defaultProfileID, "p1")
    eq("profiles.compat.wipe.accept.next", freshRoot.account.nextProfileID, 2)
    eq("profiles.compat.wipe.accept.locale", freshRoot.account.forceLocale, "auto")
    near("profiles.compat.wipe.accept.interval", freshRoot.account.updateInterval, 0.5)
    eq("profiles.compat.wipe.accept.only_p1", next(freshRoot.profiles, "p1"), nil)
    eq("profiles.compat.wipe.accept.active", freshState.profileID, "p1")
    eq("profiles.compat.wipe.accept.current_assignment",
        freshRoot.characters["Player-1-OPS-A"].specProfiles[73], "p1")
    eq("profiles.compat.wipe.accept.character_default",
        freshRoot.characters["Player-1-OPS-A"].defaultProfileID, "p1")
    eq("profiles.compat.wipe.accept.roles_tank", freshRoot.roleTemplates.TANK, "p1")
    eq("profiles.compat.wipe.accept.roles_healer", freshRoot.roleTemplates.HEALER, "p1")
    eq("profiles.compat.wipe.accept.roles_damage", freshRoot.roleTemplates.DAMAGER, "p1")
    eq("profiles.compat.wipe.accept.shadow_removed", freshRoot.shadowSetting, nil)
    eq("profiles.compat.wipe.accept.flat_shadow_removed", freshRoot.fontSize, nil)
    near("profiles.compat.wipe.accept.default_scale", freshState.settings.scale, 1)
    eq("profiles.compat.wipe.accept.default_point", freshState.settings.point, "CENTER")
    eq("profiles.compat.wipe.accept.live_point", env.StatsProFrame.points[1][1], "CENTER")
    eq("profiles.compat.wipe.accept.source_untouched", swiftSource.fontSize, 18)
    assertColor("profiles.compat.wipe.accept.source_color_untouched",
        swiftSource.colors.crit, 0.2, 0.3, 0.4)
end

for _, stage in ipairs({ "validate", "commit", "apply" }) do
    local env, _, test, root = makeProfileOpsFixture()
    root.shadowSetting = { child = { preserve = true } }
    local before = deepCopy(root)
    local identities = captureRegistryIdentities(root)
    local point = deepCopy(env.StatsProFrame.points[1])
    test.profileOps.setFailureStage(stage)
    local ok, reason = test.profileOps.fullWipe()
    eq("profiles.compat.wipe.failure." .. stage .. ".ok", ok, false)
    eq("profiles.compat.wipe.failure." .. stage .. ".reason",
        reason, stage .. "-failed")
    eq("profiles.compat.wipe.failure." .. stage .. ".root_pointer",
        rawequal(env.StatsProDB, root), true)
    assertDeepEqual("profiles.compat.wipe.failure." .. stage .. ".root", root, before)
    assertRegistryIdentities(
        "profiles.compat.wipe.failure." .. stage .. ".identities", root, identities)
    eq("profiles.compat.wipe.failure." .. stage .. ".active",
        test.profileState().profileID, "p2")
    assertDeepEqual("profiles.compat.wipe.failure." .. stage .. ".live_position",
        env.StatsProFrame.points[1], point)
end

do
    local env, _, test, root = makeProfileOpsFixture()
    root.shadowSetting = { child = { preserve = true } }
    local before = deepCopy(root)
    local identities = captureRegistryIdentities(root)
    local oldSetPoint = env.StatsProFrame.SetPoint
    rawset(env.StatsProFrame, "SetPoint", function()
        error("injected full-wipe target and rollback apply failure")
    end)
    local ok, reason = test.profileOps.fullWipe()
    eq("profiles.compat.wipe.rollback_apply.ok", ok, false)
    eq("profiles.compat.wipe.rollback_apply.reason", reason, "rollback-apply-failed")
    eq("profiles.compat.wipe.rollback_apply.root_pointer",
        rawequal(env.StatsProDB, root), true)
    assertDeepEqual("profiles.compat.wipe.rollback_apply.root", root, before)
    assertRegistryIdentities(
        "profiles.compat.wipe.rollback_apply.identities", root, identities)
    eq("profiles.compat.wipe.rollback_apply.active", test.profileState().profileID, "p2")
    eq("profiles.compat.wipe.rollback_apply.force",
        test.profileRuntimeState().forceReapply, true)
    eq("profiles.compat.wipe.rollback_apply.pending",
        test.profileRuntimeState().pendingResolution, true)
    rawset(env.StatsProFrame, "SetPoint", oldSetPoint)
    env.__flushTimers(0)
    eq("profiles.compat.wipe.rollback_apply.recovered_force",
        test.profileRuntimeState().forceReapply, false)
    eq("profiles.compat.wipe.rollback_apply.recovered_pending",
        test.profileRuntimeState().pendingResolution, false)
    eq("profiles.compat.wipe.rollback_apply.recovered_active",
        test.profileState().profileID, "p2")
end

do
    local _, _, test, root = makeProfileOpsFixture()
    local ops = test.profileOps
    local accountRef, profilesRef, charactersRef = root.account, root.profiles, root.characters
    local oldRoles = root.roleTemplates
    local assignmentsBefore = deepCopy(root.characters)
    local payloadsBefore = deepCopy(root.profiles)
    local applyBefore = test.profileRuntimeState().applyCount
    local ok, result = ops.setRoleTemplate("HEALER", "p4")
    eq("profiles.automation.roles.set.ok", ok, true)
    eq("profiles.automation.roles.set.role", result.role, "HEALER")
    eq("profiles.automation.roles.set.profile", result.profileID, "p4")
    eq("profiles.automation.roles.set.value", root.roleTemplates.HEALER, "p4")
    eq("profiles.automation.roles.set.other_tank", root.roleTemplates.TANK, oldRoles.TANK)
    eq("profiles.automation.roles.set.other_damage", root.roleTemplates.DAMAGER, oldRoles.DAMAGER)
    eq("profiles.automation.roles.set.roles_replaced", rawequal(root.roleTemplates, oldRoles), false)
    eq("profiles.automation.roles.set.account_identity", rawequal(root.account, accountRef), true)
    eq("profiles.automation.roles.set.profiles_identity", rawequal(root.profiles, profilesRef), true)
    eq("profiles.automation.roles.set.characters_identity", rawequal(root.characters, charactersRef), true)
    assertDeepEqual("profiles.automation.roles.set.assignments", root.characters, assignmentsBefore)
    assertDeepEqual("profiles.automation.roles.set.payloads", root.profiles, payloadsBefore)
    eq("profiles.automation.roles.set.no_apply", test.profileRuntimeState().applyCount, applyBefore)

    for _, case in ipairs({
        { role = "TANK", profileID = "p3" },
        { role = "DAMAGER", profileID = "p4" },
    }) do
        local beforeRoles = deepCopy(root.roleTemplates)
        local beforeTable = root.roleTemplates
        ok, result = ops.setRoleTemplate(case.role, case.profileID)
        eq("profiles.automation.roles.set_each." .. case.role .. ".ok", ok, true)
        eq("profiles.automation.roles.set_each." .. case.role .. ".value",
            root.roleTemplates[case.role], case.profileID)
        eq("profiles.automation.roles.set_each." .. case.role .. ".table_replaced",
            rawequal(root.roleTemplates, beforeTable), false)
        for _, otherRole in ipairs({ "TANK", "HEALER", "DAMAGER" }) do
            if otherRole ~= case.role then
                eq("profiles.automation.roles.set_each." .. case.role .. ".preserves_" .. otherRole,
                    root.roleTemplates[otherRole], beforeRoles[otherRole])
            end
        end
    end

    local beforeNoChange = deepCopy(root)
    ok, result = ops.setRoleTemplate("HEALER", "p4")
    eq("profiles.automation.roles.same.rejected", ok, false)
    eq("profiles.automation.roles.same.reason", result, "no-change")
    assertDeepEqual("profiles.automation.roles.same.no_writes", root, beforeNoChange)
    local beforeInvalid = deepCopy(root)
    ok, result = ops.setRoleTemplate("INVALID", "p1")
    eq("profiles.automation.roles.invalid_role.rejected", ok, false)
    eq("profiles.automation.roles.invalid_role.reason", result, "invalid-role")
    ok, result = ops.setRoleTemplate("TANK", "missing")
    eq("profiles.automation.roles.invalid_profile.rejected", ok, false)
    eq("profiles.automation.roles.invalid_profile.reason", result, "missing-profile")
    assertDeepEqual("profiles.automation.roles.invalid.no_writes", root, beforeInvalid)
end

do
    local env, _, test, root, identity = makeProfileOpsFixture()
    local ok = test.profileOps.setRoleTemplate("HEALER", "p3")
    eq("profiles.automation.roles.all_roles.set_healer", ok, true)
    ok = test.profileOps.setRoleTemplate("DAMAGER", "p4")
    eq("profiles.automation.roles.all_roles.set_damage", ok, true)
    local sourceByRole = { TANK = "p2", HEALER = "p3", DAMAGER = "p4" }
    local sourceSnapshots = {
        TANK = deepCopy(root.profiles.p2.settings),
        HEALER = deepCopy(root.profiles.p3.settings),
        DAMAGER = deepCopy(root.profiles.p4.settings),
    }
    identity.guid, identity.name = "Player-1-OPS-NEW", "Newcomer"
    local contexts = {
        { specID = 73, specName = "Protection", role = "TANK" },
        { specID = 65, specName = "Holy", role = "HEALER" },
        { specID = 71, specName = "Arms", role = "DAMAGER" },
    }
    local cloneIDs = {}
    for index, context in ipairs(contexts) do
        identity.specID, identity.specName, identity.role =
            context.specID, context.specName, context.role
        if index == 1 then
            fireEvent("profiles.automation.roles.all_roles.first",
                env, "PLAYER_ENTERING_WORLD")
            flushTimers("profiles.automation.roles.all_roles.first_flush", env, 0, 1)
        else
            fireEvent("profiles.automation.roles.all_roles.switch." .. context.role,
                env, "PLAYER_SPECIALIZATION_CHANGED", "player")
            flushTimers("profiles.automation.roles.all_roles.flush." .. context.role,
                env, 0, 1)
        end
        local cloneID = root.characters[identity.guid].specProfiles[context.specID]
        cloneIDs[context.role] = cloneID
        check("profiles.automation.roles.all_roles.allocated." .. context.role,
            type(cloneID) == "string" and cloneID ~= sourceByRole[context.role], cloneID)
        assertDeepEqual("profiles.automation.roles.all_roles.payload." .. context.role,
            root.profiles[cloneID].settings, sourceSnapshots[context.role])
        assertNoSharedTables("profiles.automation.roles.all_roles.source_isolation." .. context.role,
            root.profiles[sourceByRole[context.role]].settings,
            root.profiles[cloneID].settings)
    end
    check("profiles.automation.roles.all_roles.distinct_tank_healer",
        cloneIDs.TANK ~= cloneIDs.HEALER)
    check("profiles.automation.roles.all_roles.distinct_healer_damage",
        cloneIDs.HEALER ~= cloneIDs.DAMAGER)
    assertNoSharedTables("profiles.automation.roles.all_roles.clone_isolation",
        root.profiles[cloneIDs.TANK].settings, root.profiles[cloneIDs.HEALER].settings)
    root.profiles.p2.settings.showDefensive = false
    eq("profiles.automation.roles.all_roles.template_change_not_retroactive",
        root.profiles[cloneIDs.TANK].settings.showDefensive,
        sourceSnapshots.TANK.showDefensive)
end

do
    local env, _, test, root, identity = makeProfileOpsFixture()
    local ops = test.profileOps
    local ok = ops.setRoleTemplate("DAMAGER", "p4")
    eq("profiles.automation.roles.future.set_first", ok, true)
    local sourceBefore = deepCopy(root.profiles.p4.settings)
    identity.specID, identity.specName, identity.role = 72, "Fury", "DAMAGER"
    fireEvent("profiles.automation.roles.future.first_event",
        env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    flushTimers("profiles.automation.roles.future.first_flush", env, 0, 1)
    local firstProfileID = root.characters[identity.guid].specProfiles[72]
    check("profiles.automation.roles.future.first_allocated",
        type(firstProfileID) == "string" and firstProfileID ~= "p4", firstProfileID)
    assertDeepEqual("profiles.automation.roles.future.first_payload",
        root.profiles[firstProfileID].settings, sourceBefore)
    assertNoSharedTables("profiles.automation.roles.future.first_isolated",
        root.profiles.p4.settings, root.profiles[firstProfileID].settings)

    root.profiles.p4.settings.showTertiary = false
    eq("profiles.automation.roles.future.source_change_not_retroactive",
        root.profiles[firstProfileID].settings.showTertiary, sourceBefore.showTertiary)
    root.profiles[firstProfileID].settings.scale = 1.77
    eq("profiles.automation.roles.future.clone_change_not_source",
        root.profiles.p4.settings.scale, sourceBefore.scale)

    local firstMapping = root.characters[identity.guid].specProfiles[72]
    ok = ops.setRoleTemplate("DAMAGER", "p1")
    eq("profiles.automation.roles.future.switch_template", ok, true)
    eq("profiles.automation.roles.future.existing_mapping", root.characters[identity.guid].specProfiles[72], firstMapping)
    identity.specID, identity.specName = 70, "Retribution"
    fireEvent("profiles.automation.roles.future.second_event",
        env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    flushTimers("profiles.automation.roles.future.second_flush", env, 0, 1)
    local secondProfileID = root.characters[identity.guid].specProfiles[70]
    assertDeepEqual("profiles.automation.roles.future.second_payload",
        root.profiles[secondProfileID].settings, root.profiles.p1.settings)
    assertNoSharedTables("profiles.automation.roles.future.second_isolated",
        root.profiles.p1.settings, root.profiles[secondProfileID].settings)

    identity.specID, identity.specName = 69, "Second Damage"
    fireEvent("profiles.automation.roles.future.third_event",
        env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    flushTimers("profiles.automation.roles.future.third_flush", env, 0, 1)
    local thirdProfileID = root.characters[identity.guid].specProfiles[69]
    check("profiles.automation.roles.future.distinct_ids",
        secondProfileID ~= thirdProfileID, thirdProfileID)
    assertNoSharedTables("profiles.automation.roles.future.clone_pair_isolated",
        root.profiles[secondProfileID].settings, root.profiles[thirdProfileID].settings)
end

do
    local _, _, test, root = makeProfileOpsFixture()
    local ops = test.profileOps
    local accountRef, profilesRef, rolesRef = root.account, root.profiles, root.roleTemplates
    local alphaRef = root.characters["Player-1-OPS-A"]
    local bravoRef = root.characters["Player-1-OPS-B"]
    local charlieRef = root.characters["Player-1-OPS-C"]
    local profileIdentities = captureRegistryIdentities(root)
    local defaultBefore = alphaRef.defaultProfileID
    local nextBefore = root.account.nextProfileID
    local applyBefore = test.profileRuntimeState().applyCount
    local ok, result = ops.useProfileForKnownSpecs("Player-1-OPS-A", "p4")
    eq("profiles.automation.share.current.ok", ok, true)
    eq("profiles.automation.share.current.changed", result.changedCount, 2)
    eq("profiles.automation.share.current.spec_73", root.characters["Player-1-OPS-A"].specProfiles[73], "p4")
    eq("profiles.automation.share.current.spec_71", root.characters["Player-1-OPS-A"].specProfiles[71], "p4")
    eq("profiles.automation.share.current.default_unchanged", root.characters["Player-1-OPS-A"].defaultProfileID, defaultBefore)
    eq("profiles.automation.share.current.account_identity", rawequal(root.account, accountRef), true)
    eq("profiles.automation.share.current.profiles_identity", rawequal(root.profiles, profilesRef), true)
    eq("profiles.automation.share.current.roles_identity", rawequal(root.roleTemplates, rolesRef), true)
    eq("profiles.automation.share.current.alpha_replaced", rawequal(root.characters["Player-1-OPS-A"], alphaRef), false)
    eq("profiles.automation.share.current.bravo_unchanged", rawequal(root.characters["Player-1-OPS-B"], bravoRef), true)
    eq("profiles.automation.share.current.charlie_unchanged", rawequal(root.characters["Player-1-OPS-C"], charlieRef), true)
    eq("profiles.automation.share.current.no_ids", root.account.nextProfileID, nextBefore)
    eq("profiles.automation.share.current.active_profile", test.profileState().profileID, "p4")
    eq("profiles.automation.share.current.one_apply", test.profileRuntimeState().applyCount, applyBefore + 1)
    for profileID, profileRef in pairs(profileIdentities.profileEntries) do
        eq("profiles.automation.share.current.profile_identity." .. profileID,
            rawequal(root.profiles[profileID], profileRef), true)
    end

    local beforeSame = deepCopy(root)
    ok, result = ops.useProfileForKnownSpecs("Player-1-OPS-A", "p4")
    eq("profiles.automation.share.same.rejected", ok, false)
    eq("profiles.automation.share.same.reason", result, "no-change")
    assertDeepEqual("profiles.automation.share.same.no_writes", root, beforeSame)

    applyBefore = test.profileRuntimeState().applyCount
    ok, result = ops.useProfileForKnownSpecs("Player-1-OPS-B", "p3")
    eq("profiles.automation.share.offline.ok", ok, true)
    eq("profiles.automation.share.offline.changed", result.changedCount, 2)
    eq("profiles.automation.share.offline.no_apply", test.profileRuntimeState().applyCount, applyBefore)
    local beforeInvalid = deepCopy(root)
    ok, result = ops.useProfileForKnownSpecs("missing", "p1")
    eq("profiles.automation.share.missing_character.rejected", ok, false)
    eq("profiles.automation.share.missing_character.reason", result, "missing-context")
    ok, result = ops.useProfileForKnownSpecs("Player-1-OPS-A", "missing")
    eq("profiles.automation.share.missing_profile.rejected", ok, false)
    eq("profiles.automation.share.missing_profile.reason", result, "missing-profile")
    assertDeepEqual("profiles.automation.share.invalid.no_writes", root, beforeInvalid)
end

do
    local _, _, test, root = makeProfileOpsFixture({
        mutateRoot = function(candidate)
            candidate.characters["Player-1-OPS-A"].specProfiles[72] = "p2"
            candidate.profiles.p2.settings.unknownAutomation = {
                role = "tank", nested = { token = 73 }, explicitFalse = false,
            }
        end,
    })
    local ops = test.profileOps
    local sourceRef = root.profiles.p2
    local sourceSettingsRef = sourceRef.settings
    local sourceBefore = deepCopy(sourceSettingsRef)
    local p3Ref = root.profiles.p3
    local defaultBefore = root.characters["Player-1-OPS-A"].defaultProfileID
    local applyBefore = test.profileRuntimeState().applyCount
    local ok, result = ops.makeKnownSpecsIndependent("Player-1-OPS-A")
    eq("profiles.automation.independent.ok", ok, true)
    eq("profiles.automation.independent.changed", result.changedCount, 2)
    eq("profiles.automation.independent.spec_72_id", result.assignments[72], "p5")
    eq("profiles.automation.independent.spec_73_id", result.assignments[73], "p6")
    eq("profiles.automation.independent.unique",
        result.assignments[72] ~= result.assignments[73], true)
    eq("profiles.automation.independent.unique_spec_preserved",
        root.characters["Player-1-OPS-A"].specProfiles[71], "p3")
    eq("profiles.automation.independent.default_preserved",
        root.characters["Player-1-OPS-A"].defaultProfileID, defaultBefore)
    eq("profiles.automation.independent.next_id", root.account.nextProfileID, 7)
    eq("profiles.automation.independent.source_identity", rawequal(root.profiles.p2, sourceRef), true)
    eq("profiles.automation.independent.source_settings_identity",
        rawequal(root.profiles.p2.settings, sourceSettingsRef), true)
    eq("profiles.automation.independent.unique_profile_identity", rawequal(root.profiles.p3, p3Ref), true)
    for _, specID in ipairs({ 72, 73 }) do
        local profileID = result.assignments[specID]
        assertDeepEqual("profiles.automation.independent.payload." .. specID,
            root.profiles[profileID].settings, sourceBefore)
        assertNoSharedTables("profiles.automation.independent.source_isolation." .. specID,
            sourceSettingsRef, root.profiles[profileID].settings)
        eq("profiles.automation.independent.single_spec_ref." .. specID,
            ops.countReferences(root, profileID).specs, 1)
    end
    assertNoSharedTables("profiles.automation.independent.sibling_isolation",
        root.profiles.p5.settings, root.profiles.p6.settings)
    eq("profiles.automation.independent.active_profile", test.profileState().profileID, "p6")
    eq("profiles.automation.independent.one_apply", test.profileRuntimeState().applyCount, applyBefore + 1)

    ok = ops.useProfileForKnownSpecs("Player-1-OPS-A", "p2")
    eq("profiles.automation.round_trip.share", ok, true)
    ok = ops.assign("Player-1-OPS-A", 71, "p3")
    eq("profiles.automation.round_trip.restore_damage", ok, true)
    eq("profiles.automation.round_trip.spec_71", root.characters["Player-1-OPS-A"].specProfiles[71], "p3")
    eq("profiles.automation.round_trip.spec_72", root.characters["Player-1-OPS-A"].specProfiles[72], "p2")
    eq("profiles.automation.round_trip.spec_73", root.characters["Player-1-OPS-A"].specProfiles[73], "p2")
    assertDeepEqual("profiles.automation.round_trip.source_preserved", root.profiles.p2.settings, sourceBefore)
    eq("profiles.automation.round_trip.monotonic_ids", root.account.nextProfileID, 7)
end

do
    local _, _, noOpTest, noOpRoot = makeProfileOpsFixture({
        mutateRoot = function(candidate)
            candidate.profiles.p5 = {
                name = "Bravo tank", settings = deepCopy(candidate.profiles.p1.settings),
            }
            candidate.profiles.p6 = {
                name = "Charlie healer", settings = deepCopy(candidate.profiles.p1.settings),
            }
            candidate.account.nextProfileID = 7
            candidate.characters["Player-1-OPS-B"].specProfiles[73] = "p5"
            candidate.characters["Player-1-OPS-C"].specProfiles[65] = "p6"
        end,
    })
    local beforeNoOp = deepCopy(noOpRoot)
    local ok, reason = noOpTest.profileOps.makeKnownSpecsIndependent("Player-1-OPS-A")
    eq("profiles.automation.independent.noop.rejected", ok, false)
    eq("profiles.automation.independent.noop.reason", reason, "no-change")
    assertDeepEqual("profiles.automation.independent.noop.no_writes", noOpRoot, beforeNoOp)

    local _, _, exhaustedTest, exhaustedRoot = makeProfileOpsFixture({
        mutateRoot = function(candidate)
            candidate.characters["Player-1-OPS-A"].specProfiles[72] = "p2"
            candidate.account.nextProfileID = 99999999999998
        end,
    })
    local beforeExhausted = deepCopy(exhaustedRoot)
    local exhaustedIdentities = captureRegistryIdentities(exhaustedRoot)
    ok, reason = exhaustedTest.profileOps.makeKnownSpecsIndependent("Player-1-OPS-A")
    eq("profiles.automation.independent.exhausted.rejected", ok, false)
    eq("profiles.automation.independent.exhausted.reason", reason, "id-exhausted")
    assertDeepEqual("profiles.automation.independent.exhausted.no_writes",
        exhaustedRoot, beforeExhausted)
    assertRegistryIdentities("profiles.automation.independent.exhausted.identities",
        exhaustedRoot, exhaustedIdentities)

    for _, stage in ipairs({ "validate", "commit", "apply" }) do
        local _, _, test, root = makeProfileOpsFixture()
        local before = deepCopy(root)
        local identities = captureRegistryIdentities(root)
        local runtimeBefore = test.profileRuntimeState()
        test.profileOps.setFailureStage(stage)
        ok, reason = test.profileOps.useProfileForKnownSpecs("Player-1-OPS-A", "p4")
        eq("profiles.automation.share.failure." .. stage .. ".rejected", ok, false)
        eq("profiles.automation.share.failure." .. stage .. ".reason",
            reason, stage .. "-failed")
        assertDeepEqual("profiles.automation.share.failure." .. stage .. ".root", root, before)
        assertRegistryIdentities("profiles.automation.share.failure." .. stage .. ".identities",
            root, identities)
        eq("profiles.automation.share.failure." .. stage .. ".active",
            test.profileState().profileID, "p2")
        eq("profiles.automation.share.failure." .. stage .. ".apply_count",
            test.profileRuntimeState().applyCount,
            runtimeBefore.applyCount + (stage == "apply" and 1 or 0))
        eq("profiles.automation.share.failure." .. stage .. ".not_busy",
            test.profileOps.state().inProgress, false)
    end

    for _, stage in ipairs({ "validate", "commit", "apply" }) do
        local _, _, test, root = makeProfileOpsFixture({
            mutateRoot = function(candidate)
                candidate.characters["Player-1-OPS-A"].specProfiles[72] = "p2"
            end,
        })
        local before = deepCopy(root)
        local identities = captureRegistryIdentities(root)
        local runtimeBefore = test.profileRuntimeState()
        test.profileOps.setFailureStage(stage)
        ok, reason = test.profileOps.makeKnownSpecsIndependent("Player-1-OPS-A")
        eq("profiles.automation.independent.failure." .. stage .. ".rejected", ok, false)
        eq("profiles.automation.independent.failure." .. stage .. ".reason",
            reason, stage .. "-failed")
        assertDeepEqual("profiles.automation.independent.failure." .. stage .. ".root", root, before)
        assertRegistryIdentities("profiles.automation.independent.failure." .. stage .. ".identities",
            root, identities)
        eq("profiles.automation.independent.failure." .. stage .. ".active",
            test.profileState().profileID, "p2")
        eq("profiles.automation.independent.failure." .. stage .. ".apply_count",
            test.profileRuntimeState().applyCount, runtimeBefore.applyCount + (stage == "apply" and 1 or 0))
        eq("profiles.automation.independent.failure." .. stage .. ".not_busy",
            test.profileOps.state().inProgress, false)
    end

    for _, stage in ipairs({ "validate", "commit" }) do
        local _, _, roleTest, roleRoot = makeProfileOpsFixture()
        local roleBefore = deepCopy(roleRoot)
        local roleIdentities = captureRegistryIdentities(roleRoot)
        roleTest.profileOps.setFailureStage(stage)
        ok, reason = roleTest.profileOps.setRoleTemplate("HEALER", "p4")
        eq("profiles.automation.roles.failure." .. stage .. ".rejected", ok, false)
        eq("profiles.automation.roles.failure." .. stage .. ".reason",
            reason, stage .. "-failed")
        assertDeepEqual("profiles.automation.roles.failure." .. stage .. ".root",
            roleRoot, roleBefore)
        assertRegistryIdentities(
            "profiles.automation.roles.failure." .. stage .. ".identities",
            roleRoot, roleIdentities)
    end
end

do
    for _, case in ipairs({
        {
            name = "profiles_ref",
            replace = function(root) root.profiles = deepCopy(root.profiles) end,
            invoke = function(test, expected)
                return test.profileOps.setRoleTemplate("HEALER", "p4", expected)
            end,
        },
        {
            name = "roles_ref",
            replace = function(root) root.roleTemplates = deepCopy(root.roleTemplates) end,
            invoke = function(test, expected)
                return test.profileOps.setRoleTemplate("HEALER", "p4", expected)
            end,
        },
        {
            name = "character_ref",
            replace = function(root)
                root.characters["Player-1-OPS-A"] =
                    deepCopy(root.characters["Player-1-OPS-A"])
            end,
            invoke = function(test, expected)
                return test.profileOps.useProfileForKnownSpecs(
                    "Player-1-OPS-A", "p4", expected)
            end,
        },
    }) do
        local _, _, test, root = makeProfileOpsFixture()
        local state = test.profileState()
        local expected = {
            rootRef = root,
            generation = state.generation,
            profilesRef = root.profiles,
            roleTemplatesRef = root.roleTemplates,
            guid = "Player-1-OPS-A",
            characterRef = root.characters["Player-1-OPS-A"],
        }
        case.replace(root)
        local before = deepCopy(root)
        local identities = captureRegistryIdentities(root)
        local ok, reason = case.invoke(test, expected)
        eq("profiles.ops.gate.exact_ref." .. case.name .. ".rejected", ok, false)
        eq("profiles.ops.gate.exact_ref." .. case.name .. ".reason", reason, "stale")
        assertDeepEqual("profiles.ops.gate.exact_ref." .. case.name .. ".root", root, before)
        assertRegistryIdentities(
            "profiles.ops.gate.exact_ref." .. case.name .. ".identities", root, identities)
    end
end

do
    local _, _, test, root = makeProfileOpsFixture()
    local ops = test.profileOps
    local normalized, count = ops.validateName("  Танк 配置 😀  ", root.profiles)
    eq("profiles.ops.name.trim", normalized, "Танк 配置 😀")
    eq("profiles.ops.name.codepoints", count, 9)
    normalized, count = ops.validateName(string.rep("界", 40), root.profiles)
    eq("profiles.ops.name.limit.accept", normalized, string.rep("界", 40))
    eq("profiles.ops.name.limit.count", count, 40)
    eq("profiles.ops.name.limit.reject", ops.validateName(string.rep("界", 41), root.profiles), nil)
    eq("profiles.ops.name.pipe.reject", ops.validateName("Bad|cffff0000Name", root.profiles), nil)
    eq("profiles.ops.name.control.reject", ops.validateName("Bad\nName", root.profiles), nil)
    eq("profiles.ops.name.overlong.reject",
        ops.validateName(string.char(0xC0, 0xAF), root.profiles), nil)
    eq("profiles.ops.name.surrogate.reject",
        ops.validateName(string.char(0xED, 0xA0, 0x80), root.profiles), nil)
    eq("profiles.ops.name.out_of_range.reject",
        ops.validateName(string.char(0xF4, 0x90, 0x80, 0x80), root.profiles), nil)
    eq("profiles.ops.name.c1.reject",
        ops.validateName(string.char(0xC2, 0x85), root.profiles), nil)
    eq("profiles.ops.name.nbsp.reject",
        ops.validateName(string.char(0xC2, 0xA0), root.profiles), nil)
    eq("profiles.ops.name.bidi.reject",
        ops.validateName(string.char(0xE2, 0x80, 0xAE), root.profiles), nil)
    eq("profiles.ops.name.line_separator.reject",
        ops.validateName(string.char(0xE2, 0x80, 0xA8), root.profiles), nil)
    eq("profiles.ops.name.paragraph_separator.reject",
        ops.validateName(string.char(0xE2, 0x80, 0xA9), root.profiles), nil)
    eq("profiles.ops.name.word_joiner.reject",
        ops.validateName(string.char(0xE2, 0x81, 0xA0), root.profiles), nil)
    eq("profiles.ops.name.arabic_mark.reject",
        ops.validateName(string.char(0xD8, 0x9C), root.profiles), nil)
    eq("profiles.ops.name.duplicate.reject", ops.validateName("Tank shared", root.profiles), nil)

    local charactersBefore = deepCopy(root.characters)
    local rolesBefore = deepCopy(root.roleTemplates)
    local accountSettings = { root.account.forceLocale, root.account.updateInterval }
    local ok, profileID = ops.create("Новый 配置")
    eq("profiles.ops.create.ok", ok, true)
    eq("profiles.ops.create.id", profileID, "p5")
    eq("profiles.ops.create.next", root.account.nextProfileID, 6)
    eq("profiles.ops.create.name", root.profiles.p5.name, "Новый 配置")
    local expectedDefaults = test.copyDefaults()
    expectedDefaults.forceLocale = nil
    expectedDefaults.updateInterval = nil
    assertDeepEqual("profiles.ops.create.defaults", root.profiles.p5.settings, expectedDefaults)
    assertNoSharedTables("profiles.ops.create.isolated_from_default",
        root.profiles.p1.settings, root.profiles.p5.settings)
    assertDeepEqual("profiles.ops.create.assignments_unchanged", root.characters, charactersBefore)
    assertDeepEqual("profiles.ops.create.roles_unchanged", root.roleTemplates, rolesBefore)
    eq("profiles.ops.create.account_locale", root.account.forceLocale, accountSettings[1])
    eq("profiles.ops.create.account_interval", root.account.updateInterval, accountSettings[2])
    local model = test.profileViewModel()
    local foundCreated = false
    for _, profile in ipairs(model.profiles) do
        if profile.profileID == "p5" then foundCreated = true; eq(
            "profiles.ops.create.unused", profile.references.total, 0) end
    end
    eq("profiles.ops.create.catalog", foundCreated, true)

    local nextBeforeInvalid = root.account.nextProfileID
    local invalidBefore = deepCopy(root)
    ok = ops.create("Bad|Name")
    eq("profiles.ops.create.invalid_rejected", ok, false)
    eq("profiles.ops.create.invalid_next", root.account.nextProfileID, nextBeforeInvalid)
    assertDeepEqual("profiles.ops.create.invalid_no_writes", root, invalidBefore)

    ok = ops.deleteWithReplacement("p5", nil)
    eq("profiles.ops.create.delete_unused", ok, true)
    eq("profiles.ops.create.deleted", root.profiles.p5, nil)
    ok, profileID = ops.create("After deletion")
    eq("profiles.ops.create.after_delete_ok", ok, true)
    eq("profiles.ops.create.monotonic_id", profileID, "p6")
    eq("profiles.ops.create.monotonic_next", root.account.nextProfileID, 7)
end

do
    local _, _, test, root = makeProfileOpsFixture()
    local ops = test.profileOps
    local charactersBefore = deepCopy(root.characters)
    local sourceBefore = deepCopy(root.profiles.p2)
    local sourceRef = root.profiles.p2
    local sourceSettingsRef = sourceRef.settings
    local applyBefore = test.profileRuntimeState().applyCount
    local ok, profileID = ops.duplicate("p2", "Танк — копия")
    eq("profiles.ops.duplicate.ok", ok, true)
    eq("profiles.ops.duplicate.id", profileID, "p5")
    assertDeepEqual("profiles.ops.duplicate.settings",
        root.profiles.p5.settings, sourceBefore.settings)
    assertNoSharedTables("profiles.ops.duplicate.isolated",
        root.profiles.p2.settings, root.profiles.p5.settings)
    eq("profiles.ops.duplicate.source_identity", rawequal(root.profiles.p2, sourceRef), true)
    eq("profiles.ops.duplicate.source_settings_identity",
        rawequal(root.profiles.p2.settings, sourceSettingsRef), true)
    assertDeepEqual("profiles.ops.duplicate.assignments", root.characters, charactersBefore)
    eq("profiles.ops.duplicate.no_apply", test.profileRuntimeState().applyCount, applyBefore)

    local beforeMissing = deepCopy(root)
    ok = ops.duplicate("p999", "Missing")
    eq("profiles.ops.duplicate.missing_rejected", ok, false)
    assertDeepEqual("profiles.ops.duplicate.missing_no_writes", root, beforeMissing)

    local settingsRef = root.profiles.p2.settings
    local accountBefore = deepCopy(root.account)
    local rolesBefore = deepCopy(root.roleTemplates)
    local charactersBeforeRename = deepCopy(root.characters)
    ok, profileID = ops.rename("p2", "Танк 配置 é")
    eq("profiles.ops.rename.ok", ok, true)
    eq("profiles.ops.rename.id", profileID, "p2")
    eq("profiles.ops.rename.name", root.profiles.p2.name, "Танк 配置 é")
    eq("profiles.ops.rename.settings_identity",
        rawequal(root.profiles.p2.settings, settingsRef), true)
    assertDeepEqual("profiles.ops.rename.account", root.account, accountBefore)
    assertDeepEqual("profiles.ops.rename.roles", root.roleTemplates, rolesBefore)
    assertDeepEqual("profiles.ops.rename.assignments", root.characters, charactersBeforeRename)
    eq("profiles.ops.rename.active_id", test.profileState().profileID, "p2")
    eq("profiles.ops.rename.no_apply", test.profileRuntimeState().applyCount, applyBefore)

    local renameBefore = deepCopy(root)
    ok = ops.rename("p2", "Damage solo")
    eq("profiles.ops.rename.duplicate_rejected", ok, false)
    assertDeepEqual("profiles.ops.rename.duplicate_no_writes", root, renameBefore)
end

do
    local env, _, test, root = makeProfileOpsFixture()
    local ops = test.profileOps
    local sourceBefore = deepCopy(root.profiles.p3.settings)
    local sourceRef = root.profiles.p3.settings
    local assignmentsBefore = deepCopy(root.characters)
    local accountBefore = deepCopy(root.account)
    local applyBefore = test.profileRuntimeState().applyCount
    local oldTargetSettings = root.profiles.p2.settings
    local ok = ops.copySettings("p3", "p2")
    eq("profiles.ops.copy.active.ok", ok, true)
    eq("profiles.ops.copy.active.id", test.profileState().profileID, "p2")
    eq("profiles.ops.copy.active.new_settings",
        rawequal(root.profiles.p2.settings, oldTargetSettings), false)
    assertDeepEqual("profiles.ops.copy.active.payload", root.profiles.p2.settings, sourceBefore)
    assertNoSharedTables("profiles.ops.copy.active.isolated", sourceRef, root.profiles.p2.settings)
    assertDeepEqual("profiles.ops.copy.active.source_unchanged", root.profiles.p3.settings, sourceBefore)
    assertDeepEqual("profiles.ops.copy.active.assignments", root.characters, assignmentsBefore)
    assertDeepEqual("profiles.ops.copy.active.account", root.account, accountBefore)
    eq("profiles.ops.copy.active.applied", test.profileRuntimeState().applyCount, applyBefore + 1)
    eq("profiles.ops.copy.active.position", env.StatsProFrame.points[1][4], 301)

    applyBefore = test.profileRuntimeState().applyCount
    ok = ops.copySettings("p3", "p4")
    eq("profiles.ops.copy.offline.ok", ok, true)
    eq("profiles.ops.copy.offline.no_apply", test.profileRuntimeState().applyCount, applyBefore)
    assertNoSharedTables("profiles.ops.copy.offline.isolated",
        root.profiles.p3.settings, root.profiles.p4.settings)
    local beforeSame = deepCopy(root)
    ok = ops.copySettings("p3", "p3")
    eq("profiles.ops.copy.same_rejected", ok, false)
    assertDeepEqual("profiles.ops.copy.same_no_writes", root, beforeSame)
end

do
    for _, scope in ipairs({ "stats", "layout", "appearance" }) do
        local _, _, test, root = makeProfileOpsFixture()
        root.profiles.p3.settings.fontSize = 19
        root.profiles.p3.settings.textAlpha = 55
        if scope == "stats" then
            root.profiles.p3.settings.showStagger = nil
            root.profiles.p2.settings.showStagger = true
        elseif scope == "appearance" then
            local definition = test.appearancePresets.definitions().midnight
            for key in pairs(test.appearancePresets.allowlist()) do
                root.profiles.p3.settings[key] = deepCopy(definition[key])
            end
            root.profiles.p3.settings.appearancePresetID = "midnight"
            root.profiles.p2.settings.matchValueColorToStat = true
            root.profiles.p2.settings.useAutoColorDurability = false
            root.profiles.p2.settings.colors.crit = { r = 0.91, g = 0.92, b = 0.93 }
        end
        local targetBefore = deepCopy(root.profiles.p2.settings)
        local ok = test.profileOps.copySettings("p3", "p2", scope)
        eq("profiles.ops.copy.scope." .. scope .. ".ok", ok, true)
        if scope == "stats" then
            eq("profiles.ops.copy.scope.stats.value",
                root.profiles.p2.settings.showDefensive, false)
            eq("profiles.ops.copy.scope.stats.nested_color",
                root.profiles.p2.settings.colors.crit.r, 0.31)
            eq("profiles.ops.copy.scope.stats.absent_source_removes_target",
                root.profiles.p2.settings.showStagger, nil)
            eq("profiles.ops.copy.scope.stats.layout_preserved",
                root.profiles.p2.settings.scale, targetBefore.scale)
            eq("profiles.ops.copy.scope.stats.appearance_preserved",
                root.profiles.p2.settings.fontSize, targetBefore.fontSize)
        elseif scope == "layout" then
            eq("profiles.ops.copy.scope.layout.value",
                root.profiles.p2.settings.scale, 1.25)
            eq("profiles.ops.copy.scope.layout.stats_preserved",
                root.profiles.p2.settings.showDefensive, targetBefore.showDefensive)
            eq("profiles.ops.copy.scope.layout.appearance_preserved",
                root.profiles.p2.settings.fontSize, targetBefore.fontSize)
        else
            eq("profiles.ops.copy.scope.appearance.value",
                root.profiles.p2.settings.fontSize,
                root.profiles.p3.settings.fontSize)
            eq("profiles.ops.copy.scope.appearance.alpha",
                root.profiles.p2.settings.textAlpha,
                root.profiles.p3.settings.textAlpha)
            eq("profiles.ops.copy.scope.appearance.marker",
                root.profiles.p2.settings.appearancePresetID, "midnight")
            eq("profiles.ops.copy.scope.appearance.current_id",
                test.appearancePresets.currentID(root.profiles.p2.settings), "midnight")
            eq("profiles.ops.copy.scope.appearance.match_color",
                root.profiles.p2.settings.matchValueColorToStat,
                root.profiles.p3.settings.matchValueColorToStat)
            eq("profiles.ops.copy.scope.appearance.auto_durability",
                root.profiles.p2.settings.useAutoColorDurability,
                root.profiles.p3.settings.useAutoColorDurability)
            assertDeepEqual("profiles.ops.copy.scope.appearance.colors",
                root.profiles.p2.settings.colors, root.profiles.p3.settings.colors)
            eq("profiles.ops.copy.scope.appearance.colors_detached",
                rawequal(root.profiles.p2.settings.colors,
                    root.profiles.p3.settings.colors), false)
            assertNoSharedTables("profiles.ops.copy.scope.appearance.colors_isolated",
                root.profiles.p3.settings.colors, root.profiles.p2.settings.colors)
            eq("profiles.ops.copy.scope.appearance.stats_preserved",
                root.profiles.p2.settings.showDefensive, targetBefore.showDefensive)
            eq("profiles.ops.copy.scope.appearance.layout_preserved",
                root.profiles.p2.settings.scale, targetBefore.scale)
        end
    end

    local _, _, test, root = makeProfileOpsFixture()
    root.profiles.p3.settings.futurePayload = { nested = { keep = true } }
    local ok = test.profileOps.copySettings("p3", "p4", "all")
    eq("profiles.ops.copy.scope.all.ok", ok, true)
    eq("profiles.ops.copy.scope.all.locale_excluded",
        root.profiles.p4.settings.forceLocale, nil)
    eq("profiles.ops.copy.scope.all.interval_excluded",
        root.profiles.p4.settings.updateInterval, nil)
    eq("profiles.ops.copy.scope.all.unknown_preserved",
        root.profiles.p4.settings.futurePayload.nested.keep, true)
    assertNoSharedTables("profiles.ops.copy.scope.all.unknown_isolated",
        root.profiles.p3.settings.futurePayload, root.profiles.p4.settings.futurePayload)

    local _, _, clearTest, clearRoot = makeProfileOpsFixture()
    clearRoot.profiles.p3.settings.fontBeforeAutoSwitch = "Fonts\\ARIALN.TTF"
    clearRoot.profiles.p4.settings.fontBeforeAutoSwitch = "Fonts\\FRIZQT__.TTF"
    ok = clearTest.profileOps.copySettings("p3", "p4", "appearance")
    eq("profiles.ops.copy.scope.appearance.copy_restore_state.ok", ok, true)
    eq("profiles.ops.copy.scope.appearance.copy_restore_state.value",
        clearRoot.profiles.p4.settings.fontBeforeAutoSwitch, "Fonts\\ARIALN.TTF")
    clearRoot.profiles.p3.settings.fontBeforeAutoSwitch = nil
    clearRoot.profiles.p4.settings.fontBeforeAutoSwitch = "Fonts\\FRIZQT__.TTF"
    ok = clearTest.profileOps.copySettings("p3", "p4", "appearance")
    eq("profiles.ops.copy.scope.appearance.clear_restore_state.ok", ok, true)
    eq("profiles.ops.copy.scope.appearance.clear_restore_state.value",
        clearRoot.profiles.p4.settings.fontBeforeAutoSwitch, nil)

    local beforeInvalid = deepCopy(root)
    ok = test.profileOps.copySettings("p3", "p4", "unknown")
    eq("profiles.ops.copy.scope.invalid.rejected", ok, false)
    assertDeepEqual("profiles.ops.copy.scope.invalid.no_writes", root, beforeInvalid)
end

do
    local env, _, test, root = makeProfileOpsFixture()
    local ops = test.profileOps
    local applyBefore = test.profileRuntimeState().applyCount
    local alphaRef = root.characters["Player-1-OPS-A"]
    local bravoRef = root.characters["Player-1-OPS-B"]
    local ok = ops.assign("Player-1-OPS-B", 72, "p3")
    eq("profiles.ops.assign.offline.ok", ok, true)
    eq("profiles.ops.assign.offline.mapping",
        root.characters["Player-1-OPS-B"].specProfiles[72], "p3")
    eq("profiles.ops.assign.offline.no_apply", test.profileRuntimeState().applyCount, applyBefore)
    eq("profiles.ops.assign.offline.alpha_identity",
        rawequal(root.characters["Player-1-OPS-A"], alphaRef), true)
    eq("profiles.ops.assign.offline.bravo_replaced",
        rawequal(root.characters["Player-1-OPS-B"], bravoRef), false)

    env.StatsProFrame:ClearAllPoints()
    env.StatsProFrame:SetPoint("TOPLEFT", env.UIParent, "TOPLEFT", 111, -112)
    applyBefore = test.profileRuntimeState().applyCount
    ok = ops.assign("Player-1-OPS-A", 73, "p3")
    eq("profiles.ops.assign.active.ok", ok, true)
    eq("profiles.ops.assign.active.mapping",
        root.characters["Player-1-OPS-A"].specProfiles[73], "p3")
    eq("profiles.ops.assign.active.profile", test.profileState().profileID, "p3")
    eq("profiles.ops.assign.active.applied", test.profileRuntimeState().applyCount, applyBefore + 1)
    eq("profiles.ops.assign.active.outgoing_position", root.profiles.p2.settings.xOfs, 111)
    eq("profiles.ops.assign.active.guid", test.profileRuntimeState().activeGUID, "Player-1-OPS-A")
    eq("profiles.ops.assign.active.spec", test.profileRuntimeState().activeSpecID, 73)
    local invalidBefore = deepCopy(root)
    ok = ops.assign("Player-1-OPS-A", math.huge, "p1")
    eq("profiles.ops.assign.invalid_spec_rejected", ok, false)
    assertDeepEqual("profiles.ops.assign.invalid_spec_no_writes", root, invalidBefore)
end

do
    local _, _, test, root = makeProfileOpsFixture()
    local ops = test.profileOps
    local profileRefs = {
        p1 = root.profiles.p1, p2 = root.profiles.p2,
        p3 = root.profiles.p3, p4 = root.profiles.p4,
    }
    local applyBefore = test.profileRuntimeState().applyCount
    local ok = ops.swap(
        { guid = "Player-1-OPS-A", specID = 73 },
        { guid = "Player-1-OPS-B", specID = 72 })
    eq("profiles.ops.swap.active.ok", ok, true)
    eq("profiles.ops.swap.active.left",
        root.characters["Player-1-OPS-A"].specProfiles[73], "p4")
    eq("profiles.ops.swap.active.right",
        root.characters["Player-1-OPS-B"].specProfiles[72], "p2")
    eq("profiles.ops.swap.active.profile", test.profileState().profileID, "p4")
    eq("profiles.ops.swap.active.applied", test.profileRuntimeState().applyCount, applyBefore + 1)
    for profileID, profileRef in pairs(profileRefs) do
        eq("profiles.ops.swap.profile_identity." .. profileID,
            rawequal(root.profiles[profileID], profileRef), true)
    end

    applyBefore = test.profileRuntimeState().applyCount
    ok = ops.swap(
        { guid = "Player-1-OPS-A", specID = nil },
        { guid = "Player-1-OPS-A", specID = 71 })
    eq("profiles.ops.swap.same_character.ok", ok, true)
    eq("profiles.ops.swap.same_character.default",
        root.characters["Player-1-OPS-A"].defaultProfileID, "p3")
    eq("profiles.ops.swap.same_character.spec",
        root.characters["Player-1-OPS-A"].specProfiles[71], "p1")
    eq("profiles.ops.swap.same_character.no_apply",
        test.profileRuntimeState().applyCount, applyBefore)

    local beforeSame = deepCopy(root)
    ok = ops.swap(
        { guid = "Player-1-OPS-B", specID = 73 },
        { guid = "Player-1-OPS-C", specID = 65 })
    eq("profiles.ops.swap.same_profile_rejected", ok, false)
    assertDeepEqual("profiles.ops.swap.same_profile_no_writes", root, beforeSame)
end

do
    local _, _, test, root = makeProfileOpsFixture()
    local ops = test.profileOps
    root.profiles.p2.settings.unknownSafeField = { nested = true }
    local p2Name = root.profiles.p2.name
    local referencesBefore = {
        roles = deepCopy(root.roleTemplates),
        characters = deepCopy(root.characters),
    }
    local otherProfileBefore = deepCopy(root.profiles.p3)
    local applyBefore = test.profileRuntimeState().applyCount
    local ok = ops.resetCurrent("p2")
    eq("profiles.ops.reset.ok", ok, true)
    eq("profiles.ops.reset.id", test.profileState().profileID, "p2")
    eq("profiles.ops.reset.name", root.profiles.p2.name, p2Name)
    local expectedDefaults = test.copyDefaults()
    expectedDefaults.forceLocale = nil
    expectedDefaults.updateInterval = nil
    assertDeepEqual("profiles.ops.reset.defaults", root.profiles.p2.settings, expectedDefaults)
    assertNoSharedTables("profiles.ops.reset.isolated",
        root.profiles.p1.settings, root.profiles.p2.settings)
    assertDeepEqual("profiles.ops.reset.roles", root.roleTemplates, referencesBefore.roles)
    assertDeepEqual("profiles.ops.reset.assignments", root.characters, referencesBefore.characters)
    assertDeepEqual("profiles.ops.reset.other_profile", root.profiles.p3, otherProfileBefore)
    eq("profiles.ops.reset.applied", test.profileRuntimeState().applyCount, applyBefore + 1)
end

do
    local _, _, test, root = makeProfileOpsFixture()
    local ops = test.profileOps
    root.account.defaultProfileID = "p2"
    root.roleTemplates.HEALER = "p2"
    local references = ops.countReferences(root, "p2")
    eq("profiles.ops.delete.refs.specs", references.specs, 3)
    eq("profiles.ops.delete.refs.defaults", references.characterDefaults, 1)
    eq("profiles.ops.delete.refs.roles", references.roleTemplates, 2)
    eq("profiles.ops.delete.refs.account", references.accountDefault, 1)
    eq("profiles.ops.delete.refs.total", references.total, 7)
    local replacementRef = root.profiles.p3
    local replacementSettingsRef = replacementRef.settings
    local nextBefore = root.account.nextProfileID
    local applyBefore = test.profileRuntimeState().applyCount
    local ok = ops.deleteWithReplacement("p2", "p3")
    eq("profiles.ops.delete.ok", ok, true)
    eq("profiles.ops.delete.removed", root.profiles.p2, nil)
    eq("profiles.ops.delete.next_unchanged", root.account.nextProfileID, nextBefore)
    eq("profiles.ops.delete.role_replaced", root.roleTemplates.TANK, "p3")
    eq("profiles.ops.delete.second_role_replaced", root.roleTemplates.HEALER, "p3")
    eq("profiles.ops.delete.account_replaced", root.account.defaultProfileID, "p3")
    eq("profiles.ops.delete.default_replaced",
        root.characters["Player-1-OPS-B"].defaultProfileID, "p3")
    eq("profiles.ops.delete.alpha_replaced",
        root.characters["Player-1-OPS-A"].specProfiles[73], "p3")
    eq("profiles.ops.delete.bravo_replaced",
        root.characters["Player-1-OPS-B"].specProfiles[73], "p3")
    eq("profiles.ops.delete.charlie_replaced",
        root.characters["Player-1-OPS-C"].specProfiles[65], "p3")
    eq("profiles.ops.delete.replacement_identity",
        rawequal(root.profiles.p3, replacementRef), true)
    eq("profiles.ops.delete.replacement_settings_identity",
        rawequal(root.profiles.p3.settings, replacementSettingsRef), true)
    eq("profiles.ops.delete.active_profile", test.profileState().profileID, "p3")
    eq("profiles.ops.delete.applied", test.profileRuntimeState().applyCount, applyBefore + 1)
    eq("profiles.ops.delete.registry_current", test.dbCompatibilityState().mode, "current")
end

do
    local _, _, test, root = makeProfileOpsFixture({
        mutateRoot = function(candidate)
            candidate.profiles = { p1 = candidate.profiles.p1 }
            candidate.account.defaultProfileID = "p1"
            candidate.account.nextProfileID = 5
            candidate.roleTemplates = { TANK = "p1", HEALER = "p1", DAMAGER = "p1" }
            for _, character in pairs(candidate.characters) do
                character.defaultProfileID = "p1"
                for specID in pairs(character.specProfiles) do character.specProfiles[specID] = "p1" end
            end
        end,
    })
    local before = deepCopy(root)
    local identities = captureRegistryIdentities(root)
    local ok, reason = test.profileOps.deleteWithReplacement("p1", nil)
    eq("profiles.ops.delete.last_profile_rejected", ok, false)
    eq("profiles.ops.delete.last_profile_reason", reason, "last-profile")
    assertDeepEqual("profiles.ops.delete.last_profile_no_writes", root, before)
    assertRegistryIdentities("profiles.ops.delete.last_profile_identity", root, identities)
end

do
    local _, _, test, root = makeProfileOpsFixture()
    local profilesBefore = deepCopy(root.profiles)
    local profileRefs = captureRegistryIdentities(root)
    local activeBefore = test.profileRuntimeState()
    local applyBefore = activeBefore.applyCount
    local ok = test.profileOps.forgetCharacter("Player-1-OPS-B")
    eq("profiles.ops.forget.offline.ok", ok, true)
    eq("profiles.ops.forget.offline.removed", root.characters["Player-1-OPS-B"], nil)
    assertDeepEqual("profiles.ops.forget.profiles_preserved", root.profiles, profilesBefore)
    for profileID, profileRef in pairs(profileRefs.profileEntries) do
        eq("profiles.ops.forget.profile_identity." .. profileID,
            rawequal(root.profiles[profileID], profileRef), true)
    end
    eq("profiles.ops.forget.active_guid",
        test.profileRuntimeState().activeGUID, activeBefore.activeGUID)
    eq("profiles.ops.forget.no_apply", test.profileRuntimeState().applyCount, applyBefore)
    local beforeCurrent = deepCopy(root)
    ok = test.profileOps.forgetCharacter("Player-1-OPS-A")
    eq("profiles.ops.forget.current_rejected", ok, false)
    assertDeepEqual("profiles.ops.forget.current_no_writes", root, beforeCurrent)

    local coldRoot = deepCopy(root)
    coldRoot.characters["Player-1-OPS-B"] = {
        displayName = "Bravo-Realm",
        lastSeen = 90,
        defaultProfileID = "p2",
        specProfiles = { [73] = "p2" },
    }
    local coldBefore = deepCopy(coldRoot)
    local coldEnv, _, coldTest = loadStatsPro("enUS", {
        statsProDB = coldRoot,
        unitGUID = function() return "Player-1-OPS-A" end,
        getSpecialization = function() return nil end,
    })
    fireEvent("profiles.ops.forget.no_spec.activate", coldEnv, "PLAYER_ENTERING_WORLD")
    coldEnv.__flushTimers(0.1)
    eq("profiles.ops.forget.no_spec.no_active_guid",
        coldTest.profileRuntimeState().activeGUID, nil)
    ok = coldTest.profileOps.forgetCharacter("Player-1-OPS-A")
    eq("profiles.ops.forget.no_spec.current_rejected", ok, false)
    assertDeepEqual("profiles.ops.forget.no_spec.no_writes", coldRoot, coldBefore)
end

do
    for _, stage in ipairs({ "validate", "commit", "apply" }) do
        local _, _, test, root = makeProfileOpsFixture()
        if stage == "commit" then
            root.account.defaultProfileID = "p2"
            root.roleTemplates.HEALER = "p2"
        end
        local before = deepCopy(root)
        local identities = captureRegistryIdentities(root)
        local activeBefore = test.profileRuntimeState()
        test.profileOps.setFailureStage(stage)
        local ok, reason
        if stage == "commit" then
            ok, reason = test.profileOps.deleteWithReplacement("p2", "p3")
        else
            ok, reason = test.profileOps.assign("Player-1-OPS-A", 73, "p3")
        end
        eq("profiles.ops.failure." .. stage .. ".rejected", ok, false)
        eq("profiles.ops.failure." .. stage .. ".reason", reason, stage .. "-failed")
        assertDeepEqual("profiles.ops.failure." .. stage .. ".root", root, before)
        assertRegistryIdentities("profiles.ops.failure." .. stage .. ".identity", root, identities)
        eq("profiles.ops.failure." .. stage .. ".active_profile", test.profileState().profileID, "p2")
        eq("profiles.ops.failure." .. stage .. ".active_guid",
            test.profileRuntimeState().activeGUID, activeBefore.activeGUID)
        eq("profiles.ops.failure." .. stage .. ".active_spec",
            test.profileRuntimeState().activeSpecID, activeBefore.activeSpecID)
        eq("profiles.ops.failure." .. stage .. ".not_busy", test.profileOps.state().inProgress, false)
        eq("profiles.ops.failure." .. stage .. ".registry", test.dbCompatibilityState().mode, "current")
    end

    local env, _, test, root = makeProfileOpsFixture()
    local before = deepCopy(root)
    local identities = captureRegistryIdentities(root)
    local oldPoint, _, oldRelativePoint, oldX, oldY = env.StatsProFrame:GetPoint()
    local oldScale = env.StatsProFrame:GetScale()
    local oldSetPoint = env.StatsProFrame.SetPoint
    local failNext = true
    rawset(env.StatsProFrame, "SetPoint", function(frame, ...)
        if failNext then
            failNext = false
            root.profiles.p3.settings.showDefensive = true
            root.profiles.p3.settings.colors.crit.r = 0.999
            error("injected profile operation apply failure")
        end
        return oldSetPoint(frame, ...)
    end)
    local ok, reason = test.profileOps.assign("Player-1-OPS-A", 73, "p3")
    rawset(env.StatsProFrame, "SetPoint", oldSetPoint)
    eq("profiles.ops.failure.mutating_apply.rejected", ok, false)
    eq("profiles.ops.failure.mutating_apply.reason", reason, "apply-failed")
    assertDeepEqual("profiles.ops.failure.mutating_apply.root", root, before)
    assertRegistryIdentities("profiles.ops.failure.mutating_apply.identity", root, identities)
    eq("profiles.ops.failure.mutating_apply.active", test.profileState().profileID, "p2")
    local restoredPoint, _, restoredRelativePoint, restoredX, restoredY =
        env.StatsProFrame:GetPoint()
    eq("profiles.ops.failure.mutating_apply.visual_point", restoredPoint, oldPoint)
    eq("profiles.ops.failure.mutating_apply.visual_relative", restoredRelativePoint, oldRelativePoint)
    eq("profiles.ops.failure.mutating_apply.visual_x", restoredX, oldX)
    eq("profiles.ops.failure.mutating_apply.visual_y", restoredY, oldY)
    eq("profiles.ops.failure.mutating_apply.visual_scale", env.StatsProFrame:GetScale(), oldScale)

    env, _, test, root = makeProfileOpsFixture()
    before = deepCopy(root)
    oldSetPoint = env.StatsProFrame.SetPoint
    rawset(env.StatsProFrame, "SetPoint", function(frame, ...)
        error("injected target and rollback apply failure")
    end)
    ok, reason = test.profileOps.assign("Player-1-OPS-A", 73, "p3")
    eq("profiles.ops.failure.rollback_apply.rejected", ok, false)
    eq("profiles.ops.failure.rollback_apply.reason", reason, "rollback-apply-failed")
    assertDeepEqual("profiles.ops.failure.rollback_apply.root", root, before)
    eq("profiles.ops.failure.rollback_apply.force", test.profileRuntimeState().forceReapply, true)
    eq("profiles.ops.failure.rollback_apply.pending",
        test.profileRuntimeState().pendingResolution, true)
    local failRecoveryOnce = true
    rawset(env.StatsProFrame, "SetPoint", function(frame, ...)
        if failRecoveryOnce then
            failRecoveryOnce = false
            root.profiles.p2.settings.colors.crit.r = 0.777
            error("injected first recovery apply failure")
        end
        return oldSetPoint(frame, ...)
    end)
    env.__flushTimers(0)
    eq("profiles.ops.failure.rollback_apply.first_retry_force",
        test.profileRuntimeState().forceReapply, true)
    eq("profiles.ops.failure.rollback_apply.first_retry_pending",
        test.profileRuntimeState().pendingResolution, true)
    assertDeepEqual("profiles.ops.failure.rollback_apply.first_retry_root", root, before)
    rawset(env.StatsProFrame, "SetPoint", oldSetPoint)
    env.__flushTimers(0.25)
    eq("profiles.ops.failure.rollback_apply.recovered_force",
        test.profileRuntimeState().forceReapply, false)
    eq("profiles.ops.failure.rollback_apply.recovered_pending",
        test.profileRuntimeState().pendingResolution, false)
    eq("profiles.ops.failure.rollback_apply.recovered_profile", test.profileState().profileID, "p2")
end

do
    local calls = function(ops)
        return {
            function() return ops.create("Blocked New") end,
            function() return ops.duplicate("p2", "Blocked Copy") end,
            function() return ops.rename("p2", "Blocked Rename") end,
            function() return ops.copySettings("p3", "p2") end,
            function() return ops.assign("Player-1-OPS-A", 73, "p3") end,
            function() return ops.useProfileForKnownSpecs("Player-1-OPS-A", "p3") end,
            function() return ops.makeKnownSpecsIndependent("Player-1-OPS-A") end,
            function() return ops.setRoleTemplate("HEALER", "p4") end,
            function() return ops.swap(
                { guid = "Player-1-OPS-A", specID = 73 },
                { guid = "Player-1-OPS-B", specID = 72 }) end,
            function() return ops.resetCurrent("p2") end,
            function() return ops.importAndAssign({}) end,
            function() return ops.fullWipe() end,
            function() return ops.deleteWithReplacement("p2", "p3") end,
            function() return ops.forgetCharacter("Player-1-OPS-B") end,
        }
    end

    for _, gateCase in ipairs({ "combat", "unknown" }) do
        local secretCombat = {}
        local _, _, test, root, identity = makeProfileOpsFixture({
            issecretvalue = function(value) return value == secretCombat end,
        })
        identity.combat = gateCase == "combat"
        if gateCase == "unknown" then identity.combatValue = secretCombat end
        local before = deepCopy(root)
        local identities = captureRegistryIdentities(root)
        for index, invoke in ipairs(calls(test.profileOps)) do
            local ok, result, reason = pcall(invoke)
            check("profiles.ops.gate." .. gateCase .. ".no_error." .. index, ok, result)
            eq("profiles.ops.gate." .. gateCase .. ".rejected." .. index, result, false)
            eq("profiles.ops.gate." .. gateCase .. ".reason." .. index,
                reason, gateCase == "combat" and "combat" or "unsafe-context")
        end
        assertDeepEqual("profiles.ops.gate." .. gateCase .. ".root", root, before)
        assertRegistryIdentities("profiles.ops.gate." .. gateCase .. ".identity", root, identities)
    end

    local env, _, pendingTest, pendingRoot, identity = makeProfileOpsFixture()
    identity.specID, identity.specName, identity.role = 71, "Arms", "DAMAGER"
    fireEvent("profiles.ops.gate.pending.schedule",
        env, "PLAYER_SPECIALIZATION_CHANGED", "player")
    local pendingBefore = deepCopy(pendingRoot)
    local ok, reason
    for index, invoke in ipairs(calls(pendingTest.profileOps)) do
        local invoked, result, reason = pcall(invoke)
        check("profiles.ops.gate.pending.no_error." .. index, invoked, result)
        eq("profiles.ops.gate.pending.rejected." .. index, result, false)
        eq("profiles.ops.gate.pending.reason." .. index, reason, "pending")
    end
    assertDeepEqual("profiles.ops.gate.pending.no_writes", pendingRoot, pendingBefore)
    env.__flushTimers(0)
    eq("profiles.ops.gate.pending.resolved", pendingTest.profileState().profileID, "p3")
    ok = pendingTest.profileOps.rename("p3", "After safe switch")
    eq("profiles.ops.gate.pending.after_safe", ok, true)

    local expected = {
        rootRef = pendingRoot,
        generation = pendingTest.profileState().generation,
        guid = "Player-1-OPS-A",
        specID = 71,
        assignmentID = "p3",
        profileID = "p3",
        profileRef = pendingRoot.profiles.p3,
        activeProfileID = "p3",
    }
    ok = pendingTest.profileOps.assign("Player-1-OPS-B", 72, "p1")
    eq("profiles.ops.gate.stale.setup", ok, true)
    local staleBefore = deepCopy(pendingRoot)
    ok, reason = pendingTest.profileOps.rename("p3", "Stale rename", expected)
    eq("profiles.ops.gate.stale.rejected", ok, false)
    eq("profiles.ops.gate.stale.reason", reason, "stale")
    assertDeepEqual("profiles.ops.gate.stale.no_writes", pendingRoot, staleBefore)
end

do
    local env, _, test, root = makeProfileOpsFixture()
    local beforeTransition = deepCopy(root)
    test.profileOps.setTransitioning(true)
    eq("profiles.ops.gate.transitioning.viewmodel", test.profileViewModel().canMutate, false)
    local ok, reason = test.profileOps.rename("p2", "Blocked transition")
    eq("profiles.ops.gate.transitioning.rejected", ok, false)
    eq("profiles.ops.gate.transitioning.reason", reason, "busy")
    test.profileOps.setTransitioning(false)
    assertDeepEqual("profiles.ops.gate.transitioning.no_writes", root, beforeTransition)

    local innerOK, innerReason
    local oldSetPoint = env.StatsProFrame.SetPoint
    local attempted = false
    env.StatsProFrame.SetPoint = function(frame, ...)
        if not attempted then
            attempted = true
            innerOK, innerReason = test.profileOps.rename("p2", "Nested rename")
        end
        return oldSetPoint(frame, ...)
    end
    ok = test.profileOps.assign("Player-1-OPS-A", 73, "p3")
    env.StatsProFrame.SetPoint = oldSetPoint
    eq("profiles.ops.gate.reentrant.outer_ok", ok, true)
    eq("profiles.ops.gate.reentrant.rejected", innerOK, false)
    eq("profiles.ops.gate.reentrant.reason", innerReason, "busy")
    eq("profiles.ops.gate.reentrant.no_nested_rename", root.profiles.p2.name, "Tank shared")
end

do
    local seed = loadStatsPro("enUS")
    fireEvent("profiles.ops.future.seed", seed, "PLAYER_ENTERING_WORLD")
    local futureRoot = {
        dbVersion = seed.StatsProDB.dbVersion + 1,
        opaque = { keep = "exact" },
        account = "opaque account",
        profiles = 42,
        roleTemplates = false,
        characters = function() end,
    }
    local before = deepCopy(futureRoot)
    local env, _, test = loadStatsPro("enUS", {
        statsProDB = futureRoot,
        unitGUID = function() return "Player-1-FUTURE-OPS" end,
        getSpecialization = function() return 1 end,
        getSpecializationInfo = function()
            return 73, "Protection", nil, nil, "TANK", 1
        end,
    })
    fireEvent("profiles.ops.future.activate", env, "PLAYER_ENTERING_WORLD")
    local invocations = {
        function() return test.profileOps.create("Blocked") end,
        function() return test.profileOps.duplicate("p1", "Blocked") end,
        function() return test.profileOps.rename("p1", "Blocked") end,
        function() return test.profileOps.copySettings("p1", "p2") end,
        function() return test.profileOps.assign("guid", 73, "p1") end,
        function() return test.profileOps.useProfileForKnownSpecs("guid", "p1") end,
        function() return test.profileOps.makeKnownSpecsIndependent("guid") end,
        function() return test.profileOps.setRoleTemplate("TANK", "p1") end,
        function() return test.profileOps.swap(
            { guid = "a", specID = 73 }, { guid = "b", specID = 72 }) end,
        function() return test.profileOps.resetCurrent("p1") end,
        function() return test.profileOps.importAndAssign({}) end,
        function() return test.profileOps.fullWipe() end,
        function() return test.profileOps.deleteWithReplacement("p1", "p2") end,
        function() return test.profileOps.forgetCharacter("guid") end,
    }
    for index, invoke in ipairs(invocations) do
        local ok, result, reason = pcall(invoke)
        check("profiles.ops.future.no_error." .. index, ok, result)
        eq("profiles.ops.future.rejected." .. index, result, false)
        eq("profiles.ops.future.reason." .. index, reason, "read-only")
    end
    eq("profiles.ops.future.root_identity", rawequal(env.StatsProDB, futureRoot), true)
    assertDeepEqual("profiles.ops.future.no_writes", futureRoot, before)
end

do
    local env, addonContext, test, root, identity = makeProfileOpsFixture()
    addonContext:OpenConfigMenu()
    callScript("profiles.ui.automation.open_manager",
        env.StatsProManageProfilesButton, "OnClick")
    local state = test.profileUIState()
    eq("profiles.ui.automation.character_summary",
        state.selectedCharacterSummary, "Alpha-Realm - 2 known specs")
    eq("profiles.ui.automation.role_tank", state.roleTemplateSummary.TANK,
        "Tank: Tank shared")
    eq("profiles.ui.automation.role_healer", state.roleTemplateSummary.HEALER,
        "Healer: Default")
    eq("profiles.ui.automation.role_damage", state.roleTemplateSummary.DAMAGER,
        "Damage: Damage solo")
    eq("profiles.ui.automation.share_enabled", state.actions.useAllSpecs.enabled, true)
    eq("profiles.ui.automation.independent_enabled", state.actions.independent.enabled, true)
    eq("profiles.ui.automation.role_enabled", state.actions.roleTemplate.enabled, true)

    local function findChoice(name, predicate)
        return findFrame(name, env, function(frame)
            return frame:IsShown() and type(frame.choiceData) == "table"
                and predicate(frame.choiceData)
        end)
    end
    local function chooseRole(name, role)
        callScript(name .. ".open", env.StatsProProfileRoleTemplateButton, "OnClick")
        eq(name .. ".choice_mode", test.profileUIState().operationKind, "role-template")
        local row = findChoice(name .. ".choice", function(choice)
            return choice.role == role
        end)
        callScript(name .. ".choose", row, "OnClick")
        eq(name .. ".confirm_mode", test.profileUIState().operationKind, "set-role-template")
    end

    local beforeRoleCancel = deepCopy(root)
    chooseRole("profiles.ui.automation.role_cancel", "HEALER")
    callScript("profiles.ui.automation.role_cancel.cancel",
        env.StatsProProfileOperationCancelButton, "OnClick")
    assertDeepEqual("profiles.ui.automation.role_cancel.no_writes", root, beforeRoleCancel)
    chooseRole("profiles.ui.automation.role_confirm", "HEALER")
    callScript("profiles.ui.automation.role_confirm.confirm",
        env.StatsProProfileOperationConfirmButton, "OnClick")
    eq("profiles.ui.automation.role_confirm.mapping", root.roleTemplates.HEALER, "p2")
    eq("profiles.ui.automation.role_confirm.summary",
        test.profileUIState().roleTemplateSummary.HEALER, "Healer: Tank shared")

    callScript("profiles.ui.automation.select_share_profile.open",
        env.StatsProManagedProfileButton, "OnClick")
    local shareProfileChoice = findChoice(
        "profiles.ui.automation.select_share_profile.choice",
        function(choice) return choice.profileID == "p4" end)
    callScript("profiles.ui.automation.select_share_profile.choose",
        shareProfileChoice, "OnClick")
    eq("profiles.ui.automation.select_share_profile.selected",
        test.profileUIState().selectedProfileID, "p4")

    local assignmentsBeforeShare = deepCopy(root.characters["Player-1-OPS-A"].specProfiles)
    callScript("profiles.ui.automation.share_cancel.open",
        env.StatsProProfileUseAllSpecsButton, "OnClick")
    eq("profiles.ui.automation.share_cancel.mode",
        test.profileUIState().operationKind, "use-profile-for-specs")
    callScript("profiles.ui.automation.share_cancel.cancel",
        env.StatsProProfileOperationCancelButton, "OnClick")
    assertDeepEqual("profiles.ui.automation.share_cancel.no_writes",
        root.characters["Player-1-OPS-A"].specProfiles, assignmentsBeforeShare)
    callScript("profiles.ui.automation.share_confirm.open",
        env.StatsProProfileUseAllSpecsButton, "OnClick")
    callScript("profiles.ui.automation.share_confirm.confirm",
        env.StatsProProfileOperationConfirmButton, "OnClick")
    eq("profiles.ui.automation.share_confirm.spec_71",
        root.characters["Player-1-OPS-A"].specProfiles[71], "p4")
    eq("profiles.ui.automation.share_confirm.spec_73",
        root.characters["Player-1-OPS-A"].specProfiles[73], "p4")
    state = test.profileUIState()
    eq("profiles.ui.automation.share_confirm.header_profile",
        state.headerProfile, root.profiles.p4.name)
    eq("profiles.ui.automation.share_confirm.header_subtitle",
        state.headerSubtitle, "Shared by 3 specs")
    eq("profiles.ui.automation.share_confirm.button_disabled",
        state.actions.useAllSpecs.enabled, false)
    eq("profiles.ui.automation.share_confirm.independent_enabled",
        state.actions.independent.enabled, true)

    local rootBeforeIndependentCancel = deepCopy(root)
    callScript("profiles.ui.automation.independent_cancel.open",
        env.StatsProProfileMakeIndependentButton, "OnClick")
    eq("profiles.ui.automation.independent_cancel.mode",
        test.profileUIState().operationKind, "make-specs-independent")
    callScript("profiles.ui.automation.independent_cancel.cancel",
        env.StatsProProfileOperationCancelButton, "OnClick")
    assertDeepEqual("profiles.ui.automation.independent_cancel.no_writes",
        root, rootBeforeIndependentCancel)
    callScript("profiles.ui.automation.independent_confirm.open",
        env.StatsProProfileMakeIndependentButton, "OnClick")
    callScript("profiles.ui.automation.independent_confirm.confirm",
        env.StatsProProfileOperationConfirmButton, "OnClick")
    eq("profiles.ui.automation.independent_confirm.spec_71",
        root.characters["Player-1-OPS-A"].specProfiles[71], "p5")
    eq("profiles.ui.automation.independent_confirm.spec_73",
        root.characters["Player-1-OPS-A"].specProfiles[73], "p6")
    check("profiles.ui.automation.independent_confirm.distinct",
        root.characters["Player-1-OPS-A"].specProfiles[71]
            ~= root.characters["Player-1-OPS-A"].specProfiles[73])
    eq("profiles.ui.automation.independent_confirm.selected_active_clone",
        test.profileUIState().selectedProfileID, "p6")
    eq("profiles.ui.automation.independent_confirm.header_profile",
        test.profileUIState().headerProfile, root.profiles.p6.name)
    eq("profiles.ui.automation.independent_confirm.header_subtitle",
        test.profileUIState().headerSubtitle, "Automatic - Alpha-Realm / Protection")
    eq("profiles.ui.automation.independent_confirm.button_disabled",
        test.profileUIState().actions.independent.enabled, false)

    local rolesBeforeCombat = deepCopy(root.roleTemplates)
    chooseRole("profiles.ui.automation.combat_dialog", "TANK")
    identity.combat = true
    fireEvent("profiles.ui.automation.combat_start", env, "PLAYER_REGEN_DISABLED")
    state = test.profileUIState()
    eq("profiles.ui.automation.combat_dialog.closed", state.operationDialogShown, false)
    eq("profiles.ui.automation.combat_dialog.blocker_closed", state.operationBlockerShown, false)
    assertDeepEqual("profiles.ui.automation.combat_dialog.no_writes",
        root.roleTemplates, rolesBeforeCombat)
    for _, action in ipairs({ "useAllSpecs", "independent", "roleTemplate" }) do
        eq("profiles.ui.automation.combat_disabled." .. action,
            state.actions[action].enabled, false)
    end
    identity.combat = false
    fireEvent("profiles.ui.automation.combat_end", env, "PLAYER_REGEN_ENABLED")

    callScript("profiles.ui.automation.stale.open",
        env.StatsProProfileUseAllSpecsButton, "OnClick")
    local staleConfirm = env.StatsProProfileOperationConfirmButton.scripts.OnClick
    local staleBefore = deepCopy(root.characters["Player-1-OPS-A"].specProfiles)
    local changed = test.profileOps.setRoleTemplate("DAMAGER", "p4")
    eq("profiles.ui.automation.stale.setup", changed, true)
    staleConfirm(env.StatsProProfileOperationConfirmButton)
    assertDeepEqual("profiles.ui.automation.stale.no_old_bulk",
        root.characters["Player-1-OPS-A"].specProfiles, staleBefore)
end

do
    local env, addonContext, test, root = makeProfileOpsFixture()
    addonContext:OpenConfigMenu()
    callScript("profiles.ui.slash_modal.open_manager",
        env.StatsProManageProfilesButton, "OnClick")

    callScript("profiles.ui.slash_modal.visibility.open_reset",
        env.StatsProProfileResetButton, "OnClick")
    local staleVisibilityConfirm = env.StatsProProfileOperationConfirmButton.scripts.OnClick
    local visibilityAssignments = deepCopy(root.characters)
    local visibilityRoles = deepCopy(root.roleTemplates)
    slash("profiles.ui.slash_modal.visibility.hide", env, "hide")
    local state = test.profileUIState()
    eq("profiles.ui.slash_modal.visibility.dialog_closed", state.operationDialogShown, false)
    eq("profiles.ui.slash_modal.visibility.blocker_closed", state.operationBlockerShown, false)
    eq("profiles.ui.slash_modal.visibility.setting_applied", root.profiles.p2.settings.isVisible, false)
    staleVisibilityConfirm(env.StatsProProfileOperationConfirmButton)
    assertDeepEqual("profiles.ui.slash_modal.visibility.stale_no_assignments",
        root.characters, visibilityAssignments)
    assertDeepEqual("profiles.ui.slash_modal.visibility.stale_no_roles",
        root.roleTemplates, visibilityRoles)
    eq("profiles.ui.slash_modal.visibility.stale_did_not_reset",
        root.profiles.p2.settings.showDefensive, true)

    local otherProfileBeforeReset = deepCopy(root.profiles.p3)
    local assignmentsBeforeReset = deepCopy(root.characters)
    local rolesBeforeReset = deepCopy(root.roleTemplates)
    callScript("profiles.ui.slash_modal.reset.open",
        env.StatsProProfileResetButton, "OnClick")
    local staleResetConfirm = env.StatsProProfileOperationConfirmButton.scripts.OnClick
    slash("profiles.ui.slash_modal.reset.run", env, "reset")
    eq("profiles.ui.slash_modal.reset.popup_open",
        env.__lastStaticPopup.key, "STATSPRO_RESET_ACTIVE_PROFILE")
    env.__acceptStaticPopup()
    state = test.profileUIState()
    eq("profiles.ui.slash_modal.reset.dialog_closed", state.operationDialogShown, false)
    eq("profiles.ui.slash_modal.reset.blocker_closed", state.operationBlockerShown, false)
    eq("profiles.ui.slash_modal.reset.manager_stays_open", state.managerShown, true)
    eq("profiles.ui.slash_modal.reset.header_refreshed", state.headerProfile, "Tank shared")
    eq("profiles.ui.slash_modal.reset.active_default", root.profiles.p2.settings.showDefensive, false)
    assertDeepEqual("profiles.ui.slash_modal.reset.other_profile_preserved",
        root.profiles.p3, otherProfileBeforeReset)
    assertDeepEqual("profiles.ui.slash_modal.reset.assignments_preserved",
        root.characters, assignmentsBeforeReset)
    assertDeepEqual("profiles.ui.slash_modal.reset.roles_preserved",
        root.roleTemplates, rolesBeforeReset)
    local rootAfterReset = deepCopy(root)
    staleResetConfirm(env.StatsProProfileOperationConfirmButton)
    assertDeepEqual("profiles.ui.slash_modal.reset.stale_confirm_noop", root, rootAfterReset)

    root.profiles.p2.settings.showDefensive = true
    callScript("profiles.ui.slash_modal.import.open_role",
        env.StatsProProfileRoleTemplateButton, "OnClick")
    local healerChoice = findFrame("profiles.ui.slash_modal.import.healer_choice", env,
        function(frame)
            return frame:IsShown() and type(frame.choiceData) == "table"
                and frame.choiceData.role == "HEALER"
        end)
    callScript("profiles.ui.slash_modal.import.choose_role", healerChoice, "OnClick")
    local staleImportConfirm = env.StatsProProfileOperationConfirmButton.scripts.OnClick
    local rolesBeforeImport = deepCopy(root.roleTemplates)
    env.SwiftStatsDB = { fontSize = 17 }
    slash("profiles.ui.slash_modal.import.request", env, "import")
    state = test.profileUIState()
    eq("profiles.ui.slash_modal.import.operation_closed", state.operationDialogShown, false)
    eq("profiles.ui.slash_modal.import.blocker_closed", state.operationBlockerShown, false)
    check("profiles.ui.slash_modal.import.popup_open", env.__lastStaticPopup ~= nil)
    staleImportConfirm(env.StatsProProfileOperationConfirmButton)
    assertDeepEqual("profiles.ui.slash_modal.import.stale_role_noop",
        root.roleTemplates, rolesBeforeImport)
    env.__cancelStaticPopup()
end

do
    local env, addonContext, test, root = makeProfileOpsFixture()
    addonContext:OpenConfigMenu()
    callScript("profiles.ui.slash_modal.close_failure.open_manager",
        env.StatsProManageProfilesButton, "OnClick")
    callScript("profiles.ui.slash_modal.close_failure.open_reset",
        env.StatsProProfileResetButton, "OnClick")
    local before = deepCopy(root)
    local oldHide = env.StatsProProfileOperationDialog.Hide
    env.StatsProProfileOperationDialog.Hide = function()
        error("injected operation modal close failure")
    end
    slash("profiles.ui.slash_modal.close_failure.reset", env, "reset")
    env.StatsProProfileOperationDialog.Hide = oldHide
    assertDeepEqual("profiles.ui.slash_modal.close_failure.no_writes", root, before)
    eq("profiles.ui.slash_modal.close_failure.dialog_preserved",
        test.profileUIState().operationDialogShown, true)
    callScript("profiles.ui.slash_modal.close_failure.cleanup",
        env.StatsProProfileOperationCancelButton, "OnClick")
end

do
    local env, addonContext, test, root, identity = makeProfileOpsFixture()
    addonContext:OpenConfigMenu()
    callScript("profiles.ui.ops.open_manager", env.StatsProManageProfilesButton, "OnClick")
    local state = test.profileUIState()
    eq("profiles.ui.ops.manager", state.managerShown, true)
    eq("profiles.ui.ops.selector_default", state.managedProfile, "Tank shared")
    eq("profiles.ui.ops.selector_assigned", state.selectedAssignedProfileID, "p2")
    local actionCount = 0
    for _ in pairs(state.actions) do actionCount = actionCount + 1 end
    eq("profiles.ui.ops.action_count", actionCount, 12)
    eq("profiles.ui.ops.assign_same_disabled", state.actions.assign.enabled, false)
    eq("profiles.ui.ops.create_enabled", state.actions.create.enabled, true)
    eq("profiles.ui.ops.forget_current_disabled", state.actions.forget.enabled, false)

    local function findChoice(name, predicate)
        return findFrame(name, env, function(frame)
            return frame:IsShown() and type(frame.choiceData) == "table"
                and predicate(frame.choiceData)
        end)
    end
    local function chooseManaged(profileID)
        callScript("profiles.ui.ops.selector.open." .. profileID,
            env.StatsProManagedProfileButton, "OnClick")
        local row = findChoice("profiles.ui.ops.selector.choice." .. profileID,
            function(choice) return choice.profileID == profileID end)
        callScript("profiles.ui.ops.selector.choose." .. profileID, row, "OnClick")
    end
    local function submitName(name, value)
        env.StatsProProfileNameInput:SetText(value)
        callScript(name .. ".changed", env.StatsProProfileNameInput, "OnTextChanged")
        callScript(name .. ".submit", env.StatsProProfileOperationConfirmButton, "OnClick")
    end

    callScript("profiles.ui.ops.create.open", env.StatsProProfileNewButton, "OnClick")
    env.StatsProProfileNameInput:SetText("Bad|Name")
    callScript("profiles.ui.ops.create.invalid.changed",
        env.StatsProProfileNameInput, "OnTextChanged")
    state = test.profileUIState()
    eq("profiles.ui.ops.create.invalid_mode", state.operationKind, "create")
    eq("profiles.ui.ops.create.invalid_disabled", state.operationConfirmEnabled, false)
    check("profiles.ui.ops.create.invalid_message", state.nameValidation ~= "")
    submitName("profiles.ui.ops.create.valid", "UI Новый 配置")
    state = test.profileUIState()
    eq("profiles.ui.ops.create.selected", state.selectedProfileID, "p5")
    eq("profiles.ui.ops.create.unused", state.managedImpact, "Unused profile")
    eq("profiles.ui.ops.create.persisted", root.profiles.p5.name, "UI Новый 配置")

    callScript("profiles.ui.ops.duplicate.open", env.StatsProProfileDuplicateButton, "OnClick")
    submitName("profiles.ui.ops.duplicate.valid", "UI Duplicate")
    state = test.profileUIState()
    eq("profiles.ui.ops.duplicate.selected", state.selectedProfileID, "p6")
    assertNoSharedTables("profiles.ui.ops.duplicate.isolated",
        root.profiles.p5.settings, root.profiles.p6.settings)

    callScript("profiles.ui.ops.rename.open", env.StatsProProfileRenameButton, "OnClick")
    submitName("profiles.ui.ops.rename.valid", "Рейд 配置")
    eq("profiles.ui.ops.rename.stable_id", root.profiles.p6.name, "Рейд 配置")
    eq("profiles.ui.ops.rename.selected", test.profileUIState().selectedProfileID, "p6")

    state = test.profileUIState()
    eq("profiles.ui.ops.assign.enabled", state.actions.assign.enabled, true)
    callScript("profiles.ui.ops.assign", env.StatsProProfileAssignButton, "OnClick")
    eq("profiles.ui.ops.assign.mapping",
        root.characters["Player-1-OPS-A"].specProfiles[73], "p6")
    eq("profiles.ui.ops.assign.header", test.profileUIState().headerProfile, "Рейд 配置")

    callScript("profiles.ui.ops.header.open", env.StatsProActiveProfileButton, "OnClick")
    local p2Choice = findChoice("profiles.ui.ops.header.p2",
        function(choice) return choice.profileID == "p2" end)
    callScript("profiles.ui.ops.header.choose_p2", p2Choice, "OnClick")
    eq("profiles.ui.ops.header.mapping",
        root.characters["Player-1-OPS-A"].specProfiles[73], "p2")
    eq("profiles.ui.ops.header.updated", test.profileUIState().headerProfile, "Tank shared")

    chooseManaged("p3")
    local targetScale = root.profiles.p2.settings.scale
    callScript("profiles.ui.ops.copy.open", env.StatsProProfileCopyButton, "OnClick")
    state = test.profileUIState()
    eq("profiles.ui.ops.copy.scope_mode", state.operationKind, "copy-scope")
    local shownScopeCount = 0
    for _, choice in ipairs(state.choices) do
        if choice.shown then shownScopeCount = shownScopeCount + 1 end
    end
    eq("profiles.ui.ops.copy.scope_count", shownScopeCount, 4)
    local statsChoice = findChoice("profiles.ui.ops.copy.stats",
        function(choice) return choice.scope == "stats" end)
    callScript("profiles.ui.ops.copy.stats.choose", statsChoice, "OnClick")
    eq("profiles.ui.ops.copy.confirm_kind", test.profileUIState().operationKind, "copy")
    callScript("profiles.ui.ops.copy.cancel", env.StatsProProfileOperationCancelButton, "OnClick")
    eq("profiles.ui.ops.copy.cancel_preserved", root.profiles.p2.settings.showDefensive, true)
    callScript("profiles.ui.ops.copy.reopen", env.StatsProProfileCopyButton, "OnClick")
    statsChoice = findChoice("profiles.ui.ops.copy.stats_again",
        function(choice) return choice.scope == "stats" end)
    callScript("profiles.ui.ops.copy.stats.choose_again", statsChoice, "OnClick")
    callScript("profiles.ui.ops.copy.confirm", env.StatsProProfileOperationConfirmButton, "OnClick")
    eq("profiles.ui.ops.copy.stats_applied", root.profiles.p2.settings.showDefensive, false)
    eq("profiles.ui.ops.copy.layout_preserved", root.profiles.p2.settings.scale, targetScale)

    callScript("profiles.ui.ops.swap.open", env.StatsProProfileSwapButton, "OnClick")
    local contextChoice = findChoice("profiles.ui.ops.swap.context",
        function(choice)
            return choice.guid == "Player-1-OPS-B" and choice.specID == 72
        end)
    callScript("profiles.ui.ops.swap.choose", contextChoice, "OnClick")
    callScript("profiles.ui.ops.swap.confirm", env.StatsProProfileOperationConfirmButton, "OnClick")
    eq("profiles.ui.ops.swap.active_mapping",
        root.characters["Player-1-OPS-A"].specProfiles[73], "p4")
    eq("profiles.ui.ops.swap.offline_mapping",
        root.characters["Player-1-OPS-B"].specProfiles[72], "p2")
    eq("profiles.ui.ops.swap.header", test.profileUIState().headerProfile, "Offline only")

    callScript("profiles.ui.ops.reset.open", env.StatsProProfileResetButton, "OnClick")
    callScript("profiles.ui.ops.reset.cancel", env.StatsProProfileOperationCancelButton, "OnClick")
    eq("profiles.ui.ops.reset.cancel_preserved", root.profiles.p4.settings.showTertiary, true)
    callScript("profiles.ui.ops.reset.reopen", env.StatsProProfileResetButton, "OnClick")
    callScript("profiles.ui.ops.reset.confirm", env.StatsProProfileOperationConfirmButton, "OnClick")
    eq("profiles.ui.ops.reset.applied", root.profiles.p4.settings.showTertiary, false)

    chooseManaged("p3")
    callScript("profiles.ui.ops.delete.open", env.StatsProProfileDeleteButton, "OnClick")
    local replacementChoice = findChoice("profiles.ui.ops.delete.replacement",
        function(choice) return choice.profileID == "p1" end)
    callScript("profiles.ui.ops.delete.choose", replacementChoice, "OnClick")
    callScript("profiles.ui.ops.delete.cancel", env.StatsProProfileOperationCancelButton, "OnClick")
    check("profiles.ui.ops.delete.cancel_preserved", root.profiles.p3 ~= nil)
    callScript("profiles.ui.ops.delete.reopen", env.StatsProProfileDeleteButton, "OnClick")
    replacementChoice = findChoice("profiles.ui.ops.delete.replacement_again",
        function(choice) return choice.profileID == "p1" end)
    callScript("profiles.ui.ops.delete.choose_again", replacementChoice, "OnClick")
    callScript("profiles.ui.ops.delete.confirm", env.StatsProProfileOperationConfirmButton, "OnClick")
    eq("profiles.ui.ops.delete.removed", root.profiles.p3, nil)
    eq("profiles.ui.ops.delete.role_replaced", root.roleTemplates.DAMAGER, "p1")

    local bravoRow = findFrame("profiles.ui.ops.bravo_row", env, function(frame)
        return type(frame.profileContext) == "table"
            and frame.profileContext.guid == "Player-1-OPS-B"
            and frame.profileContext.specID == nil
    end)
    callScript("profiles.ui.ops.forget.select", bravoRow, "OnClick")
    eq("profiles.ui.ops.forget.enabled", test.profileUIState().actions.forget.enabled, true)
    callScript("profiles.ui.ops.forget.open", env.StatsProProfileForgetButton, "OnClick")
    callScript("profiles.ui.ops.forget.cancel", env.StatsProProfileOperationCancelButton, "OnClick")
    check("profiles.ui.ops.forget.cancel_preserved",
        root.characters["Player-1-OPS-B"] ~= nil)
    callScript("profiles.ui.ops.forget.reopen", env.StatsProProfileForgetButton, "OnClick")
    callScript("profiles.ui.ops.forget.confirm", env.StatsProProfileOperationConfirmButton, "OnClick")
    eq("profiles.ui.ops.forget.removed", root.characters["Player-1-OPS-B"], nil)

    callScript("profiles.ui.ops.dialog_lifecycle.open", env.StatsProProfileNewButton, "OnClick")
    env.StatsProProfileManager:Hide()
    state = test.profileUIState()
    eq("profiles.ui.ops.dialog_lifecycle.dialog_closed", state.operationDialogShown, false)
    eq("profiles.ui.ops.dialog_lifecycle.blocker_closed", state.operationBlockerShown, false)
    callScript("profiles.ui.ops.dialog_lifecycle.reopen_manager",
        env.StatsProManageProfilesButton, "OnClick")
    eq("profiles.ui.ops.dialog_lifecycle.no_stale", test.profileUIState().operationKind, nil)

    identity.combat = true
    fireEvent("profiles.ui.ops.combat", env, "PLAYER_REGEN_DISABLED")
    state = test.profileUIState()
    eq("profiles.ui.ops.combat.header_disabled", state.headerProfileEnabled, false)
    eq("profiles.ui.ops.combat.selector_readable", state.managedProfileEnabled, true)
    for action, actionState in pairs(state.actions) do
        eq("profiles.ui.ops.combat.action_disabled." .. action, actionState.enabled, false)
    end
    callScript("profiles.ui.ops.combat.selector", env.StatsProManagedProfileButton, "OnClick")
    eq("profiles.ui.ops.combat.read_dialog", test.profileUIState().operationKind, "select-profile")
    callScript("profiles.ui.ops.combat.close", env.StatsProProfileOperationCancelButton, "OnClick")
    identity.combat = false
    fireEvent("profiles.ui.ops.combat_resume", env, "PLAYER_REGEN_ENABLED")
    eq("profiles.ui.ops.combat_resume.mutable", test.profileViewModel().canMutate, true)

    chooseManaged("p1")
    callScript("profiles.ui.ops.stale.open", env.StatsProProfileRenameButton, "OnClick")
    env.StatsProProfileNameInput:SetText("Default renamed")
    callScript("profiles.ui.ops.stale.changed", env.StatsProProfileNameInput, "OnTextChanged")
    callScript("profiles.ui.ops.stale.to_confirm",
        env.StatsProProfileOperationConfirmButton, "OnClick")
    local staleCallback = env.StatsProProfileOperationConfirmButton.scripts.OnClick
    local p1Name = root.profiles.p1.name
    local renamed = test.profileOps.rename("p4", "Recovered active")
    eq("profiles.ui.ops.stale.setup", renamed, true)
    staleCallback(env.StatsProProfileOperationConfirmButton)
    eq("profiles.ui.ops.stale.no_old_confirm", root.profiles.p1.name, p1Name)

    callScript("profiles.ui.ops.stale_choice.open", env.StatsProManagedProfileButton, "OnClick")
    local staleChoice = findChoice("profiles.ui.ops.stale_choice.row",
        function(choice) return choice.profileID == "p2" end)
    local staleChoiceCallback = staleChoice.scripts.OnClick
    local selectedBeforeStaleChoice = test.profileUIState().selectedProfileID
    renamed = test.profileOps.rename("p4", "Recovered active again")
    eq("profiles.ui.ops.stale_choice.setup", renamed, true)
    staleChoiceCallback(staleChoice)
    eq("profiles.ui.ops.stale_choice.no_old_selection",
        test.profileUIState().selectedProfileID, selectedBeforeStaleChoice)

    callScript("profiles.ui.ops.future_name.open", env.StatsProProfileNewButton, "OnClick")
    local futureRoot = {
        dbVersion = root.dbVersion + 1,
        opaque = { keep = true }, account = "opaque", profiles = 42, characters = false,
    }
    env.StatsProDB = futureRoot
    env.StatsProProfileNameInput:SetText("Future blocked")
    callScript("profiles.ui.ops.future_name.changed",
        env.StatsProProfileNameInput, "OnTextChanged")
    state = test.profileUIState()
    eq("profiles.ui.ops.future_name.disabled", state.operationConfirmEnabled, false)
    eq("profiles.ui.ops.future_name.message",
        state.nameValidation, "Compatibility mode - profiles are read-only.")
    assertDeepEqual("profiles.ui.ops.future_name.no_writes", futureRoot, {
        dbVersion = root.dbVersion + 1,
        opaque = { keep = true }, account = "opaque", profiles = 42, characters = false,
    })
end

do
    local env, _, test = loadStatsPro("enUS")
    local function pointOffsets(frame)
        local point = frame.points and frame.points[1] or {}
        if #point == 3 then return point[2], point[3] end
        return point[4] or 0, point[5] or 0
    end
    fireEvent("config.control_design.pew", env, "PLAYER_ENTERING_WORLD")
    slash("config.control_design.open", env, "")

    local tokens = test.settingsDesignSnapshot()
    local controls = test.settingsControlState()
    local counts = {}
    for _, control in ipairs(controls) do
        counts[control.kind] = (counts[control.kind] or 0) + 1
        check("config.control_design.hit_target." .. tostring(control.kind)
                .. "." .. tostring(control.name or _),
            control.height >= 24 and control.width >= 24,
            "interactive control is smaller than 24x24px")
    end
    eq("config.control_design.checkbox_count", counts.checkbox, 37)
    eq("config.control_design.swatch_count", counts.swatch, 18)
    eq("config.control_design.slider_count", counts.slider, 5)
    eq("config.control_design.dropdown_trigger_count", counts.dropdown, 6)
    check("config.control_design.button_count", (counts.button or 0) >= 18,
        "shared shell buttons are not registered")
    eq("config.control_design.empty_warning_surface_hidden",
        env.StatsProConfigFrame.languageWarning.statsProWarningSurface:IsShown(), false)
    eq("config.control_design.empty_warning_rail_hidden",
        env.StatsProConfigFrame.languageWarning.statsProWarningRail:IsShown(), false)
    for index, border in ipairs(
        env.StatsProConfigFrame.languageWarning.statsProWarningSurface.statsProBorders) do
        eq("config.control_design.empty_warning_border_hidden." .. index,
            border:IsShown(), false)
    end
    local chatInput = env.CreateFrame("EditBox", "StatsProSmokeChatInput", env.UIParent,
        "InputBoxTemplate")
    chatInput:SetFocus()
    eq("config.control_design.chat_focus_setup", env.__focusedFrame, chatInput)

    local dbBeforeHover = deepCopy(env.StatsProDB)
    userInteract("config.control_design.checkbox_hover", env.StatsProOffensiveCheck, "OnEnter")
    eq("config.control_design.checkbox_hover_state",
        env.StatsProOffensiveCheck.statsProControlState, "hover")
    assertColor("config.control_design.checkbox_hover_fill",
        env.StatsProOffensiveCheck.statsProStateTexture.colorTexture,
        tokens.colors.rowHover[1], tokens.colors.rowHover[2], tokens.colors.rowHover[3])
    near("config.control_design.checkbox_hover_fill.a",
        env.StatsProOffensiveCheck.statsProStateTexture.colorTexture.a,
        tokens.colors.rowHover[4])
    userInteract("config.control_design.checkbox_pressed", env.StatsProOffensiveCheck, "OnMouseDown")
    eq("config.control_design.checkbox_pressed_state",
        env.StatsProOffensiveCheck.statsProControlState, "pressed")
    assertColor("config.control_design.checkbox_pressed_fill",
        env.StatsProOffensiveCheck.statsProStateTexture.colorTexture,
        tokens.colors.rowPressed[1], tokens.colors.rowPressed[2], tokens.colors.rowPressed[3])
    near("config.control_design.checkbox_pressed_fill.a",
        env.StatsProOffensiveCheck.statsProStateTexture.colorTexture.a,
        tokens.colors.rowPressed[4])
    userInteract("config.control_design.checkbox_release", env.StatsProOffensiveCheck, "OnMouseUp")
    userInteract("config.control_design.checkbox_leave", env.StatsProOffensiveCheck, "OnLeave")
    assertDeepEqual("config.control_design.hover_zero_writes", env.StatsProDB, dbBeforeHover)
    local _, critY = pointOffsets(env.StatsProCritCheck)
    local _, masteryY = pointOffsets(env.StatsProMasteryCheck)
    check("config.control_design.checkbox_row_pitch",
        math.abs(critY - masteryY) >= env.StatsProCritCheck:GetHeight(),
        "checkbox rows overlap")

    env.StatsProOffensiveCheck:SetChecked(false)
    userInteract("config.control_design.disable_master", env.StatsProOffensiveCheck, "OnClick")
    eq("config.control_design.disabled_checkbox", env.StatsProCritCheck:IsEnabled(), false)
    eq("config.control_design.disabled_checkbox_state",
        env.StatsProCritCheck.statsProControlState, "disabled")
    assertColor("config.control_design.disabled_checkbox_text",
        env.StatsProCritCheck.statsProText.textColor,
        tokens.colors.textDisabled[1], tokens.colors.textDisabled[2],
        tokens.colors.textDisabled[3])
    near("config.control_design.disabled_checkbox_text.a",
        env.StatsProCritCheck.statsProText.textColor.a, tokens.colors.textDisabled[4])
    eq("config.control_design.disabled_reason",
        env.StatsProCritCheck.statsProDisabledReasonKey, "Show Offensive Stats")
    local critSwatch = exists("config.control_design.disabled_swatch",
        env.StatsProCritCheck.statsProSwatch)
    eq("config.control_design.disabled_swatch_enabled", critSwatch:IsEnabled(), false)
    eq("config.control_design.disabled_swatch_alpha", critSwatch:GetAlpha(), 0.35)
    assertRGBA("config.control_design.disabled_swatch_border",
        critSwatch.statsProSurface.statsProBorders[1].colorTexture,
        tokens.colors.textDisabled)
    userInteract("config.control_design.disabled_tooltip", env.StatsProCritCheck, "OnEnter")
    eq("config.control_design.disabled_tooltip_owner", env.GameTooltip:GetOwner(),
        env.StatsProCritCheck)
    eq("config.control_design.disabled_tooltip_text", env.GameTooltip.lines[1].left,
        "Requires Show Offensive Stats.")
    local showCritBefore = activeSettings(env).showCrit
    eq("config.control_design.disabled_click_suppressed",
        userInteract("config.control_design.disabled_click", env.StatsProCritCheck, "OnClick"), false)
    eq("config.control_design.disabled_click_zero_write",
        activeSettings(env).showCrit, showCritBefore)
    local foreignTooltipOwner = env.CreateFrame("Frame", "StatsProSmokeForeignTooltipOwner",
        env.UIParent)
    env.GameTooltip:SetOwner(foreignTooltipOwner, "ANCHOR_LEFT")
    env.GameTooltip:AddLine("Foreign tooltip")
    env.GameTooltip:Show()
    userInteract("config.control_design.disabled_tooltip_leave", env.StatsProCritCheck, "OnLeave")
    eq("config.control_design.foreign_tooltip_preserved", env.GameTooltip:IsShown(), true)
    eq("config.control_design.foreign_tooltip_owner", env.GameTooltip:GetOwner(),
        foreignTooltipOwner)
    eq("config.control_design.foreign_tooltip_text",
        env.GameTooltip.lines[1].left, "Foreign tooltip")
    env.GameTooltip:Hide()

    env.StatsProOffensiveCheck:SetChecked(true)
    userInteract("config.control_design.reenable_master", env.StatsProOffensiveCheck, "OnClick")
    eq("config.control_design.reenabled_swatch", critSwatch:IsEnabled(), true)
    local hoverSurfacesBefore = deepCopy(env.StatsProDB)
    userInteract("config.control_design.swatch_hover", critSwatch, "OnEnter")
    assertRGBA("config.control_design.swatch_hover_border",
        critSwatch.statsProSurface.statsProBorders[1].colorTexture,
        tokens.colors.borderStrong)
    userInteract("config.control_design.swatch_pressed", critSwatch, "OnMouseDown")
    assertRGBA("config.control_design.swatch_pressed_border",
        critSwatch.statsProSurface.statsProBorders[1].colorTexture,
        tokens.colors.accent)
    userInteract("config.control_design.swatch_released", critSwatch, "OnMouseUp")
    userInteract("config.control_design.swatch_open", critSwatch, "OnClick")
    eq("config.control_design.swatch_active", critSwatch.statsProActive, true)
    assertRGBA("config.control_design.swatch_active_border",
        critSwatch.statsProSurface.statsProBorders[1].colorTexture,
        tokens.colors.accent)
    env.__cancelColorPicker()
    eq("config.control_design.swatch_cancel_inactive", critSwatch.statsProActive, false)
    assertRGBA("config.control_design.swatch_well",
        critSwatch.statsProColorWell.colorTexture, { 1, 0, 0, 1 })
    userInteract("config.control_design.swatch_leave", critSwatch, "OnLeave")

    userInteract("config.control_design.slider_hover", env.StatsProScaleSlider, "OnEnter")
    eq("config.control_design.slider_hover_state",
        env.StatsProScaleSlider.statsProControlState, "hover")
    exists("config.control_design.slider_thumb", env.StatsProScaleSlider.statsProThumb)
    exists("config.control_design.slider_track", env.StatsProScaleSlider.statsProTrack)
    assertColor("config.control_design.slider_hover_thumb",
        env.StatsProScaleSlider.statsProThumb.vertexColor,
        tokens.colors.textPrimary[1], tokens.colors.textPrimary[2],
        tokens.colors.textPrimary[3])
    near("config.control_design.slider_hover_thumb.a",
        env.StatsProScaleSlider.statsProThumb.vertexColor.a, 0.86)
    assertColor("config.control_design.slider_track_color",
        env.StatsProScaleSlider.statsProTrack.colorTexture,
        tokens.colors.track[1], tokens.colors.track[2], tokens.colors.track[3])
    near("config.control_design.slider_track_color.a",
        env.StatsProScaleSlider.statsProTrack.colorTexture.a, tokens.colors.track[4])
    userInteract("config.control_design.slider_leave", env.StatsProScaleSlider, "OnLeave")

    local dropdownTrigger = exists("config.control_design.dropdown_trigger",
        env.StatsProDisplayModeDropdown.statsProTrigger)
    userInteract("config.control_design.dropdown_hover", dropdownTrigger, "OnEnter")
    eq("config.control_design.dropdown_hover_state",
        dropdownTrigger.statsProControlState, "hover")
    eq("config.control_design.dropdown_width",
        env.StatsProDisplayModeDropdown.dropdownWidth, 180)
    eq("config.control_design.dropdown_justify",
        env.StatsProDisplayModeDropdown.dropdownJustify, "LEFT")
    assertColor("config.control_design.dropdown_hover_border",
        dropdownTrigger.statsProSurface.statsProBorders[1].colorTexture,
        tokens.colors.borderStrong[1], tokens.colors.borderStrong[2],
        tokens.colors.borderStrong[3])
    near("config.control_design.dropdown_hover_border.a",
        dropdownTrigger.statsProSurface.statsProBorders[1].colorTexture.a,
        tokens.colors.borderStrong[4])
    userInteract("config.control_design.dropdown_leave", dropdownTrigger, "OnLeave")

    eq("config.control_design.destructive_role",
        env.StatsProProfileResetButton.statsProButtonRole, "destructive")
    userInteract("config.control_design.destructive_hover",
        env.StatsProProfileResetButton, "OnEnter")
    eq("config.control_design.destructive_hover_state",
        env.StatsProProfileResetButton.statsProButtonState, "hover")
    local destructiveHoverColor = tokens.colors.pressed
    assertColor("config.control_design.destructive_hover_fill",
        env.StatsProProfileResetButton.backdropColor,
        destructiveHoverColor[1], destructiveHoverColor[2], destructiveHoverColor[3])
    near("config.control_design.destructive_hover_fill.a",
        env.StatsProProfileResetButton.backdropColor.a, destructiveHoverColor[4])
    userInteract("config.control_design.destructive_press",
        env.StatsProProfileResetButton, "OnMouseDown")
    env.StatsProProfileResetButton:Disable()
    eq("config.control_design.disable_clears_hover",
        env.StatsProProfileResetButton.statsProHovered, false)
    eq("config.control_design.disable_clears_pressed",
        env.StatsProProfileResetButton.statsProPressed, false)
    eq("config.control_design.disable_state",
        env.StatsProProfileResetButton.statsProButtonState, "disabled")
    env.StatsProProfileResetButton:Enable()
    eq("config.control_design.reenable_normal_state",
        env.StatsProProfileResetButton.statsProButtonState, "normal")
    userInteract("config.control_design.destructive_leave",
        env.StatsProProfileResetButton, "OnLeave")
    assertDeepEqual("config.control_design.multi_surface_hover_zero_writes",
        env.StatsProDB, hoverSurfacesBefore)
    eq("config.control_design.non_edit_controls_preserve_chat_focus",
        env.__focusedFrame, chatInput)

    env.StatsProOffensiveCheck:SetChecked(false)
    userInteract("config.control_design.pending_dependency_setup",
        env.StatsProOffensiveCheck, "OnClick")
    test.setSettingsContextBlockedForSmoke(true)
    eq("config.control_design.pending_slider_disabled",
        env.StatsProScaleSlider:IsEnabled(), false)
    eq("config.control_design.pending_dropdown_disabled",
        env.StatsProLanguageDropdownButton:IsEnabled(), false)
    eq("config.control_design.pending_dependency_disabled",
        env.StatsProCritCheck:IsEnabled(), false)
    local pendingBefore = deepCopy(env.StatsProDB)
    eq("config.control_design.pending_preview_suppressed",
        userInteract("config.control_design.pending_font_click",
            env.StatsProFontDropdownButton, "OnClick"), false)
    assertDeepEqual("config.control_design.pending_zero_writes", env.StatsProDB, pendingBefore)
    test.setSettingsContextBlockedForSmoke(false)
    eq("config.control_design.pending_slider_restored",
        env.StatsProScaleSlider:IsEnabled(), true)
    eq("config.control_design.pending_dropdown_restored",
        env.StatsProLanguageDropdownButton:IsEnabled(), true)
    eq("config.control_design.pending_dependency_preserved",
        env.StatsProCritCheck:IsEnabled(), false)
    env.StatsProOffensiveCheck:SetChecked(true)
    userInteract("config.control_design.pending_dependency_restore",
        env.StatsProOffensiveCheck, "OnClick")

    env.StatsProConfigFrame.SwitchToTab(3)
    userInteract("config.control_design.font_picker_open",
        env.StatsProFontDropdownButton, "OnClick")
    eq("config.control_design.font_dropdown_open_state",
        env.StatsProFontDropdownButton.statsProControlState, "normal")
    eq("config.control_design.font_dropdown_open_flag",
        env.StatsProFontDropdownButton.statsProOpen, true)
    local selectedFontRows = 0
    for _, control in ipairs(test.settingsControlState()) do
        if control.kind == "listRow" and control.selected then
            selectedFontRows = selectedFontRows + 1
        end
    end
    -- One selected font row plus the committed appearance-preset row.
    eq("config.control_design.font_and_preset_selected_rows", selectedFontRows, 2)
    local fontRows = {}
    for _, frame in ipairs(env.__frames) do
        if frame.fontPath and frame.statsProControlKind == "listRow" then
            fontRows[#fontRows + 1] = frame
        end
    end
    for left = 1, #fontRows do
        local leftX, leftY = pointOffsets(fontRows[left])
        for right = left + 1, #fontRows do
            local rightX, rightY = pointOffsets(fontRows[right])
            if leftX == rightX and leftY ~= rightY then
                check("config.control_design.font_row_pitch." .. left .. "." .. right,
                    math.abs(leftY - rightY) >= fontRows[left]:GetHeight(),
                    "font rows overlap")
            end
        end
    end
    local fontHoverBefore = deepCopy(env.StatsProDB)
    local fontRow = findFrame("config.control_design.font_row", env, function(frame)
        return frame.fontPath ~= nil and frame.statsProControlKind == "listRow"
            and frame.statsProSelected == true
    end)
    assertRGBA("config.control_design.font_selected_fill",
        fontRow.statsProStateTexture.colorTexture, tokens.colors.selected)
    userInteract("config.control_design.font_row_hover", fontRow, "OnEnter")
    assertRGBA("config.control_design.font_hover_fill",
        fontRow.statsProStateTexture.colorTexture, tokens.colors.rowHover)
    userInteract("config.control_design.font_row_leave", fontRow, "OnLeave")
    flushTimers("config.control_design.font_hover_timer", env, 0, 1)
    assertDeepEqual("config.control_design.font_hover_zero_writes",
        env.StatsProDB, fontHoverBefore)
    env.StatsProFontPicker:Hide()
    eq("config.control_design.font_dropdown_closed_flag",
        env.StatsProFontDropdownButton.statsProOpen, false)
    env.StatsProConfigFrame.SwitchToTab(1)

    userInteract("config.control_design.manager_open", env.StatsProManageProfilesButton, "OnClick")
    userInteract("config.control_design.profile_choices", env.StatsProManagedProfileButton, "OnClick")
    local visibleListRows = 0
    for _, row in ipairs(test.profileUIState().rows) do
        if row.shown then
            check("config.control_design.manager_row_hit_target." .. _,
                env.StatsProProfileManager:IsShown(), "manager row built outside manager")
        end
    end
    for _, control in ipairs(test.settingsControlState()) do
        if control.kind == "listRow" and control.enabled then visibleListRows = visibleListRows + 1 end
    end
    check("config.control_design.choice_rows_styled", visibleListRows >= 1,
        "choice rows are not registered with the shared list-row design")
    local choiceRow = findFrame("config.control_design.choice_row", env, function(frame)
        return frame.choiceData ~= nil and frame.statsProControlKind == "listRow"
    end)
    local choiceHoverBefore = deepCopy(env.StatsProDB)
    userInteract("config.control_design.choice_row_hover", choiceRow, "OnEnter")
    assertRGBA("config.control_design.choice_hover_fill",
        choiceRow.statsProStateTexture.colorTexture, tokens.colors.rowHover)
    userInteract("config.control_design.choice_row_leave", choiceRow, "OnLeave")
    assertDeepEqual("config.control_design.choice_hover_zero_writes",
        env.StatsProDB, choiceHoverBefore)
    userInteract("config.control_design.profile_choices_close",
        env.StatsProProfileOperationCancelButton, "OnClick")

    userInteract("config.control_design.name_dialog_open", env.StatsProProfileNewButton, "OnClick")
    eq("config.control_design.name_releases_chat_focus", chatInput:HasFocus(), false)
    eq("config.control_design.name_focus", env.StatsProProfileNameInput:HasFocus(), true)
    for _, suffix in ipairs({ "Left", "Middle", "Right" }) do
        eq("config.control_design.editbox_legacy_hidden." .. suffix,
            env["StatsProProfileNameInput" .. suffix]:GetAlpha(), 0)
    end
    eq("config.control_design.name_focus_border",
        env.StatsProProfileNameInput.statsProSurface.statsProBorderRole, "accent")
    assertColor("config.control_design.name_focus_border_color",
        env.StatsProProfileNameInput.statsProSurface.statsProBorders[1].colorTexture,
        tokens.colors.accent[1], tokens.colors.accent[2], tokens.colors.accent[3])
    near("config.control_design.name_focus_border_color.a",
        env.StatsProProfileNameInput.statsProSurface.statsProBorders[1].colorTexture.a,
        tokens.colors.accent[4])
    env.StatsProProfileNameInput:SetText("")
    userInteract("config.control_design.name_invalid", env.StatsProProfileNameInput, "OnTextChanged")
    eq("config.control_design.name_invalid_state",
        env.StatsProProfileNameInput.statsProInvalid, true)
    eq("config.control_design.name_invalid_border",
        env.StatsProProfileNameInput.statsProSurface.statsProBorderRole, "danger")
    assertColor("config.control_design.name_invalid_border_color",
        env.StatsProProfileNameInput.statsProSurface.statsProBorders[1].colorTexture,
        tokens.colors.danger[1], tokens.colors.danger[2], tokens.colors.danger[3])
    near("config.control_design.name_invalid_border_color.a",
        env.StatsProProfileNameInput.statsProSurface.statsProBorders[1].colorTexture.a,
        tokens.colors.danger[4])
    userInteract("config.control_design.name_escape", env.StatsProProfileNameInput, "OnEscapePressed")
    eq("config.control_design.name_focus_cleared", env.StatsProProfileNameInput:HasFocus(), false)
    eq("config.control_design.name_focus_owner_cleared", env.__focusedFrame, nil)

    for index, control in ipairs(test.settingsControlState()) do
        check("config.control_design.lazy_hit_target." .. index,
            control.width >= 24 and control.height >= 24,
            "lazy control is smaller than 24x24px")
        local frame
        for _, candidate in ipairs(env.__frames) do
            if candidate:GetName() == control.name and control.name then frame = candidate break end
        end
        if frame then
            eq("config.control_design.no_onupdate." .. index, frame.scripts.OnUpdate, nil)
            if control.kind ~= "editBox" then
                eq("config.control_design.no_keyboard_capture." .. index,
                    frame:IsKeyboardEnabled(), false)
                eq("config.control_design.no_focus_capture." .. index,
                    frame:HasFocus(), false)
            end
        end
    end
end

do
    local presetEnv, presetAddon, presetTest = loadStatsPro("enUS", withProfileIdentity())
    fireEvent("appearance.presets.pew", presetEnv, "PLAYER_ENTERING_WORLD")
    local service = presetTest.appearancePresets
    local expectedOrder = {
        "default", "classic", "clean-dark", "midnight", "monochrome", "high-contrast",
    }
    assertDeepEqual("appearance.presets.registry.order", service.order(), expectedOrder)
    local allowlist = service.allowlist()
    assertDeepEqual("appearance.presets.registry.allowlist", allowlist, {
        fontSize=true, textAlpha=true, panelBackgroundAlpha=true,
        textOutlineStyle=true, matchValueColorToStat=true,
        useAutoColorDurability=true, colors=true,
    })
    local definitions = service.definitions()
    local defaults = presetTest.copyDefaults()
    local colorCount = 0
    for key in pairs(defaults.colors) do colorCount = colorCount + 1 end
    eq("appearance.presets.registry.default_marker", defaults.appearancePresetID, "default")
    for _, presetID in ipairs(expectedOrder) do
        local definition = exists("appearance.presets.registry." .. presetID, definitions[presetID])
        local actualColorCount = 0
        for key, color in pairs(definition.colors or {}) do
            actualColorCount = actualColorCount + 1
            check("appearance.presets.registry." .. presetID .. ".known_color." .. key,
                defaults.colors[key] ~= nil)
            check("appearance.presets.registry." .. presetID .. ".finite_color." .. key,
                isFiniteNumber(color.r) and isFiniteNumber(color.g) and isFiniteNumber(color.b)
                    and color.r >= 0 and color.r <= 1 and color.g >= 0 and color.g <= 1
                    and color.b >= 0 and color.b <= 1)
        end
        eq("appearance.presets.registry." .. presetID .. ".complete_colors",
            actualColorCount, colorCount)
        for key in pairs(allowlist) do
            check("appearance.presets.registry." .. presetID .. ".required." .. key,
                definition[key] ~= nil)
            if key ~= "colors" then
                eq("appearance.presets.registry." .. presetID .. ".type." .. key,
                    type(definition[key]), type(defaults[key]))
            end
        end
        for key in pairs(definition) do
            check("appearance.presets.registry." .. presetID .. ".allowed_key." .. key,
                key == "label" or allowlist[key] == true)
        end
        check("appearance.presets.registry." .. presetID .. ".font_size_range",
            definition.fontSize >= 8 and definition.fontSize <= 32)
        check("appearance.presets.registry." .. presetID .. ".text_alpha_range",
            definition.textAlpha >= 25 and definition.textAlpha <= 100)
        check("appearance.presets.registry." .. presetID .. ".background_range",
            definition.panelBackgroundAlpha >= 0
                and definition.panelBackgroundAlpha <= 80)
        check("appearance.presets.registry." .. presetID .. ".outline_enum",
            definition.textOutlineStyle == "none"
                or definition.textOutlineStyle == "outline"
                or definition.textOutlineStyle == "thick")
    end
    local defaultPresetPayload = deepCopy(definitions.default)
    defaultPresetPayload.label = nil
    local defaultPayload = {}
    for key in pairs(allowlist) do defaultPayload[key] = deepCopy(defaults[key]) end
    assertDeepEqual("appearance.presets.registry.default_matches_defaults",
        defaultPresetPayload, defaultPayload)
    eq("appearance.presets.registry.classic_keeps_transparent_background",
        definitions.classic.panelBackgroundAlpha, 0)
    eq("appearance.presets.registry.classic_keeps_separate_value_colors",
        definitions.classic.matchValueColorToStat, false)
    local classicSettings = deepCopy(defaults)
    for key in pairs(allowlist) do
        classicSettings[key] = deepCopy(definitions.classic[key])
    end
    classicSettings.appearancePresetID = "classic"
    eq("appearance.presets.registry.false_value_survives_capture",
        service.currentID(classicSettings), "classic")

    local state = presetTest.profileState()
    local activeProfileID = state.profileID
    local settings = state.settings
    settings.showCrit = false
    settings.showRating = false
    settings.showPercentage = false
    settings.displayMode = "split"
    settings.scale = 1.3
    local rootRef, profilesRef, settingsRef = state.root, state.profiles, settings
    local beforePreview = deepCopy(settings)
    local beforeRuntime = presetTest.cachedAppearanceState()
    local beforeVisual = presetTest.panelVisualState()
    local accountBefore = deepCopy(state.root.account)
    local charactersBefore = deepCopy(state.root.characters)
    local roleTemplatesBefore = deepCopy(state.root.roleTemplates)
    local otherProfilesBefore, otherProfileRefs = {}, {}
    for profileID, profile in pairs(state.profiles) do
        if profileID ~= state.profileID then
            otherProfilesBefore[profileID] = deepCopy(profile)
            otherProfileRefs[profileID] = profile
        end
    end
    local forbiddenKeys = {
        "font", "fontBeforeAutoSwitch", "isVisible", "isLocked", "displayMode",
        "labelStyle", "scale", "updateInterval", "forceLocale", "point",
        "relativePoint", "xOfs", "yOfs", "defensive_point",
        "defensive_relativePoint", "defensive_xOfs", "defensive_yOfs",
        "showRating", "showPercentage", "showCrit", "showHaste", "showMastery", "showVersatility",
        "showDefensive", "showDurability", "showRepairCost", "splitOffensive",
        "splitDefensive", "targetSnapshot",
    }
    local forbiddenBefore = {}
    for _, key in ipairs(forbiddenKeys) do forbiddenBefore[key] = settings[key] end
    eq("appearance.presets.fresh_is_default", service.currentID(), "default")

    local ok, reason = service.startPreview("high-contrast")
    eq("appearance.presets.preview.starts", ok, true)
    eq("appearance.presets.preview.reason", reason, nil)
    eq("appearance.presets.preview.id", service.state().presetID, "high-contrast")
    local previewRuntime = presetTest.cachedAppearanceState()
    eq("appearance.presets.preview.runtime_font_size", previewRuntime.fontSize, 16)
    near("appearance.presets.preview.runtime_text_alpha", previewRuntime.textAlpha, 1)
    near("appearance.presets.preview.runtime_background",
        previewRuntime.panelBackgroundAlpha, 0.75)
    eq("appearance.presets.preview.runtime_outline",
        previewRuntime.textOutlineStyle, "thick")
    eq("appearance.presets.preview.runtime_match_color",
        previewRuntime.matchValueColorToStat, true)
    eq("appearance.presets.preview.runtime_auto_durability",
        previewRuntime.useAutoColorDurability, true)
    check("appearance.presets.preview.runtime_palette_changed",
        previewRuntime.colorStrings.crit ~= beforeRuntime.colorStrings.crit)
    local previewVisual = presetTest.panelVisualState()
    eq("appearance.presets.preview.rendered_outline", previewVisual.mainLabelFlags,
        "THICKOUTLINE")
    near("appearance.presets.preview.rendered_alpha", previewVisual.mainLabelAlpha, 1)
    near("appearance.presets.preview.rendered_background",
        previewVisual.mainBackgroundTextureAlpha, 0.75)
    assertDeepEqual("appearance.presets.preview.zero_db_writes", settings, beforePreview)
    eq("appearance.presets.preview.root_identity", presetTest.profileState().root, rootRef)
    eq("appearance.presets.preview.profiles_identity", presetTest.profileState().profiles, profilesRef)
    eq("appearance.presets.preview.settings_identity", presetTest.profileState().settings, settingsRef)

    ok = service.startPreview("midnight")
    eq("appearance.presets.preview.switches", ok, true)
    assertDeepEqual("appearance.presets.preview.switch_keeps_db", settings, beforePreview)
    eq("appearance.presets.preview.switch_id", service.state().presetID, "midnight")
    near("appearance.presets.preview.switch_runtime_background",
        presetTest.cachedAppearanceState().panelBackgroundAlpha, 0.35)
    eq("appearance.presets.preview.cancel", service.cancelPreview(), true)
    assertDeepEqual("appearance.presets.preview.cancel_exact", settings, beforePreview)
    eq("appearance.presets.preview.cancel_inactive", service.state().active, false)
    assertDeepEqual("appearance.presets.preview.cancel_runtime_exact",
        presetTest.cachedAppearanceState(), beforeRuntime)
    local restoredVisual = presetTest.panelVisualState()
    eq("appearance.presets.preview.cancel_rendered_outline",
        restoredVisual.mainLabelFlags, beforeVisual.mainLabelFlags)
    near("appearance.presets.preview.cancel_rendered_alpha",
        restoredVisual.mainLabelAlpha, beforeVisual.mainLabelAlpha)
    near("appearance.presets.preview.cancel_rendered_background",
        restoredVisual.mainBackgroundTextureAlpha,
        beforeVisual.mainBackgroundTextureAlpha)

    ok = service.startPreview("high-contrast")
    eq("appearance.presets.apply.preview", ok, true)
    ok, reason = service.applyPreview()
    eq("appearance.presets.apply.success", ok, true)
    eq("appearance.presets.apply.result", reason, activeProfileID)
    local applied = presetTest.profileState()
    eq("appearance.presets.apply.root_identity", applied.root, rootRef)
    check("appearance.presets.apply.profiles_replaced", applied.profiles ~= profilesRef)
    check("appearance.presets.apply.settings_replaced", applied.settings ~= settingsRef)
    eq("appearance.presets.apply.marker", applied.settings.appearancePresetID, "high-contrast")
    eq("appearance.presets.apply.current_id", service.currentID(), "high-contrast")
    ok, reason = service.startPreview("high-contrast")
    eq("appearance.presets.current_click_noop", ok, false)
    eq("appearance.presets.current_click_reason", reason, "no-change")
    eq("appearance.presets.current_click_no_session", service.state().active, false)
    eq("appearance.presets.apply.protected_visibility", applied.settings.showCrit, false)
    eq("appearance.presets.apply.protected_layout", applied.settings.displayMode, "split")
    near("appearance.presets.apply.protected_scale", applied.settings.scale, 1.3)
    eq("appearance.presets.apply.protected_position",
        applied.settings.point, beforePreview.point)
    for _, key in ipairs(forbiddenKeys) do
        eq("appearance.presets.apply.forbidden." .. key,
            applied.settings[key], forbiddenBefore[key])
    end
    assertDeepEqual("appearance.presets.apply.account_unchanged",
        applied.root.account, accountBefore)
    assertDeepEqual("appearance.presets.apply.characters_unchanged",
        applied.root.characters, charactersBefore)
    assertDeepEqual("appearance.presets.apply.role_templates_unchanged",
        applied.root.roleTemplates, roleTemplatesBefore)
    for profileID, profile in pairs(otherProfilesBefore) do
        eq("appearance.presets.apply.other_identity." .. profileID,
            applied.profiles[profileID], otherProfileRefs[profileID])
        assertDeepEqual("appearance.presets.apply.other_unchanged." .. profileID,
            applied.profiles[profileID], profile)
    end
    assertNoSharedTables("appearance.presets.apply.detached_definition",
        definitions["high-contrast"].colors, applied.settings.colors)

    local appliedSettings = applied.settings
    ok = service.startPreview("monochrome")
    eq("appearance.presets.rollback.preview", ok, true)
    presetTest.profileOps.setFailureStage("commit")
    ok, reason = service.applyPreview()
    eq("appearance.presets.rollback.rejected", ok, false)
    eq("appearance.presets.rollback.reason", reason, "commit-failed")
    presetTest.profileOps.setFailureStage(nil)
    eq("appearance.presets.rollback.settings_identity",
        presetTest.profileState().settings, appliedSettings)
    eq("appearance.presets.rollback.marker",
        presetTest.profileState().settings.appearancePresetID, "high-contrast")
    eq("appearance.presets.rollback.preview_resumed", service.state().active, true)
    eq("appearance.presets.rollback.cancel_resumed", service.cancelPreview(), true)

    for _, stage in ipairs({ "validate", "apply" }) do
        ok = service.startPreview("monochrome")
        eq("appearance.presets.failure." .. stage .. ".preview", ok, true)
        presetTest.profileOps.setFailureStage(stage)
        ok, reason = service.applyPreview()
        eq("appearance.presets.failure." .. stage .. ".rejected", ok, false)
        eq("appearance.presets.failure." .. stage .. ".reason",
            reason, stage .. "-failed")
        eq("appearance.presets.failure." .. stage .. ".preview_resumed",
            service.state().active, true)
        eq("appearance.presets.failure." .. stage .. ".cancel",
            service.cancelPreview(), true)
        eq("appearance.presets.failure." .. stage .. ".marker",
            presetTest.profileState().settings.appearancePresetID, "high-contrast")
    end
    ok = service.startPreview("monochrome")
    eq("appearance.presets.failure.busy.preview", ok, true)
    presetTest.profileOps.setTransitioning(true)
    ok, reason = service.applyPreview()
    eq("appearance.presets.failure.busy.rejected", ok, false)
    eq("appearance.presets.failure.busy.reason", reason, "busy")
    eq("appearance.presets.failure.busy.preview_closed", service.state().active, false)
    presetTest.profileOps.setTransitioning(false)

    local configOK, configErr = pcall(function() presetAddon:OpenConfigMenu() end)
    check("appearance.presets.ui.opens", configOK, configErr)
    for _, presetID in ipairs(expectedOrder) do
        exists("appearance.presets.ui.button." .. presetID,
            presetEnv["StatsProAppearancePreset" .. presetID:gsub("[^%w]", "")])
    end
    local runtime = presetTest.profileRuntimeState()
    local uiRoot = presetTest.profileState().root
    uiRoot.characters[runtime.activeGUID].specProfiles[999] = activeProfileID
    userInteract("appearance.presets.ui.preview_button",
        presetEnv.StatsProAppearancePresetmidnight, "OnClick")
    eq("appearance.presets.ui.preview_wired", service.state().presetID, "midnight")
    eq("appearance.presets.ui.preview_tile_selected",
        presetEnv.StatsProAppearancePresetmidnight.statsProSelected, true)
    local presetUI = presetAddon.appearancePresets.ui
    eq("appearance.presets.ui.apply_visible", presetUI.apply:IsShown(), true)
    eq("appearance.presets.ui.cancel_visible", presetUI.cancel:IsShown(), true)
    eq("appearance.presets.ui.shared_warning_visible", presetUI.warning:IsShown(), true)
    check("appearance.presets.ui.shared_warning_text",
        presetUI.warning:GetText():find("2", 1, true) ~= nil)
    local _, _, _, _, sharedBodyY = presetUI.lowerBody:GetPoint()
    eq("appearance.presets.ui.shared_preview_body_y", sharedBodyY,
        presetUI.warningY - 42 - 32)
    presetUI.refreshLayout(true, false)
    local _, _, _, _, unsharedBodyY = presetUI.lowerBody:GetPoint()
    eq("appearance.presets.ui.unshared_preview_body_y", unsharedBodyY,
        presetUI.warningY - 32)
    presetAddon.appearancePresets.RefreshUI()
    local _, _, _, _, restoredSharedBodyY = presetUI.lowerBody:GetPoint()
    eq("appearance.presets.ui.shared_preview_layout_restored",
        restoredSharedBodyY, sharedBodyY)
    presetEnv.StatsProConfigFrame:Hide()
    eq("appearance.presets.ui.config_hide_cancels", service.state().active, false)
    eq("appearance.presets.ui.config_hide_zero_writes",
        presetTest.profileState().settings.appearancePresetID, "high-contrast")

    presetEnv.StatsProConfigFrame:Show()
    presetEnv.StatsProFontSlider:SetValue(15)
    userInteract("appearance.presets.manual_slider.change",
        presetEnv.StatsProFontSlider, "OnValueChanged", 15)
    eq("appearance.presets.manual_slider_marks_custom",
        presetTest.profileState().settings.appearancePresetID, "custom")
    check("appearance.presets.manual_slider_refreshes_status",
        presetUI.status:GetText():find("Custom", 1, true) ~= nil)
    ok = service.startPreview("high-contrast")
    eq("appearance.presets.nonvisual.prepare_preview", ok, true)
    ok = service.applyPreview()
    eq("appearance.presets.nonvisual.prepare_apply", ok, true)
    presetEnv.StatsProScaleSlider:SetValue(1.2)
    userInteract("appearance.presets.nonvisual_slider.change",
        presetEnv.StatsProScaleSlider, "OnValueChanged", 1.2)
    eq("appearance.presets.nonvisual_slider_preserves_marker",
        presetTest.profileState().settings.appearancePresetID, "high-contrast")

    presetEnv.StatsProMatchColorCheck:SetChecked(false)
    userInteract("appearance.presets.manual_checkbox.change",
        presetEnv.StatsProMatchColorCheck, "OnClick")
    eq("appearance.presets.manual_checkbox_marks_custom",
        presetTest.profileState().settings.appearancePresetID, "custom")
    check("appearance.presets.manual_checkbox_refreshes_status",
        presetUI.status:GetText():find("Custom", 1, true) ~= nil)
    ok = service.startPreview("high-contrast")
    eq("appearance.presets.manual_outline.prepare_preview", ok, true)
    ok = service.applyPreview()
    eq("appearance.presets.manual_outline.prepare_apply", ok, true)
    selectDropdownValue("appearance.presets.manual_outline.change",
        presetEnv.StatsProTextOutlineDropdown, "none")
    eq("appearance.presets.manual_outline_marks_custom",
        presetTest.profileState().settings.appearancePresetID, "custom")
    check("appearance.presets.manual_outline_refreshes_status",
        presetUI.status:GetText():find("Custom", 1, true) ~= nil)
    ok = service.startPreview("high-contrast")
    eq("appearance.presets.color.prepare_preview", ok, true)
    ok = service.applyPreview()
    eq("appearance.presets.color.prepare_apply", ok, true)

    local critSwatch
    for _, frame in ipairs(presetEnv.__frames) do
        if frame.statsProColorKey == "crit" then critSwatch = frame break end
    end
    exists("appearance.presets.color.swatch", critSwatch)
    local colorBefore = deepCopy(presetTest.profileState().settings.colors.crit)
    userInteract("appearance.presets.color.cancel.open", critSwatch, "OnClick")
    presetEnv.__setColorPickerRGB(0.41, 0.42, 0.43)
    presetEnv.ColorPickerFrame.colorPickerOptions.swatchFunc()
    eq("appearance.presets.color.preview_keeps_marker",
        presetTest.profileState().settings.appearancePresetID, "high-contrast")
    presetEnv.__cancelColorPicker()
    eq("appearance.presets.color.cancel_keeps_marker",
        presetTest.profileState().settings.appearancePresetID, "high-contrast")
    assertDeepEqual("appearance.presets.color.cancel_restores",
        presetTest.profileState().settings.colors.crit, colorBefore)
    userInteract("appearance.presets.color.accept.open", critSwatch, "OnClick")
    presetEnv.__setColorPickerRGB(0.51, 0.52, 0.53)
    presetEnv.ColorPickerFrame.colorPickerOptions.swatchFunc()
    presetEnv.__acceptColorPicker()
    eq("appearance.presets.color.accept_marks_custom",
        presetTest.profileState().settings.appearancePresetID, "custom")
    check("appearance.presets.color.accept_refreshes_status",
        presetUI.status:GetText():find("Custom", 1, true) ~= nil)

    ok = service.startPreview("midnight")
    eq("appearance.presets.manager.preview", ok, true)
    userInteract("appearance.presets.manager.open",
        presetEnv.StatsProManageProfilesButton, "OnClick")
    eq("appearance.presets.manager.cancels_preview", service.state().active, false)

    service.markCustom(presetTest.profileState().settings)
    eq("appearance.presets.manual_edit_custom", service.currentID(), "custom")
    presetTest.profileState().settings.scale = 1.1
    eq("appearance.presets.nonvisual_stays_custom",
        presetTest.profileState().settings.appearancePresetID, "custom")

    local legacyEnv, _, legacyTest = loadStatsPro("enUS", withProfileIdentity())
    fireEvent("appearance.presets.legacy.pew", legacyEnv, "PLAYER_ENTERING_WORLD")
    legacyTest.profileState().settings.appearancePresetID = nil
    eq("appearance.presets.legacy_missing_marker_custom",
        legacyTest.appearancePresets.currentID(), "custom")
    eq("appearance.presets.legacy_zero_write",
        rawget(legacyTest.profileState().settings, "appearancePresetID"), nil)
end

do
    local inCombat = false
    local gateEnv, _, gateTest = loadStatsPro("enUS", withProfileIdentity({
        inCombatLockdown = function() return inCombat end,
    }))
    fireEvent("appearance.presets.gates.pew", gateEnv, "PLAYER_ENTERING_WORLD")
    local service = gateTest.appearancePresets
    local before = deepCopy(gateTest.profileState().root)
    inCombat = true
    local ok, reason = service.startPreview("midnight")
    eq("appearance.presets.gates.combat_rejected", ok, false)
    eq("appearance.presets.gates.combat_reason", reason, "combat")
    assertDeepEqual("appearance.presets.gates.combat_zero_writes",
        gateTest.profileState().root, before)
    inCombat = false
    ok = service.startPreview("midnight")
    eq("appearance.presets.gates.preview_before_combat", ok, true)
    inCombat = true
    service.setRuntimeFailureCount(1)
    fireEvent("appearance.presets.gates.combat_event", gateEnv, "PLAYER_REGEN_DISABLED")
    eq("appearance.presets.gates.combat_auto_cancel", service.state().active, false)
    assertDeepEqual("appearance.presets.gates.cancel_in_combat_zero_writes",
        gateTest.profileState().root, before)
end

print(string.format("StatsPro smoke: PASS (%d assertions)", assertionCount))
