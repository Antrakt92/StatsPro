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
    }
    local counts = { setFont = 0, ownedFont = 0, width = 0 }
    local env, addon, test = fixtures.loadStatsPro("enUS", {
        forever = forever, lsmFonts = fonts, isKnownFontFile = function() return true end,
        unitGUID = function() return "Player-HoverFixture" end,
        getSpecialization = function() return 1 end, specID = 73,
        specName = "Protection", specRole = "TANK", primaryStat = 1,
        getCritChance = function() return 12 end,
        setFontResult = function() counts.setFont = counts.setFont + 1; return true end,
        fontObjectSetFontResult = function() counts.ownedFont = counts.ownedFont + 1; return true end,
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    check(addon:RunUpdateStatsSafe(), "initial HUD renders")
    addon:OpenConfigMenu()
    local picker = addon.settingsUI.fontPicker
    picker.Show(addon)
    local state = test.panelFontState()
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
    local function reset() counts.setFont, counts.ownedFont, counts.width = 0, 0, 0 end
    local function idle(message)
        check(counts.setFont == 0 and counts.ownedFont == 0 and counts.width == 0, message)
    end
    local function applied(path) return test.panelFontState().mainAppliedFont == path end
    local root, settings = test.profileState().root, test.profileState().settings
    local saved = settings.font

    reset()
    picker.Hide(addon)
    idle("closing untouched picker performs no font mutations or width reads")
    picker.Show(addon)
    reset()
    enter(first)
    check(applied(first.fontPath), "first hover applies immediately")
    check(counts.ownedFont > 0 and counts.width > 0, "hover exercises actual HUD mutation and measurement")
    local firstSets, firstOwned, firstWidths = counts.setFont, counts.ownedFont, counts.width
    local staleLeave = leave(first)
    reset()
    env.__flushTimers(0)
    idle("row gap does not immediately restore and remeasure committed font")
    check(applied(first.fontPath), "row gap retains current preview until next hover")
    enter(second)
    check(applied(second.fontPath), "next hover applies immediately without a delayed callback")
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
    reset()
    staleLeave()
    idle("closed picker ignores stale leave callback")

    picker.Show(addon)
    enter(first)
    staleLeave = leave(first)
    reset()
    second.scripts.OnClick(second)
    check(settings.font == second.fontPath and applied(second.fontPath), "click commits selected row")
    check(counts.ownedFont == 2, "click applies each panel font once without repeating on close")
    check(counts.width > 0 and counts.width <= firstWidths,
        "click performs one HUD measurement pass without repeating on close")
    reset()
    staleLeave()
    idle("stale leave cannot undo committed row")

    picker.Show(addon)
    reset()
    enter(second)
    idle("hovering selected font after commit performs no native work")
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
end
print("StatsPro font hover: PASS (" .. checks .. " checks)")
