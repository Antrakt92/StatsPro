-- Shared recovery must work independently of client language and addon flavor.
local forever = arg and arg[1] == "forever"
assert(not arg or not arg[1] or forever, "expected optional forever flavor")
local flavor = forever and "Forever" or "Retail"
local fixtures = assert(loadfile("scripts/smoke.lua"))("fixtures")
local function loadStatsPro(locale, options)
    options = options or {}
    options.forever = forever
    local env, addon, test = fixtures.loadStatsPro(locale, options)
    assert((addon.forever and addon.forever.enabled == true or false) == forever,
        "recovery fixture loads the requested flavor")
    return env, addon, test
end
-- Retail may report THICKOUTLINE with its implied OUTLINE bit set.
do
    local secret={}
    local _,addon=loadStatsPro('enUS',{issecretvalue=function(value) return value==secret end})
    for _,case in ipairs({
        {'THICKOUTLINE','OUTLINE, THICKOUTLINE',true},
        {'THICKOUTLINE',' THICKOUTLINE , OUTLINE ',true},
        {'OUTLINE, THICKOUTLINE','THICKOUTLINE',true},
        {'MONOCHROME,THICKOUTLINE','OUTLINE, MONOCHROME, THICKOUTLINE',true},
        {'OUTLINE',' OUTLINE ',true},
        {'','',true},
        {'THICKOUTLINE','OUTLINE',false},
        {'THICKOUTLINE','',false},
        {'OUTLINE','THICKOUTLINE',false},
        {'THICKOUTLINE','THICKOUTLINE,MONOCHROME',false},
        {'THICKOUTLINE','THICKOUTLINE,UNKNOWN',false},
        {'THICKOUTLINE','THICKOUTLINE,,OUTLINE',false},
        {'THICKOUTLINE','THICKOUTLINE,THICKOUTLINE',false},
        {'THICKOUTLINE',string.rep(' ',129)..'THICKOUTLINE',false},
        {'THICKOUTLINE',secret,false},
        {secret,'THICKOUTLINE',false},
    }) do
        local region={GetFont=function() return 'Fonts\\ARIALN.TTF',14,case[2] end}
        assert(addon.fontRuntime.matchesAppliedFont(region,'Fonts\\ARIALN.TTF',14,case[1])==case[3],
            'bounded semantic font flag comparison: '..tostring(case[1])..' / '..tostring(case[2]))
    end
end
for _,style in ipairs({'none','outline','thick'}) do
    local env,addon,test=loadStatsPro('enUS',{
        statsProDB={textOutlineStyle=style},
        setFontResult=function(region)
            if not region.normalizedFontReadback then
                region.normalizedFontReadback=true
                local original=region.GetFont
                region.GetFont=function(self)
                    local path,size,flags=original(self)
                    if flags=='THICKOUTLINE' then flags='OUTLINE, THICKOUTLINE' end
                    return path,size,flags
                end
            end
            return true
        end,
    })
    env.__fireEvent('PLAYER_ENTERING_WORLD')
    addon:OpenConfigMenu()
    assert(test.panelFontState().mainAppliedTextOutlineStyle==style,'native normalized readback preserves '..style..' HUD style')
    for _,path in ipairs({'Fonts\\ARIALN.TTF','Fonts\\FRIZQT__.TTF'}) do
        assert(addon.fontRuntime.applyCommittedTextStyle(path,14,true,true),'normalized readback permits subsequent style/font recovery')
        local state=test.panelFontState()
        assert(state.mainAppliedTextOutlineStyle==style,'recovery retains requested '..style..' style')
        for _,region in ipairs(state.mainFontRegions) do
            assert(addon.fontRuntime.matchesAppliedFont(region,state.mainAppliedFont,14,state.mainAppliedFontFlags),
                'every actual HUD region verifies normalized flags after recovery')
        end
    end
