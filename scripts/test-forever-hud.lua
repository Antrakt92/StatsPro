-- Exercise the real shared HUD using the existing mocked WoW client.
local fixtures = assert(loadfile("scripts/smoke.lua"))("fixtures")
local count = 0
local function check(ok, name)
    count = count + 1
    assert(ok, name)
end
local combat = false
local value = 0
local restricted = false
local secret = -123456
local env, addon, test = fixtures.loadStatsPro("enUS", {
    forever = true,
    unitGUID = function() return "Player-ForeverFixture" end,
    inCombatLockdown = function() return combat end,
    issecretvalue = function(number) return number == -123456 or number == -123457 end,
    roundToNearestString = function(number)
        if number == -123456 then return "75" end
        if number == -123457 then return "90" end
        return tostring(number)
    end,
    foreverAPIs = {
        UnitStat = function(_, index) return index, 20 + index, 0, 0 end,
        GetCritChance = function() return restricted and secret or value end,
        UnitAttackPower = function() return 10, restricted and secret or 2, -1 end,
        GetMeleeHaste = function() return 2 end,
        GetSpellCritChance = function() return 5 end,
        GetSpellBonusHealing = function() return 15 end,
        UnitSpellHaste = function() return 0 end,
        GetManaRegen = function() return 6, 1 end,
        GetExpertise = function() return 0, 0, 0 end,
        UnitDefenseSkill = function() return 5, 0 end,
    },
})
env.__fireEvent("PLAYER_ENTERING_WORLD")
check(addon.forever.enabled, "verified beta adapter enabled")
check(env.StatsProFrame:IsShown(), "level-one HUD visible without Retail specialization")
local initialSettings = test.profileState().settings
for _, name in ipairs({ "Strength", "Agility", "Stamina", "Intellect", "Spirit" }) do
    initialSettings["show" .. name] = true
