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

    local font = "Interface\\AddOns\\AntraktFonts\\fonts\\DejaVuSans.ttf"
    local oldSettings = { font = "Fonts\\ARIALN.TTF", fontBeforeAutoSwitch = font }
    local appearance = { appearance = true }
    local fontCode = assert(addon.profileTransfer.Serialize("Legacy font", oldSettings, appearance))
    local fontPackage = assert(addon.profileTransfer.Parse(fontCode))
    local transferred = assert(addon.profileTransfer.BuildImportedSettings({}, fontPackage, appearance))
    assert(transferred.font == font and transferred.fontBeforeAutoSwitch == nil,
        "appearance transfer lost the legacy preferred font")
end

for _, forever in ipairs({ false, true }) do
    for _, failure in ipairs({ "early-event", "SetPoint", "SetUserPlaced", "persistent" }) do
        local env, addon, test = fixtures.loadStatsPro("enUS", {
            forever = forever, uiParentWidth = 1920,
            unitGUID = function() return "Player-1-VIEWPORT" end,
            getSpecialization = function() return 1 end, specID = 73,
        })
        env.__fireEvent("PLAYER_ENTERING_WORLD")
        local sections = { layout = true }
        local payload = assert(addon.profileTransfer.Serialize("Wide layout", {
            point = "RIGHT", relativePoint = "LEFT", xOfs = 4400, yOfs = 0,
        }, sections))
        local state = test.profileRuntimeState()
        assert(addon.profileOps.ImportTransferToContext(assert(addon.profileTransfer.Parse(payload)),
            sections, state.activeGUID, state.activeSpecID))
        local frame = env.StatsProFrame
        local function anchorX() return select(4, frame:GetPoint()) end
        local fallback = anchorX()
        assert(fallback ~= 4400)
        local method = failure == "persistent" and "SetUserPlaced" or failure
        local setter = frame[method]
        local failures = 0
        if failure == "early-event" then
            env.__fireEvent("DISPLAY_SIZE_CHANGED")
            env.__flushTimers(0)
            env.UIParent:SetWidth(7680)
        else
            rawset(frame, method, function(self, ...)
                if failure == "persistent" or failures == 0 then
                    failures = failures + 1
                    error("synthetic viewport positioning failure")
                end
                return setter(self, ...)
            end)
            env.UIParent:SetWidth(7680)
            env.__fireEvent("DISPLAY_SIZE_CHANGED")
            env.__flushTimers(0)
            assert(anchorX() == fallback, "failed reposition keeps the former anchor")
        end
        env.__flushTimers(1)
        if failure == "persistent" then
            assert(failures > 1 and failures <= 3 and anchorX() == fallback, "viewport retries are bounded")
            rawset(frame, method, setter)
            env.__fireEvent("UI_SCALE_CHANGED")
            env.__flushTimers(1)
        end
        assert(anchorX() == 4400, "viewport change restores the saved position after " .. failure)
        assert(addon.dbRuntime.GetActiveSettings().xOfs == 4400, "viewport does not rewrite the saved position")
    end
end

print("Retail and Forever profile transfer positions and fonts passed")
