-- Count native font mutations and width reads; these are deterministic work
-- regressions, not a frame-time benchmark or proof of native visual latency.
local fixtures = assert(loadfile("scripts/smoke.lua"))("fixtures")
local checks = 0
local function check(ok, message)
    checks = checks + 1
    assert(ok, message)
end

for _, forever in ipairs({ false, true }) do
    local fonts = {
        { name = "Hover A", path = "Interface\\AddOns\\Media\\HoverA.ttf" },
        { name = "Hover B", path = "Interface\\AddOns\\Media\\HoverB.ttf" },
        { name = "Neucha", path = "Interface\\AddOns\\AntraktFonts\\fonts\\Neucha.ttf" },
    }
    local counts = { setFont = 0, ownedFont = 0, hudOwned = 0, width = 0 }
    local hudObjects = {}
    local env, addon, test = fixtures.loadStatsPro("enUS", {
        forever = forever, lsmFonts = fonts, isKnownFontFile = function() return true end,
        unitGUID = function() return "Player-HoverFixture" end,
        getSpecialization = function() return 1 end, specID = 73,
        specName = "Protection", specRole = "TANK", primaryStat = 1,
        getCritChance = function() return 12 end,
        setFontResult = function() counts.setFont = counts.setFont + 1; return true end,
        fontObjectSetFontResult = function(object)
            counts.ownedFont = counts.ownedFont + 1
            if hudObjects[object] then counts.hudOwned = counts.hudOwned + 1 end
            return true
        end,
    })
    local setDropdownWidth=env.UIDropDownMenu_SetWidth
    env.UIDropDownMenu_SetWidth=function(control,width)
        setDropdownWidth(control,width)
        control:SetWidth(width+50) -- Native template includes two 25px end caps.
    end
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    check(addon:RunUpdateStatsSafe(), "initial HUD renders")
    addon:OpenConfigMenu()
    local picker = addon.settingsUI.fontPicker
    picker.Show(addon)
    local state = test.panelFontState()
    hudObjects[state.mainOwnedFontObject], hudObjects[state.sideOwnedFontObject] = true, true
    for _, regions in ipairs({ state.mainFontRegions, state.sideFontRegions }) do
        for _, region in ipairs(regions) do
            local original = region.GetStringWidth
            region.GetStringWidth = function(self, ...)
                counts.width = counts.width + 1
                return original(self, ...)
            end
        end
    end
    local buttons = {}
    for _, button in ipairs(picker.buttons) do buttons[button.fontName] = button end
    local first, second = assert(buttons["Hover A"]), assert(buttons["Hover B"])
    local function enter(button) button.scripts.OnEnter(button) end
    local function leave(button)
        button.scripts.OnLeave(button)
        return env.__timers[#env.__timers].fn
    end
    local function reset() counts.setFont, counts.ownedFont, counts.hudOwned, counts.width = 0, 0, 0, 0 end
    local function idle(message)
        check(counts.setFont == 0 and counts.ownedFont == 0 and counts.width == 0, message)
    end
    local function applied(path) return test.panelFontState().mainAppliedFont == path end
    local configBefore = test.configFontState()
    local configBaseline, catalogRegions, closeRegions, fieldRegions = {}, {}, {}, {}
    for _, button in ipairs(picker.buttons) do catalogRegions[button.text] = true end
    for _, trigger in ipairs(addon.settingsDesign.dropdownTriggers) do fieldRegions[trigger.statsProText] = true end
    local controls = {env.StatsProFontDropdown,env.StatsProLanguageDropdown,env.StatsProTextOutlineDropdown}
    local geometry = {}
    local anchorWrites=0
    for _, control in ipairs(controls) do
        geometry[control] = {point={control:GetPoint()},width=control:GetWidth(),height=control:GetHeight()}
        local clear,set=control.ClearAllPoints,control.SetPoint
        control.ClearAllPoints=function(...) anchorWrites=anchorWrites+1;return clear(...) end
        control.SetPoint=function(...) anchorWrites=anchorWrites+1;return set(...) end
        local label=control.statsProLabel
        local measure=label.GetStringWidth
        label.GetStringWidth=function(region)
            local font=region:GetFont()
            if font==first.fontPath then return 205 end
            if font==second.fontPath then return 20 end
            return measure(region)
        end
    end
    local function stableGeometry()
        check(anchorWrites==0,'preview never clears or rewrites the stationary field anchors')
        for _,control in ipairs(controls) do
            local before=geometry[control];local point={control:GetPoint()}
            for i=1,5 do check(point[i]==before.point[i],'font/language preview cannot move an Appearance field anchor') end
            check(control:GetWidth()==before.width and control:GetHeight()==before.height,'preview keeps field dimensions fixed')
        end
        local fontField=env.StatsProFontDropdown
        local right=select(4,fontField:GetPoint())+fontField:GetWidth()+4+addon.sharedFonts.marker:GetWidth()
        check(right<=addon.settingsUI.context.scrollChildWidth,'field and info marker stay inside the viewport with native template padding')
    end
    for _, entry in ipairs(configBefore.entries) do
        local path, size, flags = entry.region:GetFont()
        configBaseline[entry.region] = {path=path,size=size,flags=flags,text=entry.region:GetText()}
        if entry.region:GetText() == "×" then closeRegions[entry.region] = true end
    end
    local function menuFont(path, unchangedText)
        stableGeometry()
        for _, entry in ipairs(test.configFontState().entries) do
            local baseline = configBaseline[entry.region]
            if baseline then
                local actual, size, flags = entry.region:GetFont()
                check(actual == ((catalogRegions[entry.region] or closeRegions[entry.region] or fieldRegions[entry.region]) and baseline.path or path), 'Settings text follows hover while catalogue, field captions and close icons stay readable')
                check(size == baseline.size and addon.fontRuntime.semanticFlags(flags) == addon.fontRuntime.semanticFlags(baseline.flags), 'hover preserves semantic role size and outline flags')
                if unchangedText then check(entry.region:GetText() == baseline.text, 'font preview restores every region text after mutation') end
            end
        end
    end
    local function menuRestored()
        for region, baseline in pairs(configBaseline) do
            local actual, size, flags = region:GetFont()
            check(actual == baseline.path and size == baseline.size and addon.fontRuntime.semanticFlags(flags) == addon.fontRuntime.semanticFlags(baseline.flags), 'leave/cancel/selection restores each committed Settings font')
        end
    end
    local root, settings = test.profileState().root, test.profileState().settings
    local saved = settings.font

    reset()
    picker.Hide(addon)
    idle("closing untouched picker performs no font mutations or width reads")
    picker.Show(addon)
    reset()
    enter(first)
    check(applied(first.fontPath), "first hover applies immediately")
    menuFont(first.fontPath, true)
    check(counts.ownedFont > 0 and counts.width > 0, "hover exercises actual HUD mutation and measurement")
    local firstSets, firstOwned, firstWidths = counts.setFont, counts.ownedFont, counts.width
    local staleLeave = leave(first)
    reset()
    env.__flushTimers(0)
    idle("row gap does not immediately restore and remeasure committed font")
    check(applied(first.fontPath), "row gap retains current preview until next hover")
    enter(second)
    check(applied(second.fontPath), "next hover applies immediately without a delayed callback")
    menuFont(second.fontPath, true)
    check(counts.setFont <= firstSets and counts.ownedFont <= firstOwned and counts.width <= firstWidths,
        "adjacent hover performs at most one font mutation and measurement pass")
    check(settings.font == saved and test.profileState().root == root and test.profileState().settings == settings,
        "hover preserves saved preference and profile graph identities")
    reset()
    staleLeave()
    idle("previous row leave callback cannot overwrite next preview")
    enter(second)
    idle("reentering same preview performs no duplicate native work")

    -- Closing restores once; a previously queued leave must become inert.
    staleLeave = leave(second)
    picker.Hide(addon)
    check(applied(saved), "closing restores committed font")
    menuRestored()
    reset()
    staleLeave()
    idle("closed picker ignores stale leave callback")

    picker.Show(addon)
    enter(first)
    staleLeave = leave(first)
    reset()
    second.scripts.OnClick(second)
    check(settings.font == second.fontPath and applied(second.fontPath), "click commits selected row")
    menuRestored()
    check(counts.hudOwned == 2, "click applies each panel font once while ending the separate Settings demonstration")
    check(counts.width > 0 and counts.width <= firstWidths,
        "click performs one HUD measurement pass without repeating on close")
    reset()
    staleLeave()
    idle("stale leave cannot undo committed row")

    picker.Show(addon)
    reset()
    enter(second)
    check(counts.hudOwned == 0 and counts.width == 0, "hovering selected font only demonstrates Settings without reapplying or measuring HUD")
    menuFont(second.fontPath, false)
    check(applied(second.fontPath) and settings.font == second.fontPath,
        "selected row hover retains committed font and preference")
    picker.Hide(addon)

    picker.Show(addon)
    enter(first)
    staleLeave = leave(first)
    picker.Hide(addon)
    picker.Show(addon)
    enter(second)
    reset()
    staleLeave()
    idle("previous picker session cannot mutate reopened preview")
    check(applied(second.fontPath), "reopened picker retains current hover")

    -- A pending exit cannot apply style while another profile transaction owns it.
    enter(first)
    staleLeave = leave(first)
    addon.profileRuntime.transitioning = true
    reset()
    staleLeave()
    idle("queued leave respects active profile transition")
    addon.profileRuntime.transitioning = false
    picker.Hide(addon)
    check(applied(settings.font), "safe close restores latest committed preference")

    -- Leaving the list entirely still restores after the bounded exit grace.
    picker.Show(addon)
    enter(first)
    leave(first)
    env.__flushTimers(0.2)
    check(applied(settings.font), "actual list exit restores committed font after grace")
    picker.Hide(addon)
    picker.Show(addon)
    enter(first)
    addon.settingsUI.localization.Preview(addon, 'zhTW')
    picker.CancelPreview(addon)
    check(addon.fontRuntime.configPreviewBaseFont == nil, 'equal-base locale fallback cancellation clears temporary Settings preview state')
    local refreshes = 0
    test.addConfigRefresherForSmoke(function() refreshes = refreshes + 1 end)
    reset()
    check(not picker.CancelPreview(addon), 'a second completed cancellation is a no-op')
    idle('completed equal-base cancellation causes no native work on a second exit')
    check(refreshes == 0, 'completed cancellation never repeats Settings control refresh')
    addon.settingsUI.localization.CancelPreview(addon)
    picker.Hide(addon)
    -- Neucha's actual asset has no U+00D7: close icons must keep their baseline.
    local neucha = assert(buttons["Neucha"])
    local icon, baseline
    for region in pairs(closeRegions) do icon, baseline = region, configBaseline[region]; break end
    check(icon ~= nil, 'fixture includes an actual styled close icon')
    picker.Show(addon); enter(neucha)
    check(icon:GetFont() == baseline.path and icon:GetText() == "×", 'Neucha hover never applies its missing multiplication glyph to close icons')
    local lateClose = env.CreateFrame('Button', nil, addon.settingsUI.frame, 'UIPanelCloseButton')
    addon.settingsDesign.StyleCloseButton(lateClose)
    local lateText = lateClose.statsProCloseText
    check(lateText:GetFont() == baseline.path and lateText.statsProFontPreviewIndependent == true,
        'a close icon registered during hover immediately inherits the readable baseline')
    local lateLabel = addon.settingsUI.frame:CreateFontString(nil, 'OVERLAY')
    addon.settingsDesign.ApplyTextRole(lateLabel, 'body')
    lateLabel:SetText('Late preview label')
    check(lateLabel:GetFont() == neucha.fontPath, 'late independent icon registration never resets ordinary preview text')
    leave(neucha); env.__flushTimers(.2)
    check(icon:GetFont() == baseline.path and lateText:GetFont() == baseline.path,
        'leaving Neucha preserves original and late close icons')
    enter(neucha); picker.Hide(addon)
    check(icon:GetFont() == baseline.path and lateText:GetFont() == baseline.path
        and lateLabel:GetFont() == baseline.path, 'cancellation restores ordinary text while close icons stay on baseline')
    addon.settingsUI.dropdownMenu.Toggle(addon,env.StatsProLanguageDropdown)
    local menu=addon.settingsUI.dropdownMenu
    local anchor={menu.frame:GetPoint()}
    for _,row in ipairs(menu.buttons) do
        if row:IsShown() and row.info then
            row.scripts.OnEnter(row)
            stableGeometry()
            local current={menu.frame:GetPoint()}
            for i=1,5 do check(current[i]==anchor[i],'hovering a language cannot reanchor its open menu') end
        end
    end
    addon.settingsUI.dropdownMenu.Hide(addon)
    stableGeometry()
end
print("StatsPro font hover: PASS (" .. checks .. " checks)")