end
print(flavor .. ' normalized font flag readback regressions passed')
for _, client in ipairs({ "enUS", "ruRU" }) do
    local activated = {}
    local env, addon, test = loadStatsPro(client, {
        lsmFonts = {},
        isKnownFontFile = function() return true end,
        setFontResult = function(_, path) return activated[path] == true end,
        fontObjectSetFontResult = function(object, path)
            if object.name == "StatsProFontAssetActivator" then activated[path] = true end
            return true
        end,
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    addon:OpenConfigMenu()
    for index, entry in ipairs(test.configFontState().entries) do
        if index > 22 then break end
        local path, size, flags = entry.region:GetFont()
        entry.region:SetFont(path, size, flags)
    end
    for _, locale in ipairs({ "ruRU", "koKR", "zhCN", "zhTW", "enUS" }) do
        addon.settingsUI.localization.Preview(addon, locale)
        local requirement = test.registrySnapshot().localeGlyphReq[locale]
        local state = test.panelFontState()
        assert(test.fontSupports(state.mainAppliedFont, requirement), client .. ": readable HUD for " .. locale)
        for _, entry in ipairs(test.configFontState().entries) do
            assert(test.fontSupports(entry.actualFont, requirement), client .. ": readable Settings for " .. locale)
        end
        addon.settingsUI.localization.CancelPreview(addon)
    end
end
print(flavor .. " cross-language cold-font regressions passed")

-- A client exposing only the namespaced money API must still render both gear rows.
for _, mode in ipairs({ "modern", "modern-only", "legacy", "missing", "throwing",
    "nil-return", "number-return", "empty-return", "secret-return" }) do
    local env, addon, test = loadStatsPro("enUS", {
        statsProDB = { showDurability = true, showRepairCost = true },
        getInventoryItemDurability = function(slot)
            if slot == 1 then return 70, 100 end
        end,
        getTooltipInventoryItem = function() return { repairCost = 4458354 } end,
        issecretvalue = function(value) return value == "restricted-money" end,
    })
    local legacy = env.GetCoinTextureString
    if mode ~= "legacy" then env.GetCoinTextureString = nil end
    if mode == "modern" or mode == "modern-only" then
        env.C_CurrencyInfo = { GetCoinTextureString = legacy }
        if mode == "modern" then env.GetCoinTextureString = function() error("modern API must take priority") end end
    elseif mode == "throwing" then
        env.C_CurrencyInfo = { GetCoinTextureString = function() error("formatter unavailable") end }
    elseif mode:find("-return", 1, true) then
        env.C_CurrencyInfo = { GetCoinTextureString = function()
            if mode == "number-return" then return 42 end
            if mode == "empty-return" then return "" end
            if mode == "secret-return" then return "restricted-money" end
        end }
    end
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    assert(addon:RunUpdateStatsSafe(), mode .. ": repair formatting must not abort HUD rendering")
    assert(env.StatsProFrame:IsShown(), mode .. ": HUD remains visible")
    local state = test.durabilityState()
    assert(state.durabilityValue == 70 and state.repairCost == 4458354, mode .. ": gear data remains complete")
    local text = test.formatRepairCost(4458354, 15)
    assert(text == ((mode == "modern" or mode == "modern-only" or mode == "legacy") and "coin:4458354:15" or "?"), mode .. ": repair display")
end
print(flavor .. " money API and HUD recovery regressions passed")

for _, costReadyOnWake in ipairs({ true, false }) do
    local slot = forever and 18 or 1
    local equippedID, reads, cost = 1337, 0, nil
    local env, addon, test = loadStatsPro("enUS", {
        statsProDB = { showDurability = true, showRepairCost = true },
        getInventoryItemDurability = function(index)
            if index == slot then return 80, 100 end
        end,
        getTooltipInventoryItem = function()
            reads = reads + 1
            return cost and { repairCost = cost } or nil
        end,
    })
    env.GetInventoryItemID = function(_, index) if index == slot then return equippedID end end
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    local limit = test.durabilityState().retryLimit
    env.__fireEvent("GET_ITEM_INFO_RECEIVED", 1337, true)
    assert(not test.durabilityState().dirty, "scheduled retry leaves late readiness available")
    for _ = 1, limit do
        assert(env.__flushNextTimer(), "pending repair schedules its bounded retries")
        assert(addon:RunUpdateStatsSafe(), "pending repair retries render safely")
    end
    local exhausted = test.durabilityState()
    assert(exhausted.durabilityValue == 80 and exhausted.repairCost == nil
        and exhausted.repairRetryAttempt == limit and not exhausted.repairRetryScheduled,
        "readable durability does not prove the repair tooltip is available")
    local before = reads
    env.__fireEvent("ITEM_DATA_LOAD_RESULT", 999, true)
    env.__fireEvent("GET_ITEM_INFO_RECEIVED", 1337, false)
    equippedID = 42
    env.__fireEvent("ITEM_DATA_LOAD_RESULT", 1337, true)
    assert(not test.durabilityState().dirty and reads == before,
        "foreign, failed and stale item callbacks cannot wake repair")
    equippedID = 1337
    if costReadyOnWake then cost = 300 end
    env.__fireEvent("ITEM_DATA_LOAD_RESULT", 1337, true)
    assert(test.durabilityState().dirty and reads == before, "repair-only item readiness coalesces a scan")
    assert(addon:RunUpdateStatsSafe() and reads == before + 1, "late repair readiness runs one scan")
    local after = test.durabilityState()
    assert(after.repairCost == cost and after.repairRetryAttempt == limit and not after.repairRetryScheduled,
        "late readiness applies the result without reopening the retry budget")
    env.__fireEvent("GET_ITEM_INFO_RECEIVED", 1337, true)
    assert(not test.durabilityState().dirty, "duplicate item readiness cannot wake a second scan")
    if not costReadyOnWake then
        cost = 0
        env.__fireEvent("MERCHANT_SHOW")
        assert(addon:RunUpdateStatsSafe() and test.durabilityState().repairCost == 0,
            "new external generation can still recover zero repair cost")
    end
end
print(flavor .. " late repair tooltip recovery regressions passed")

do
    local env, addon, test = loadStatsPro("enUS", {
        unitGUID = function() return "Player-Capacity" end,
        getSpecialization = function() return 1 end, specID = 73, specRole = "TANK",
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    assert(test.profileOps.enableAccountWide(test.profileState().profileID))
    local sections = { stats = true, layout = true, appearance = true }
    local payload = assert(test.profileTransfer.serialize("Capacity", test.profileState().settings, sections))
    local package = assert(test.profileTransfer.parse(payload))
    local reachedLimit = false
    for _ = 1, 150 do
        local before = test.profileState()
        local ok, reason = test.profileOps.importTransferToContext(package, sections)
        if not ok then
            assert(reason == "profile-capacity", "valid profile growth reports the registry node limit")
            local after = test.profileState()
            assert(after.profiles == before.profiles and after.settings == before.settings
                and after.profileID == before.profileID and test.validateRegistry(after.root),
                "capacity rejection preserves the active valid registry")
            local hint = addon.profileUI.OperationErrorText(reason)
            assert(hint:find("Delete unused settings", 1, true), "capacity message identifies manual cleanup")
            local altEnv, altAddon, altTest = loadStatsPro("enUS", {
                statsProDB = after.root,
                unitGUID = function() return "Player-Capacity-Alt" end,
                getSpecialization = function() return 1 end, specID = 73, specRole = "TANK",
            })
            local budget = altAddon.dbRuntime.NewGraphBudget()
            assert(altAddon.dbRuntime.ValidateRegistry(after.root, budget))
            altAddon.dbRuntime.maxGraphNodes = budget.nodes
            altEnv.__fireEvent("PLAYER_ENTERING_WORLD")
            local fallback = altTest.profileState()
            assert(not fallback.characters["Player-Capacity-Alt"] and altEnv.StatsProFrame:IsShown()
                and not altAddon.profileRuntime.pendingResolution,
                "first login at capacity can show existing settings without allocating a profile")
            local wasVisible, xOffset = fallback.settings.isVisible, fallback.settings.xOfs
            altEnv.SlashCmdList.STATSPRO("hide")
            altEnv.StatsProFrame:ClearAllPoints()
            altEnv.StatsProFrame:SetPoint("CENTER", altEnv.UIParent, "CENTER", 500, 100)
            altEnv.__fireEvent("PLAYER_LOGOUT")
            local reset, resetReason = altTest.profileOps.resetProfile(fallback.profileID)
            assert(not reset and resetReason == "profile-capacity"
                and fallback.settings.isVisible == wasVisible and fallback.settings.xOfs == xOffset,
                "capacity fallback protects saved settings from normal operations and logout")
            local function click(button)
                assert(button:IsEnabled(), "expected available profile action")
                button.scripts.OnClick(button)
            end
            altAddon:OpenConfigMenu()
            click(altEnv.StatsProManageProfilesButton)
            click(altEnv.StatsProProfileAdvancedButton)
            assert(not altEnv.StatsProProfileResetButton:IsEnabled(), "fallback disables regular profile changes")
            click(altEnv.StatsProProfileCleanupButton)
            assert(altEnv.StatsProProfileOperationDialog:IsShown(), "manual cleanup offers confirmation")
            click(altEnv.StatsProProfileOperationConfirmButton)
            assert(altAddon.profileRuntime.ResolvePending(), "cleanup retries the new character assignment")
            local recovered = altTest.profileState()
            assert(recovered.characters["Player-Capacity-Alt"] and not altAddon.profileRuntime.capacityFallback,
                "new character receives a normal assignment after cleanup")
            assert(addon.profileUI.OperationErrorText(reason) == "Profile storage is full.",
                "capacity message does not direct users to unavailable cleanup")
            assert(altTest.profileOps.importTransferToContext(assert(altTest.profileTransfer.parse(payload)), sections),
                "cleanup makes room for a retry")
            reachedLimit = true
            break
        end
    end
    assert(reachedLimit, "fixture reaches the real profile storage limit")
end
print(flavor .. " profile capacity recovery regressions passed")

if not forever then
    local rating, percent = 0, 5
    local function readRating() return rating end
    local function readPercent() return percent end
    local env, addon, test = loadStatsPro("enUS", {
        unitGUID = function() return "Player-HideZero" end,
        getSpecialization = function() return 1 end, specID = 64, specRole = "DAMAGER",
        unitClassToken = "MAGE",
        statsProDB = {
            showRating = true, showPercentage = false,
            showOffensive = true, hideZeroOffensive = true,
            showCrit = true, showHaste = true, showMastery = true, showVersatility = true,
            showTertiary = true, hideZeroTertiary = true, showLeech = true, showAvoidance = true, showSpeed = false,
        },
        getCombatRating = readRating,
        getCritChance = readPercent, getHaste = readPercent, getMasteryEffect = readPercent,
        getVersatilityBonus = readPercent, getLifesteal = readPercent, getAvoidance = readPercent,
        issecretvalue = function(value) return value == -1234 or value == -1235 end,
        roundToNearestString = function(value) return value == -1234 and "1234" or "1235" end,
    })
    local archon = assert(loadfile("StatsPro_ArchonTargets.lua"))
    setfenv(archon, env)
    archon()
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    local settings = test.profileState().settings
    local function expectRows(expectedOffensive, expectedTertiary)
        local blocks = test.buildRenderBlocks()
        assert(#blocks[2].labels == expectedOffensive and #blocks[3].labels == expectedTertiary,
            "Hide Zero follows the visible value columns")
        return blocks[2]
    end
    expectRows(0, 0)
    rating = 250
    local contextReads = 0
    local getCurrentSnapshot = addon.archonTargets.GetCurrentSnapshot
    addon.archonTargets.GetCurrentSnapshot = function()
        contextReads = contextReads + 1
        return getCurrentSnapshot()
    end
    local rated = expectRows(4, 2)
    assert(contextReads == 1, "four rated rows share one Archon context")
    assert(type(rated.targetRows[1]) == "table" and rated.targetRows[1].current == 250,
        "rating-only rows retain Archon comparison metadata")
    local snapshot = env.StatsProArchonTargets
    env.StatsProArchonTargets = nil
    contextReads = 0
    local noSnapshot = expectRows(4, 2)
    assert(contextReads == 1 and noSnapshot.targetRows[1] == false and noSnapshot.targetRows[4] == false,
        "four rated rows also share an unavailable Archon context")
    env.StatsProArchonTargets = snapshot
    rating = -1234
    expectRows(4, 2)
    rating = -1235
    expectRows(4, 2)
    rating = 0
    expectRows(0, 0)
    rating = -1234
    expectRows(0, 0)
    rating, percent = 250, 0
    settings.showRating, settings.showPercentage = false, true
    test.cacheSettings()
    expectRows(0, 0)
    settings.showRating = true
    test.cacheSettings()
    expectRows(4, 2)
    rating, percent = 0, 5
    expectRows(4, 2)
    settings.showPercentage, settings.hideZeroOffensive, settings.hideZeroTertiary = false, false, false
    test.cacheSettings()
    expectRows(4, 2)
    print("Retail displayed-column Hide Zero regressions passed")
end

-- A styled FontString can retain its own font even while GetFontObject still
-- identifies the shared parent. Changing that parent must not strand Settings.
for _, failFirst in ipairs({ false, true }) do
    local env, addon, test = loadStatsPro("enUS")
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    addon:OpenConfigMenu()
    local before = test.configFontState()
    local fail = failFirst
    for _, entry in ipairs(before.entries) do
        local region = entry.region
        local originalGet, originalSet = region.GetFont, region.SetFont
        local font, size, flags = region:GetFont()
        local pinned = true
        region.GetFont = function(self)
            if pinned then return font, size, flags end
            return originalGet(self)
        end
        region.SetFont = function(self, path, height, style)
            if fail and path == "Fonts\\ARIALN.TTF" then return false end
            pinned = false
            return originalSet(self, path, height, style)
        end
    end
    if failFirst then
        assert(not test.applyConfigFont("Fonts\\ARIALN.TTF", true), "failed direct fallback remains atomic")
        for index, entry in ipairs(test.configFontState().entries) do
            assert(entry.actualFont == before.entries[index].actualFont, "fallback failure restores every font")
            assert(entry.actualText == before.entries[index].actualText, "fallback failure preserves every label")
        end
        fail = false
    end
    assert(test.applyConfigFont("Fonts\\ARIALN.TTF", true), "same-owner overrides recover through direct Settings update")
    for _, entry in ipairs(test.configFontState().entries) do
        assert(entry.actualFont == "Fonts\\ARIALN.TTF", "every Settings font updates despite local override")
    end
    assert(test.applyConfigFont("Fonts\\2002.ttf", true), "subsequent Korean switch also updates direct regions")
    for _, entry in ipairs(test.configFontState().entries) do
        assert(entry.actualFont == "Fonts\\2002.ttf", "every Settings font switches to Korean")
    end
end
print(flavor .. " Settings inherited-override recovery regressions passed")

-- EditBox:SetFont requires a flags string even when FontString accepts nil.
-- The hidden profile-transfer input participates in the same Settings transaction.
do
    local env, addon, test = loadStatsPro("enUS", { lsmFonts = { { name = "Chinese", path = "Fonts\\ARHei.TTF" } } })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    addon:OpenConfigMenu()
    local input
    for _, entry in ipairs(test.configFontState().entries) do
        if entry.roleKey == "transferInput" then input = entry.region; break end
    end
    assert(input, "real profile-transfer EditBox is registered")
    local font, size, flags = input:GetFont()
    input:SetFont(font, size, flags or "")
    local originalSet = input.SetFont
    input.SetFont = function(self, path, height, style)
        assert(type(style) == "string", "EditBox flags must be a string")
        return originalSet(self, path, height, style)
    end
    for _, path in ipairs({ "Fonts\\ARHei.TTF", "Fonts\\ARIALN.TTF", "Fonts\\2002.ttf" }) do
        local applied, status = test.applyConfigFont(path, true)
        assert(applied, "hidden EditBox must not roll back Settings font switch: " .. tostring(status) .. " " .. tostring(addon.fontRuntime.configFontFailure) .. " " .. tostring(addon.fontRuntime.configFontFailureChild))
        for _, entry in ipairs(test.configFontState().entries) do
            assert(entry.actualFont == path, "all Settings regions receive selected font")
        end
    end
end
print(flavor .. " EditBox font flags regressions passed")

-- A single unavailable Settings region must not strand committed localization.
do
    local function fixture()
        local state = { failures = 1, attempts = 0, combat = false, specID = 73 }
        local env, addon, test = loadStatsPro("enUS", {
            lsmFonts = {},
            unitGUID = function() return "Player-1-SETTINGS-RECOVERY" end,
            getSpecialization = function() return 1 end,
            getSpecializationInfo = function()
                return state.specID, state.specID == 73 and "Protection" or "Arms",
                    nil, nil, state.specID == 73 and "TANK" or "DAMAGER", 1
            end,
            inCombatLockdown = function() return state.combat end,
        })
        env.__fireEvent("PLAYER_ENTERING_WORLD")
        env.__flushTimers(0)
        addon:OpenConfigMenu()
        local input
        for _, entry in ipairs(test.configFontState().entries) do
            if entry.roleKey == "transferInput" then input = entry.region; break end
        end
        assert(input, "recovery uses the real transfer input")
        input:SetFont(input:GetFont())
        local original = input.SetFont
        input.SetFont = function(self, path, height, flags)
            if path == "Fonts\\ARIALN.TTF" then
                state.attempts = state.attempts + 1
                if state.failures > 0 then state.failures = state.failures - 1; return false end
            end
            return original(self, path, height, flags)
        end
        state.env, state.addon, state.test = env, addon, test
        state.select = function(locale)
            local dropdown = env.StatsProLanguageDropdown
            dropdown.dropdownInit()
            for _, info in ipairs(dropdown.dropdownEntries) do
                if info.value == locale then info.func(); return end
            end
            error("missing language " .. locale)
        end
        state.tick = function() addon:RunUpdateStatsSafe() end
        return state
    end

    local once = fixture()
    local before = once.test.profileState()
    local root, settings, profile = before.root, before.settings, before.root.profiles[before.profileID]
    once.select("ruRU")
    once.tick()
    assert(once.attempts == 2, "one-shot region failure retries automatically")
    assert(once.test.configFontState().currentFont == "Fonts\\ARIALN.TTF", "Settings recovers without manual apply")
    assert(once.test.profileState().root == root and once.test.profileState().settings == settings
        and root.profiles[before.profileID] == profile, "font recovery preserves profile graph identities")
    assert(root.account.forceLocale == "ruRU", "recovery preserves committed locale")
    assert(settings.font == "Fonts\\FRIZQT__.TTF" and settings.fontBeforeAutoSwitch == nil, "recovery preserves the preference without creating a synthetic restore field")

    local persistent = fixture()
    persistent.failures = 100
    persistent.select("ruRU")
    for _, delay in ipairs({ 0.2, 1, 3, 5 }) do
        persistent.env.__flushTimers(delay)
        persistent.tick()
    end
    local attempts = persistent.attempts
    for _ = 1, 20 do persistent.env.__flushTimers(10); persistent.tick() end
    assert(attempts == 6 and persistent.attempts == attempts, "persistent Settings failure has a fixed retry budget")

    for _, guard in ipairs({ "combat", "unknown-combat", "transition", "preview", "latest-locale" }) do
        local guarded = fixture()
        guarded.failures = 100
        guarded.select("ruRU")
        local oldAttempts = guarded.attempts
        guarded.failures = 0
        if guard == "combat" then guarded.combat = true
        elseif guard == "unknown-combat" then guarded.combat = nil
        elseif guard == "transition" then guarded.addon.profileRuntime.transitioning = true
        elseif guard == "preview" then guarded.addon.settingsUI.localization.Preview(guarded.addon, "koKR")
        else guarded.select("zhCN") end
        guarded.env.__flushTimers(0.2)
        guarded.tick()
        if guard ~= "latest-locale" then
            assert(guarded.attempts == oldAttempts, guard .. ": retry waits for safe context")
        end
        if guard == "preview" then
            assert(guarded.test.fontSupports(guarded.test.configFontState().currentFont, "Hangul"), "retry preserves hovered script")
            guarded.addon.settingsUI.localization.CancelPreview(guarded.addon)
        elseif guard == "latest-locale" then
            assert(guarded.test.fontSupports(guarded.test.configFontState().currentFont, "Hans"), "old retry cannot restore former locale")
        else
            guarded.combat = false
            guarded.addon.profileRuntime.transitioning = false
        end
        guarded.tick()
        assert(guarded.test.fontSupports(guarded.test.configFontState().currentFont,
            guard == "latest-locale" and "Hans" or "Cyrillic"), guard .. ": recovery uses latest locale")
    end

    local handoff = fixture()
    handoff.failures = 100
    handoff.select("ruRU")
    local old = handoff.test.profileState()
    local oldSettings, oldFont, oldSaved = old.settings, old.settings.font, old.settings.fontBeforeAutoSwitch
    if forever then
        -- Forever routes character/manual profiles without Retail specialization.
        local switched, result = handoff.test.profileOps.enableAccountWide(old.profileID)
        assert(switched and result.created, "manual account-wide switch creates a separate profile")
    else
        handoff.specID = 71
        handoff.env.__fireEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
    end
    handoff.env.__flushTimers(0)
    local current = handoff.test.profileState()
    assert(current.profileID ~= old.profileID and current.settings ~= oldSettings,
        "real profile-context change selects new settings")
    handoff.failures = 0
    handoff.env.__flushTimers(0.2)
    handoff.tick()
    assert(handoff.test.configFontState().currentFont == "Fonts\\ARIALN.TTF", "retry recovers in latest profile")
    assert(handoff.test.profileState().settings == current.settings, "retry preserves new settings identity")
    assert(oldSettings.font == oldFont and oldSettings.fontBeforeAutoSwitch == oldSaved, "retry cannot mutate outgoing settings")
end
print(flavor .. " committed Settings recovery regressions passed")


-- The scaled protected-number formatters recover after combat without retrying
-- a failing native call on every HUD update.
for _, kind in ipairs(forever and { "Movement", "MP5" } or { "Movement" }) do
    local first, second = {}, {}
    local combat, phase = false, "probe-error"
    local probeCalls, restrictedCalls = 0, 0
    local opts = {
        statsProDB = {
            showOffensive = false, showTertiary = false, showDefensive = false,
            showMainStat = false, showStamina = false, showItemLevel = false,
        },
        inCombatLockdown = function() return combat end,
        issecretvalue = function(value) return rawequal(value, first) or rawequal(value, second) end,
        abbreviateNumbers = function(value)
            if type(value) == "number" then
                probeCalls = probeCalls + 1
                if phase == "probe-error" then error("transient clean probe failure") end
                if kind == "Movement" then return value == 7 and "100,0%" or "150,0%" end
                return "10,25"
            end
            restrictedCalls = restrictedCalls + 1
            if phase == "protected-error" then return nil end
            if kind == "Movement" then return rawequal(value, first) and "110,0%" or "150,0%" end
            return rawequal(value, first) and "30,25" or "38,75"
        end,
        setFormattedText = function(_, format, value)
            assert(format == "%.1f yd/s", "Movement preserves the live raw-speed format")
            return rawequal(value, first) and "7,7 yd/s" or "10,5 yd/s"
        end,
    }
    local env, addon = loadStatsPro("enUS", opts)
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    local function cycleCombat()
        combat = false
        env.__fireEvent("PLAYER_REGEN_ENABLED")
        combat = true
        env.__fireEvent("PLAYER_REGEN_DISABLED")
    end
    local function read(value)
        if kind == "MP5" then return addon.forever.FormatRestrictedMP5(value) end
        local _, text = addon.movementRuntime.ResolvePercent(value)
        return text
    end
    local fallbackFirst = kind == "Movement" and "7,7 yd/s" or nil
    local fallbackSecond = kind == "Movement" and "10,5 yd/s" or nil
    local nativeFirst = kind == "Movement" and "110,0%" or "30,25"
    local nativeSecond = kind == "Movement" and "150,0%" or "38,75"
    combat = true
    env.__fireEvent("PLAYER_REGEN_DISABLED")
    assert(read(first) == fallbackFirst, kind .. ": failed clean probe uses fallback")
    local failedProbes = probeCalls
    phase = "ready"
    assert(read(second) == fallbackSecond and probeCalls == failedProbes and restrictedCalls == 0,
        kind .. ": clean probe is not repeated in the same combat")
    cycleCombat()
    assert(read(first) == nativeFirst and probeCalls > failedProbes and restrictedCalls == 1,
        kind .. ": clean probe can recover on the next combat")

    phase = "protected-error"
    assert(read(first) == fallbackFirst and restrictedCalls == 2,
        kind .. ": malformed protected result uses the correct fallback")
    phase = "ready"
    assert(read(second) == fallbackSecond and restrictedCalls == 2,
        kind .. ": protected call is not repeated in the same combat")
    cycleCombat()
    assert(read(first) == nativeFirst and read(second) == nativeSecond and restrictedCalls == 4,
        kind .. ": resumed native path displays consecutive live values")

    local incompatibleProbes, unexpectedProtectedCalls = 0, 0
    local compatible = false
    env.AbbreviateNumbers = function(value)
        if type(value) ~= "number" then
            unexpectedProtectedCalls = unexpectedProtectedCalls + 1
            return nativeFirst
        end
        incompatibleProbes = incompatibleProbes + 1
        if not compatible then return "1.0" end
        if kind == "Movement" then return value == 7 and "100%" or "150%" end
        return "10.25"
    end
    assert(read(first) == fallbackFirst and incompatibleProbes > 0, kind .. ": clean mismatch fails closed")
    local provenMismatch = incompatibleProbes
    compatible = true
    cycleCombat()
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    assert(read(second) == fallbackSecond and incompatibleProbes == provenMismatch and unexpectedProtectedCalls == 0,
        kind .. ": a proven mismatch remains cached across recovery events")
    print(flavor .. " " .. kind .. " protected formatter recovery regressions passed")
end

for _, ownedAlias in ipairs({ false, true }) do
    local snapshot = assert(loadfile("AntraktFontCatalog.lua"))()
    local face = snapshot.fonts[1]
    local path = ownedAlias and face.path or "Interface\\AddOns\\SharedMedia_MyMedia\\fonts\\LateReady.ttf"
    local savedPath = ownedAlias and face.aliases[1] or path
    local ready = false
    local function canApply(_, font) return (font ~= path and font ~= savedPath) or ready end
    local env, addon, test = fixtures.loadStatsPro("enUS", {
        forever = forever,
        statsProDB = { font = savedPath },
        bundledFonts = ownedAlias,
        lsmFonts = { { name = "Late Ready", path = path } },
        setFontResult = canApply,
        fontObjectSetFontResult = canApply,
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    for _ = 1, 8 do
        if not env.__flushNextTimer(5) then break end
    end
    local attempts = test.fontRuntimeState().pendingRetryAttempt
    assert(attempts == 4 and not test.fontRuntimeState().pendingRetryScheduled
        and test.currentRuntimeFontPath() ~= path, "font starts in exhausted fallback")
    env.__registerLSMFont("Unrelated", "Interface\\AddOns\\SharedMedia_MyMedia\\fonts\\Unrelated.ttf")
    env.__flushTimers(0)
    assert(addon:RunUpdateStatsSafe())
    assert(test.fontRuntimeState().pendingRetryAttempt == attempts
        and not test.fontRuntimeState().pendingRetryScheduled, "unrelated registration cannot restart the same retry budget")

    ready = true
    env.__registerLSMFont("Late Ready", path)
    env.__flushTimers(0)
    assert(addon:RunUpdateStatsSafe())
    assert(test.currentRuntimeFontPath() == path, "a ready catalogue font recovers after its initial retry window")
    assert(test.fontRuntimeState().pendingSavedFont == nil
        and test.profileState().settings.font == savedPath, "recovery preserves the saved selection and clears pending state")
end
print(flavor .. " late catalogue font recovery regressions passed")

for _, mode in ipairs({ "preview", "locale", "combat" }) do
    local path = "Interface\\AddOns\\SharedMedia_MyMedia\\fonts\\DelayedLatinFixture.ttf"
    local ready, combat = false, false
    local function canApply(_, font) return font ~= path or ready end
    local env, addon, test = loadStatsPro("enUS", {
        statsProDB = { font = path },
        lsmFonts = { { name = "Delayed Latin Fixture", path = path } },
        setFontResult = canApply,
        fontObjectSetFontResult = canApply,
        inCombatLockdown = function() return combat end,
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    assert(addon:OpenConfigMenu() ~= false)
    local function selectLocale(locale)
        local dropdown = env.StatsProLanguageDropdown
        dropdown.dropdownInit()
        for _, entry in ipairs(dropdown.dropdownEntries) do
            if entry.value == locale then
                entry.func()
                return
            end
        end
        error("language choice is missing: " .. locale)
    end
    if mode == "preview" then
        assert(test.previewFontForSmoke("Fonts\\ARIALN.TTF"))
    elseif mode == "locale" then
        selectLocale("ruRU")
        assert(test.profileState().root.account.forceLocale == "ruRU")
    else
        combat = true
        env.__fireEvent("PLAYER_REGEN_DISABLED")
    end
    local before = test.panelFontState()
    ready = true
    assert(env.__flushNextTimer(0.2))
    local after = test.panelFontState()
    assert(after.mainAppliedFont == before.mainAppliedFont and after.sideAppliedFont == before.sideAppliedFont,
        "saved font timer must not override " .. mode)
    assert(test.profileState().settings.font == path, "saved preference must survive " .. mode)
    if mode == "preview" then
        addon.settingsUI.fontPicker.CancelPreview(addon)
    elseif mode == "combat" then
        combat = false
        env.__fireEvent("PLAYER_REGEN_ENABLED")
    end
    assert(addon:RunUpdateStatsSafe())
    env.__flushTimers(0.2)
    assert((test.currentRuntimeFontPath() == path) == (mode ~= "locale"),
        "compatible saved font must recover after " .. mode)
    if mode == "locale" then
        selectLocale("enUS")
        assert(test.currentRuntimeFontPath() == path and test.profileState().settings.font == path,
            "returning to a supported locale restores the saved face")
    end
end
print(flavor .. " pending saved font ownership regressions passed")

local function archonTargetsFixture()
    return {
        schemaVersion = 6,
        snapshots = {
            mythicPlusCurrent = {
                capturedAt = "2026-11-11",
                specs = { MAGE = { frost = { targets = { haste = 1000, mastery = 1000 } } } },
            },
        },
    }
end

if not forever then
    local phase = "clean"
    local env, addon, test = loadStatsPro("enUS", {
        unitClassToken = "MAGE", specIndex = 1, specID = 64,
        statsProArchonTargets = archonTargetsFixture(),
        statsProDB = {
            showOffensive = true, showCrit = false, showHaste = true,
            showMastery = false, showVersatility = false, matchValueColorToStat = false,
        },
        getCombatRating = function()
            if phase == "liveOnly" then return -21 end
            if phase ~= "targetOnly" then return 2000 end
        end,
        getHaste = function()
            if phase == "liveOnly" or phase == "secretPercent" then return -22 end
            return 56
        end,
        issecretvalue = function(value) return value == -21 or value == -22 end,
        getCombatRatingBonusForCombatRatingValue = function(_, rating)
            assert(rating >= 0, "protected rating must never reach conversion")
            return rating == 2000 and 20 or 10
        end,
        setFormattedText = function(_, _, value)
            assert(value == -21 or value == -22, "expected protected Haste value")
            return value == -21 and "2000" or "56.0%"
        end,
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    local function tooltipRows()
        local meta = test.buildRenderBlocks()[2].targetRows[1]
        assert(addon.archonTargets.ShowTooltip(env.UIParent, meta))
        local rows = {}
        for _, row in ipairs(test.getArchonTooltip().lines) do rows[row.left] = row.right end
        return rows, meta.target, meta.comparisonState
    end
    local rows, target = tooltipRows()
    assert(rows["Target:"] == target .. " (~43.0%)", "Haste target retains the current 30% multiplier")
    assert(rows["Current:"] == "2000 (~56.0%)" and rows["Over:"]:find("(~+13.0%)", 1, true),
        "Haste gap compares the two projected totals")

    phase = "liveOnly"
    local liveRows, _, liveState = tooltipRows()
    assert(liveState == "liveOnly" and liveRows["Target:"] == tostring(target)
        and liveRows["Current:"] == "2000 (~56.0%)" and not liveRows["Over:"],
        "a protected live total cannot be paired with a rating-only percentage")

    phase = "secretPercent"
    local secretRows = tooltipRows()
    assert(secretRows["Target:"] == tostring(target) and secretRows["Current:"] == "2000 (~56.0%)"
        and not secretRows["Over:"]:find("%", 1, true), "a restricted total cannot drive projected percentages")

    addon.archonTargets.InvalidateComparisonCache()
    phase = "targetOnly"
    local targetRows, _, targetState = tooltipRows()
    assert(targetState == "targetOnly" and targetRows["Target:"] == tostring(target)
        and not targetRows["Current:"], "without a clean baseline, show the reference rating alone")
    print("Retail Archon Haste projection regressions passed")
end

if not forever then
    local spec = 62
    local specReady = true
    local restricted = false
    local ratingReady = true
    local env, addon, test = loadStatsPro("enUS", {
        unitClassToken = "MAGE", specIndex = 1,
        unitGUID = function() return "Player-1-RETAIL-SPEC-CACHE" end,
        getSpecializationInfo = function()
            if specReady then return spec, "Mage", nil, nil, "DAMAGER", 4 end
        end,
        statsProDB = {
            showOffensive = true, showCrit = true, showHaste = false,
            showMastery = false, showVersatility = true, hideZeroOffensive = true,
        },
        getCritChance = function() return restricted and -9 or spec == 62 and 25 or 9 end,
        getRangedCritChance = function() return restricted and -8 or 8 end,
        getSpellCritChance = function() return restricted and -31 or spec == 62 and 12 or 31 end,
        getCombatRating = function() if ratingReady then return spec == 62 and 750 or 300 end end,
        getCombatRatingBonus = function() return restricted and -3 or spec == 62 and 10 or 3 end,
        getVersatilityBonus = function() return restricted and -8 or spec == 62 and 2 or 8 end,
        issecretvalue = function(value) return value == -9 or value == -8 or value == -31 or value == -3 end,
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    assert(test.profileOps.enableAccountWide(test.profileState().profileID))
    assert(addon:RunUpdateStatsSafe() and test.versatilityState().total == 12)
    local value, state = addon.GetBestCritChance()
    assert(value == 25 and state == "exact")
    restricted = true
    ratingReady = false

    env.__fireEvent("PLAYER_SPECIALIZATION_CHANGED", "pet")
    assert(addon:RunUpdateStatsSafe() and test.versatilityState().total == 12,
        "pet events do not evict a player's confirmed caches")
    env.__fireEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
    assert(addon:RunUpdateStatsSafe() and test.versatilityState().rating == 750,
        "a same-spec player event preserves the last complete read")

    specReady = false
    env.__fireEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
    assert(addon:RunUpdateStatsSafe())
    value, state = addon.GetBestCritChance()
    assert(value == nil and state == "restricted" and #test.buildRenderBlocks()[2].labels == 0,
        "an unsettled player spec cannot display the prior Crit or Versatility fallback")
    assert(test.versatilityState().total == 12, "an unsettled identity keeps the former cache intact")

    spec = 63
    restricted = false
    ratingReady = true
    assert(addon:RunUpdateStatsSafe())
    value, state = addon.GetBestCritChance()
    assert(value == 31 and state == "exact" and test.versatilityState().rating == 750
        and test.versatilityState().total == 12, "clean interim samples display without changing the former cache")

    spec = 62
    restricted = true
    ratingReady = false
    specReady = true
    assert(addon:RunUpdateStatsSafe())
    value, state = addon.GetBestCritChance()
    assert(value == -9 and state == "liveProxy" and #test.buildRenderBlocks()[2].labels == 2,
        "if the previous spec is confirmed, its Crit and Versatility caches resume")

    spec = 63
    specReady = false
    env.__fireEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
    assert(addon:RunUpdateStatsSafe())
    assert(test.versatilityState().total == 12, "transient missing identity does not become a spec change")
    specReady = true
    env.__flushTimers(0)
    assert(addon:RunUpdateStatsSafe())
    value, state = addon.GetBestCritChance()
    local vers = test.versatilityState()
    assert(value == nil and state == "restricted", "new spec cannot borrow the former Crit proxy")
    assert(vers.total == nil and vers.rating == nil and vers.percentVisible == nil,
        "new spec cannot borrow Versatility total, rating, or Hide Zero decision")
    assert(#test.buildRenderBlocks()[2].labels == 0, "restricted rows with no new-spec visibility do not use old decisions")

    restricted = false
    ratingReady = true
    assert(addon:RunUpdateStatsSafe())
    value, state = addon.GetBestCritChance()
    assert(value == 31 and state == "exact" and test.versatilityState().total == 11,
        "new spec resumes normal clean readings")
    spec = 62
    restricted = true
    ratingReady = false
    env.__fireEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
    assert(addon:RunUpdateStatsSafe())
    value, state = addon.GetBestCritChance()
    assert(value == nil and state == "restricted" and test.versatilityState().total == nil,
        "returning to a previous spec does not resurrect its old sample")
    print("Retail spec-scoped restricted stat recovery regressions passed")
end

if not forever then
    local reads = 0
    local coefficientUnavailable = false
    local env, addon, test = loadStatsPro("enUS", {
        unitClassToken = "MAGE", specIndex = 1, specID = 64,
        statsProArchonTargets = archonTargetsFixture(),
        statsProDB = {
            showOffensive = true, showCrit = false, showHaste = false,
            showMastery = true, showVersatility = false,
        },
        getCombatRating = function() return 300 end,
        getCombatRatingBonusForCombatRatingValue = function(_, value) return value / 100 end,
        getMasteryEffect = function()
            reads = reads + 1
            if reads % 2 == 0 then return 50, 4 end
            if coefficientUnavailable then return 20 end
            return 20, 2
        end,
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    reads = 0
    local meta = test.buildRenderBlocks()[2].targetRows[1]
    local expected = 20 + (meta.target / 100 - 3) * 2
    assert(reads == 1 and meta.currentPct == 20 and math.abs(meta.targetPct - expected) < 1e-6,
        "Mastery projection and displayed effect use the same client API result")
    assert(addon.archonTargets.ShowTooltip(env.UIParent, meta) and reads == 1)

    reads = 0
    coefficientUnavailable = true
    local unavailable = test.buildRenderBlocks()[2].targetRows[1]
    assert(unavailable.targetPct == nil and unavailable.currentPct == 20 and reads == 1,
        "a missing coefficient does not trigger another sample")
    assert(addon.archonTargets.ShowTooltip(env.UIParent, unavailable) and reads == 1,
        "an unavailable render coefficient cannot be replaced when opening the tooltip")

    reads = 0
    coefficientUnavailable = false
    local standalone = test.buildArchonTargetMeta("mastery", 300, env.CR_MASTERY, 20)
    assert(reads == 1 and math.abs(standalone.targetPct - expected) < 1e-6,
        "standalone metadata remains compatible without a pre-read sample")
    print("Retail Archon Mastery single-sample regressions passed")
end

if not forever then
    local env, _, test = loadStatsPro("enUS", {
        issecretvalue = function(value) return value == -21 or value == -22 end,
        setFormattedText = function(_, _, value) return value == -21 and "41.2%" or "63.7%" end,
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    local function render(currentPct, currentPctDisplay)
        test.renderMainPanelForSmoke("Haste:", "875", "22.0%", 1, nil, nil, {
            {
                statKey = "haste", ratingCR = env.CR_HASTE_MELEE, target = 1000, current = 875,
                currentPct = currentPct, currentPctDisplay = currentPctDisplay,
                delta = -125, capturedAt = "2026-11-11", comparisonState = "exact",
            },
        })
    end
    render(22)
    test.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    local tooltip = test.getArchonTooltip()
    local measurements, anchors, visibleWrites = 0, 0, 0
    local measure = tooltip.bodyProbe.GetUnboundedStringWidth
    tooltip.bodyProbe.GetUnboundedStringWidth = function(...)
        measurements = measurements + 1
        return measure(...)
    end
    local clearPoints = tooltip.ClearAllPoints
    tooltip.ClearAllPoints = function(...)
        anchors = anchors + 1
        return clearPoints(...)
    end
    local region = tooltip.regions[4].rightText
    local setText = region.SetText
    region.SetText = function(...)
        visibleWrites = visibleWrites + 1
        return setText(...)
    end
    local measuredRows = tooltip.lines
    render(22)
    assert(tooltip.lines == measuredRows and type(tooltip.lines[1].height) == "number",
        "a clean layout reuse retains its measured row state")
    assert(measurements == 0 and anchors == 0 and visibleWrites == 0,
        "a shown tooltip does no geometry or visible text work for identical clean content")
    render(25)
    assert(measurements > 0 and visibleWrites > 0, "changed clean content updates geometry and text")

    env.__fireEvent("UI_SCALE_CHANGED")
    local beforeScale = measurements
    render(25)
    assert(measurements > beforeScale, "scale changes invalidate clean tooltip layout")

    render(nil, -21)
    local beforeProtected = visibleWrites
    render(nil, -22)
    assert(visibleWrites > beforeProtected and region:GetText():find("63.7%", 1, true),
        "two consecutive restricted updates remain live")

    tooltip:Hide()
    render(25)
    local beforeReopen = measurements
    test.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    assert(tooltip:IsShown() and measurements > beforeReopen,
        "opening a hidden tooltip does not reuse an old visible layout")
    test.renderMainPanelForSmoke("Haste:", "875", "22.0%", 1, nil, nil, {
        { statKey = "haste", ratingCR = env.CR_HASTE_MELEE, target = 1000, comparisonState = "targetOnly" },
    })
    assert(not region:IsShown() and region:GetText() == "",
        "a shorter tooltip clears previously visible text regions")
    print("Retail Archon stable tooltip layout regressions passed")
end
