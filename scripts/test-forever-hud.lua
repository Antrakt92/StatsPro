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
print("StatsPro Forever HUD integration: PASS (" .. count .. " checks)")
