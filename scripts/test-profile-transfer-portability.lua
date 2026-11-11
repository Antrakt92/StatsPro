local fixtures = assert(loadfile("scripts/smoke.lua"))("fixtures")

for _, forever in ipairs({ false, true }) do
    local wideEnv, wide = fixtures.loadStatsPro("enUS", { forever = forever, uiParentWidth = 7680 })
    wideEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    local env, addon, test = fixtures.loadStatsPro("enUS", {
        forever = forever, uiParentWidth = 1920,
        unitGUID = function() return "Player-1-PORTABLE" end,
        getSpecialization = function() return 1 end,
        specID = 73,
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    local positions = { point = "RIGHT", relativePoint = "LEFT", xOfs = 4400, yOfs = -3300 }
    local sections = { layout = true }
    local code = assert(wide.profileTransfer.Serialize("Wide layout", positions, sections))
    assert(addon.profileTransfer.Serialize("Wide layout", positions, sections) == code,
        "layout export changed with the viewport")
    local package = assert(addon.profileTransfer.Parse(code))
    assert(package.values.xOfs == 4400, "layout import lost the original offset")
    local state = test.profileRuntimeState()
    local imported = assert(addon.profileOps.ImportTransferToContext(
        package, sections, state.activeGUID, state.activeSpecID))
    local saved = addon.dbRuntime.GetActiveSettings()
    assert(imported and saved.xOfs == 4400 and saved.yOfs == -3300,
        "import transaction lost the original offsets")
    local _, _, _, visibleX = env.StatsProFrame:GetPoint()
    assert(visibleX ~= 4400, "narrow viewport used the original off-screen offset")
    env.__fireEvent("PLAYER_LOGOUT")
    assert(saved.xOfs == 4400 and saved.yOfs == -3300, "logout overwrote the original offsets")
    env.UIParent:SetWidth(7680)
    env.__fireEvent("DISPLAY_SIZE_CHANGED")
    env.__flushTimers(0)
    local _, _, _, restoredX, projectedY = env.StatsProFrame:GetPoint()
    assert(restoredX == 4400 and projectedY ~= -3300, "viewport axes did not restore independently")
    env.StatsProFrame.scripts.OnDragStart()
    env.StatsProFrame:ClearAllPoints()
    env.StatsProFrame:SetPoint("CENTER", env.UIParent, "CENTER", 32, -64)
    env.StatsProFrame.scripts.OnDragStop()
    assert(saved.xOfs == 32 and saved.yOfs == -64, "explicit drag did not replace the portable position")
    rawset(env.StatsProFrame, "GetPoint", function() return "CENTER", env.UIParent, "CENTER", 90, nil end)
    env.__fireEvent("PLAYER_LOGOUT")
    assert(saved.xOfs == 32 and saved.yOfs == -64, "incomplete frame anchor corrupted the saved position")
end

print("Retail and Forever profile transfer positions passed")