end
test.cacheSettings()
local blocks = test.buildRenderBlocks()
check(#blocks[1].labels == 5, "all five attributes shown")
check(string.find(table.concat(blocks[1].labels, "\n"), "Spirit", 1, true), "Spirit in shared HUD")
check(test.transferPrefix() == "SPF1:", "Forever transfer envelope")
check(#addon.archonTargets.GetAvailableSnapshotOptions() == 0, "no Archon snapshot selector")
check(addon.archonTargets.GetSnapshot("MAGE", "frost") == nil, "no Archon lookup")
local settings = test.profileState().settings
local export = test.profileTransfer.serialize("Forever", settings, { stats = true, layout = true, appearance = true })
check(type(export) == "string" and export:sub(1, 5) == "SPF1:", "profile export includes flavor")
local parsedExport = test.profileTransfer.parse(export)
check(parsedExport ~= nil, "own flavor profile roundtrip")
for key, color in pairs(addon.forever.colorDefaults or {}) do
    check(settings.colors[key] ~= nil, "Forever color seeded " .. key)
    check(parsedExport.values["colors." .. key .. ".r"] == settings.colors[key].r,
        "Forever color included in appearance transfer " .. key)
end
check(test.profileTransfer.parse(export:gsub("^SPF1:", "SPP1:")) == nil, "Retail profile rejected")
local retailEnv, retailAddon, retailTest = fixtures.loadStatsPro("enUS")
check(retailTest.profileTransfer.parse(export) == nil, "Forever profile rejected by Retail")
check(retailEnv ~= nil, "Retail remains loadable")
for _, id in ipairs(test.hudPresets.order()) do
    check(test.hudPresets.startPreview(id), "preset preview " .. id)
    check(test.hudPresets.applyPreview(), "preset apply " .. id)
    check(test.hudPresets.currentID() == id, "preset current " .. id)
end
settings = test.profileState().settings
settings.showOffensive, settings.showMeleeCrit = true, true
settings.hideZeroOffensive = true
settings.showAttackPower = true
test.cacheSettings()
blocks = test.buildRenderBlocks()
local function contains(block, text)
    return string.find(table.concat(block.labels, "\n"), text, 1, true) ~= nil
end
local critLabel = addon.forever.Translate("Melee Crit", "enUS") or "Melee Crit"
check(not contains(blocks[2], critLabel), "clean zero hidden")
restricted = true
blocks = test.buildRenderBlocks()
check(not contains(blocks[2], critLabel), "restricted after clean zero remains hidden")
restricted, value = false, 7
test.buildRenderBlocks()
restricted, combat = true, true
blocks = test.buildRenderBlocks()
check(contains(blocks[2], critLabel), "restricted after nonzero remains visible")
check(contains(blocks[2], "Attack Power"), "unknown composite remains visible after clean nonzero")
check(string.find(table.concat(blocks[2].values, "\n") .. table.concat(blocks[2].ratings, "\n"), "?", 1, true), "composite restricted value displays unknown")
local firstRestricted = table.concat(blocks[2].values, "\n") .. table.concat(blocks[2].ratings, "\n")
check(string.find(firstRestricted, "75", 1, true), "first restricted scalar displayed live")
secret = -123457
blocks = test.buildRenderBlocks()
local secondRestricted = table.concat(blocks[2].values, "\n") .. table.concat(blocks[2].ratings, "\n")
check(string.find(secondRestricted, "90", 1, true), "second consecutive restricted scalar displayed live")
check(not string.find(secondRestricted, "75", 1, true), "previous restricted scalar not cached")
combat, restricted = false, false
settings.hideZeroOffensive = false
settings.showRating, settings.showPercentage = false, false
test.cacheSettings()
blocks = test.buildRenderBlocks()
check(#blocks[2].ratings > 0 and table.concat(blocks[2].ratings, "") ~= "", "single values survive hidden Retail column toggles")
env.SlashCmdList.STATSPRO("")
check(env.StatsProConfigFrame:IsShown(), "shared Settings opens")
local foundSpirit, foundArchon, foundUtility = false, false, false
for _, frame in ipairs(env.__frames) do
    if frame.name == "StatsProForeverSpirit" then foundSpirit = true end
    if frame.name == "StatsProArchonSnapshotDropdown" then foundArchon = true end
    if frame.name == "StatsProForeverutilityMaster" then foundUtility = true end
end
check(foundSpirit, "Forever Spirit checkbox exists")
check(foundUtility, "utility section controls exist")
check(not foundArchon, "Archon Settings control absent")
check(addon.forever.capabilities.itemLevel, "observed item-level API offers optional control")
local visited = {}
local gearEnv, _, gearTest = fixtures.loadStatsPro("enUS", {
    forever = true, unitGUID = function() return "Player-GearFixture" end,
    statsProDB = { showDurability = true },
    getInventoryItemDurability = function(slot)
        visited[slot] = true
        if slot == 18 then return 10, 20 end
    end,
})
gearEnv.__fireEvent("PLAYER_ENTERING_WORLD")
check(visited[18], "Forever ranged-slot durability is inspected")
check(gearTest.durabilityState().durabilityValue == 50, "ranged-slot durability contributes to HUD")
local customColorKey = next(addon.forever.colorDefaults or {})
if customColorKey then
    settings.colors[customColorKey] = { r = 0.12, g = 0.34, b = 0.56 }
end
local root = env.StatsProDB
local reloadEnv, _, reloadTest = fixtures.loadStatsPro("enUS", {
    forever = true, statsProDB = root,
    unitGUID = function() return "Player-ForeverFixture" end,
    foreverAPIs = { UnitStat = function(_, index) return index, 20 + index, 0, 0 end },
})
reloadEnv.__fireEvent("PLAYER_ENTERING_WORLD")
check(reloadTest.profileState().settings.showSpirit == settings.showSpirit, "Forever row selections survive reload")
check(#reloadTest.buildRenderBlocks()[1].labels > 0, "HUD survives reload")
if customColorKey then
    local restored = reloadTest.profileState().settings.colors[customColorKey]
    check(restored.r == 0.12 and restored.g == 0.34 and restored.b == 0.56,
        "custom Forever stat color survives reload")
end
-- Five cards must fit the standalone welcome and the expanded Settings body.
local welcome = addon.hudPresets.BuildWelcome()
local welcomeUI = welcome.statsProView
check(welcomeUI ~= nil, "welcome has testable layout")
for _, warning in ipairs({ false, true }) do
    welcomeUI.refreshLayout(true, warning)
    for _, button in ipairs({ welcomeUI.cancel, welcomeUI.apply }) do
        local _, _, _, _, top = button:GetPoint()
        check(-top + button:GetHeight() + 16 <= welcome:GetHeight(),
            "five-card welcome footer fits including warning " .. tostring(warning))
    end
end
local lastCard = welcomeUI.buttons[test.hudPresets.order()[5]]
local _, _, lastShortTop, _, lastTop = lastCard:GetPoint()
lastTop = lastTop or lastShortTop
check(-lastTop + lastCard:GetHeight() < -welcomeUI.warningY,
    "fifth welcome card above note and footer")
local statsTab
for _, candidate in ipairs(env.__frames) do
    if candidate.quickSetupView then statsTab = candidate; break end
end
check(statsTab ~= nil, "Settings quick setup available")
local settingsUI = statsTab.quickSetupView
settingsUI.expanded = true
settingsUI.refreshLayout(false, false)
local fifthSettingsCard = settingsUI.buttons[test.hudPresets.order()[5]]
local _, _, fifthShortTop, _, fifthTop = fifthSettingsCard:GetPoint()
fifthTop = fifthTop or fifthShortTop
check(-fifthTop + fifthSettingsCard:GetHeight() < settingsUI.choiceBody:GetHeight(),
    "fifth Settings card fits expanded choice body")
local _, _, _, _, lowerTop = statsTab.statsBody:GetPoint()
check(-lowerTop + statsTab.statsBody:GetHeight() <= statsTab:GetHeight(),
    "expanded Settings content height includes all five cards and stat controls")
check(retailTest.hudPresets.order()[4] == nil, "Retail keeps three cards")
local retailWelcome = retailAddon.hudPresets.BuildWelcome()
retailWelcome.statsProView.refreshLayout(true, true)
check(retailWelcome:GetHeight() == 438, "Retail three-card welcome retains its original height")
local smallEnv, smallAddon = fixtures.loadStatsPro("enUS", {
    forever = true, uiParentWidth = 440, uiParentHeight = 400,
})
local smallWelcome = smallAddon.hudPresets.BuildWelcome()
smallWelcome.statsProView.refreshLayout(true, true)
check(smallWelcome:GetHeight() * smallWelcome:GetScale() <= smallEnv.UIParent:GetHeight() - 32,
    "five-card welcome fits a short viewport without clipping")
check(smallWelcome:GetWidth() * smallWelcome:GetScale() <= smallEnv.UIParent:GetWidth() - 32,
    "five-card welcome fits a narrow viewport without clipping")
-- Forever diagnostics must inspect its actual catalog, never Retail Mastery.
local spellState, spellValue = addon.selfTest.ProbeRow("SpellCrit")
check(spellState == 0 and spellValue == 5, "selftest probes Forever spell crit")
settings.showSpellCrit, settings.showOffensive, settings.showSpirit = true, true, false
test.cacheSettings()
addon.selfTest.CaptureEnv()
local observedKeys = {}
for _, key in ipairs(addon.selfTest.rowKeys) do observedKeys[key] = true end
check(observedKeys.SpellCrit and not observedKeys.Spirit and not observedKeys.mastery,
    "selftest catalogs only selected Forever rows")
addon.selfTest.TakeSample(false, false)
addon.selfTest.BuildReport()
local diagnostic = addon.selfTest.BuildPayload()
check(diagnostic:find("flavor=forever", 1, true) and not diagnostic:find("archon=", 1, true),
    "copied diagnostic includes flavor and excludes Archon")
restricted = true
local directState, directValue = addon.selfTest.ProbeRow("MeleeCrit")
check(directState == 1 and directValue == nil, "selftest excludes restricted scalar numbers")
local compositeState, compositeValue = addon.selfTest.ProbeRow("AttackPower")
check(compositeState == 2 and compositeValue == nil, "selftest excludes restricted composite numbers")
env.__prints = {}
addon:PrintDebugLiveStats()
local debugOutput = table.concat(env.__prints, "\n")
check(debugOutput:find("SpellCrit=5.00", 1, true) and debugOutput:find("MeleeCrit=secret", 1, true),
    "debug live samples Forever rows safely")
check(not debugOutput:find("-123457", 1, true) and not debugOutput:find("mastery", 1, true),
    "debug live excludes raw restricted numbers and Retail-only rows")
restricted = false
check(addon.selfTest.env.archon == nil, "Forever selftest excludes Archon context")
check(addon.selfTest.env.flavor == "forever", "Forever selftest identifies client flavor")
check(env.StatsProSplitTertiaryCheckText:GetText() == "Utility", "split routing names Forever utility")
check(env.StatsProForeverStrengthText:GetWidth() == env.StatsProForeverStaminaText:GetWidth(),
    "Forever character color swatches align in their column")
addon.profileUI.advancedShown = true
addon.profileUI.LayoutActionButtons(addon.profileUI.currentModel)
check(not addon.profileUI.actionButtons.roleTemplate:IsShown(), "unsupported role templates absent in Forever")
check(test.buildRenderBlocks()[3].sectionKey == "Utility", "Forever sectioned HUD names utility correctly")
local longControl = env.StatsProForeverCastingManaRegenMP5
check(type(longControl.statsProTooltipProvider) == "function", "long stat controls expose full labels on hover")
check(longControl.statsProTooltipProvider() == "Casting Mana Regen / 5 sec",
    "long stat tooltip exposes complete untruncated name")
env.__prints = {}
env.SlashCmdList.STATSPRO("debug")
local defaultDebug = table.concat(env.__prints, "\n")
check(defaultDebug:find("debug forever SpellCrit=5.00", 1, true)
    and not defaultDebug:find("mythicPlusCurrent", 1, true)
    and not defaultDebug:find("showMastery", 1, true),
    "default Forever debug uses the actual client catalog")
env.__prints = {}
check(addon.selfTest.Start(), "Forever diagnostic starts")
local startText = table.concat(env.__prints, "\n")
check(startText:find("fight a creature", 1, true) and not startText:find("training dummy", 1, true),
    "Forever diagnostic instructions match the beta client")
addon.selfTest.Stop("cancelled")
env.__prints = {}
env.SlashCmdList.STATSPRO("help")
check(table.concat(env.__prints, "\n"):find("/statspro import (SwiftStats)", 1, true),
    "Forever help distinguishes legacy SwiftStats import from profile strings")
retailEnv.__prints = {}
retailEnv.SlashCmdList.STATSPRO("help")
check(not table.concat(retailEnv.__prints, "\n"):find("import (SwiftStats)", 1, true),
    "Retail command help remains unchanged")
-- Exercise actual confirmation creation; do not accept destructive actions.
local beforeWipeRoot = env.StatsProDB
check(addon.wipeRuntime.Request(), "Forever wipe confirmation opens")
local wipePopup = env.__lastStaticPopup
check(wipePopup.renderedText:find("character assignment", 1, true)
    and not wipePopup.renderedText:find("specialization", 1, true),
    "Forever wipe confirmation uses character assignments")
addon.wipeRuntime.CancelPending(wipePopup, wipePopup.data)
check(env.StatsProDB == beforeWipeRoot and addon.wipeRuntime.pending == nil,
    "cancelled Forever confirmation preserves profiles")
local ruEnv, ruAddon = fixtures.loadStatsPro("ruRU", {
    forever = true, unitGUID = function() return "Player-RussianPopupFixture" end,
})
ruEnv.__fireEvent("PLAYER_ENTERING_WORLD")
check(ruAddon.wipeRuntime.Request(), "localized Forever wipe confirmation opens")
local ruWipe = ruEnv.__lastStaticPopup
check(ruWipe.renderedText:find("персонаж", 1, true)
    and not ruWipe.renderedText:find("специализа", 1, true),
    "Russian Forever confirmation names characters correctly")
ruAddon.wipeRuntime.CancelPending(ruWipe, ruWipe.data)
-- Some beta clients expose item level; both capability states must fit Gear.
local function controlPosition(control)
    local _, shortX, shortY, x, y = control:GetPoint()
    return x or shortX, y or shortY
end
for _, available in ipairs({ false, true }) do
    local gearEnv, gearAddon = fixtures.loadStatsPro("enUS", {
        forever = true,
        foreverAPIs = { GetAverageItemLevel = available and function() return 5, 4 end or false },
    })
    gearEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    gearAddon:OpenConfigMenu()
    local dur = gearEnv.StatsProDurabilityCheck
    local durX, durY = controlPosition(dur)
    local repairX, repairY = controlPosition(gearEnv.StatsProRepairCostCheck)
    local item = gearEnv.StatsProItemLevelCheck
    if available then
        check(item ~= nil, "supported item level control exists")
        local itemX, itemY = controlPosition(item)
        check(durY == itemY and durX >= itemX + item:GetWidth(),
            "item level and durability occupy separate Gear columns")
    else
        check(item == nil, "unsupported item level control absent")
        check(durX == repairX, "durability occupies left column without item level")
    end
    check(repairY < durY, "repair checkbox follows complete Gear row")
end
do
    local phase, visited = "pending", {}
    local repairEnv, repairAddon, repairTest = fixtures.loadStatsPro("enUS", {
        forever = true, unitGUID = function() return "Player-RepairForever" end,
        statsProDB = { showRepairCost = true, showDurability = true },
        getInventoryItemDurability = function(slot)
            if slot == 1 or slot == 18 then return phase == "repaired" and 100 or 50, 100 end
        end,
        getTooltipInventoryItem = function(unit, slot)
            assert(unit == "player")
            visited[slot] = true
            if slot == 1 then return { repairCost = 123, sellPrice = 90000 } end
            if slot == 18 then
                if phase == "pending" then return { sellPrice = 80000 } end
                return { repairCost = 456, sellPrice = 80000 }
            end
        end,
    })
    repairEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    repairTest.cacheSettings()
    check(repairAddon:RunUpdateStatsSafe(), "Forever repair initial update")
    check(visited[1] and visited[18], "repair inspects damaged ranged slot")
    check(repairTest.durabilityState().repairCost == nil and not repairTest.durabilityState().repairCostComplete,
        "partial repair cost stays unknown")
    check(repairTest.durabilityState().repairRetryAttempt == 1, "missing repair cost gets bounded retry")
    check(repairTest.buildRenderBlocks()[7].repairStr == "?", "incomplete repair row shows unknown instead of partial sum")
    phase = "ready"
    check(repairEnv.__flushNextTimer(1), "repair retry timer runs")
    check(repairAddon:RunUpdateStatsSafe(), "repair retry update")
    check(repairTest.durabilityState().repairCostComplete and repairTest.durabilityState().repairCost == 579,
        "repair sums repairCost, not sellPrice")
    check(repairTest.buildRenderBlocks()[7].repairStr ~= "" and repairTest.buildRenderBlocks()[7].repairStr ~= "?",
        "known nonzero repair row renders money")
    phase, visited = "repaired", {}
    repairEnv.__fireEvent("UPDATE_INVENTORY_DURABILITY")
    check(repairTest.durabilityState().dirty, "repair event invalidates equipped cost")
    check(repairAddon:RunUpdateStatsSafe(), "post-repair update")
    check(repairTest.durabilityState().repairCostComplete and repairTest.durabilityState().repairCost == 0,
        "fully repaired cost is zero")
    check(repairTest.durabilityState().durabilityValue == 100, "repair restores durability")
    check(repairTest.buildRenderBlocks()[7].repairStr == "", "fully repaired gear hides the zero-cost row")
    check(not next(visited), "fully repaired gear needs no repair tooltips")
end
print("StatsPro Forever HUD integration: PASS (" .. count .. " checks)")
