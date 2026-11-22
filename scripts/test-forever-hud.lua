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
local attackPower, hitBonus = 10, 3
local hitModifier = 1
local secret = -123456
local restrictedRegen, nextRestrictedRegen = {}, {}
local manaRegen, castingRegen = 6, 1
local rejectMP5 = false
local env, addon, test = fixtures.loadStatsPro("enUS", {
    forever = true,
    unitGUID = function() return "Player-ForeverFixture" end,
    inCombatLockdown = function() return combat end,
    issecretvalue = function(number)
        return number == -123456 or number == -123457
            or number == restrictedRegen or number == nextRestrictedRegen
    end,
    abbreviateNumbers = function(number, options)
        local breakpoint = options.breakpointData[1]
        if number == restrictedRegen or number == nextRestrictedRegen then
            assert(not rejectMP5, "native MP5 formatting rejected")
            assert(breakpoint.abbreviation == "" and breakpoint.fractionDivisor == 100)
            assert(math.abs(breakpoint.significandDivisor - 0.002) < 1e-9)
            return number == restrictedRegen and "30.25" or "38.75"
        end
        return tostring(math.floor(number / breakpoint.significandDivisor)
            / breakpoint.fractionDivisor) .. breakpoint.abbreviation
    end,
    roundToNearestString = function(number)
        if number == -123456 then return "75" end
        if number == -123457 then return "90" end
        if number == restrictedRegen then return "6" end
        if number == nextRestrictedRegen then return "8" end
        return tostring(number)
    end,
    foreverAPIs = {
        UnitStat = function(_, index) return index, 20 + index, 0, 0 end,
        GetCritChance = function() return restricted and secret or value end,
        UnitAttackPower = function() return attackPower, restricted and secret or 2, -1 end,
        CR_HIT_MELEE = 6,
        GetCombatRatingBonus = function() return hitBonus end,
        GetHitModifier = function() return hitModifier end,
        GetMeleeHaste = function() return 2 end,
        GetSpellCritChance = function() return 5 end,
        GetSpellBonusHealing = function() return 15 end,
        UnitSpellHaste = function() return 0 end,
        GetManaRegen = function() return manaRegen, castingRegen end,
        GetExpertise = function() return 0, 0, 0 end,
        GetRangedHaste = function() return 4, restricted and secret or 10 end,
        UnitDefenseSkill = function() return 5, restricted and secret or 0 end,
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
do
    local available = true
    local swimming, falling = false, false
    local movementReads = 0
    local moveEnv, moveAddon, moveTest = fixtures.loadStatsPro("enUS", {
        forever = true,
        unitGUID = function() return "Player-Forever-UnknownUnits" end,
        foreverAPIs = {
            GetUnitSpeed = function()
                movementReads = movementReads + 1
                return 7, 7, 14, 4.9
            end,
            IsSwimming = function() return swimming end,
            IsFalling = function() return falling end,
            UnitOnTaxi = function() if available then return false end end,
            GetCritChance = function() if available then return 5 end end,
            GetManaRegen = function() if available then return 6, 1 end end,
        },
    })
    moveEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    local moveSettings = moveTest.profileState().settings
    moveSettings.showMeleeCrit, moveSettings.showManaRegenMP5 = true, true
    moveTest.cacheSettings()
    local function valueFor(group, label)
        local labels, ratings, values = {}, {}, {}
        moveAddon.forever.BuildLines(group, labels, ratings, values, true)
        for index, text in ipairs(labels) do
            if text:find(label, 1, true) then return ratings[index] .. values[index] end
        end
        return ""
    end
    check(valueFor("utility", "Movement Speed"):find("100%", 1, true), "movement starts at a clean percentage")
    check(valueFor("offensive", "Melee Crit"):find("5.00%", 1, true), "crit starts at a clean percentage")
    check(valueFor("utility", "Mana Regen / 5 sec"):find("30.00", 1, true), "MP5 starts at a clean rate")
    available = false
    check(valueFor("utility", "Movement Speed"):find("?%", 1, true), "unknown movement retains the percentage unit")
    check(valueFor("offensive", "Melee Crit"):find("?%", 1, true), "unknown crit retains the percentage unit")
    local unknownMP5 = valueFor("utility", "Mana Regen / 5 sec")
    check(unknownMP5:find("?", 1, true) and not unknownMP5:find("%", 1, true), "unknown MP5 retains its time unit")

    available = true
    for _, visibilityKey in ipairs({ "showMovementSpeed", "showTertiary", "isVisible" }) do
        swimming, falling = true, false
        check(valueFor("utility", "Movement Speed"):find("70%", 1, true), "swim speed before hiding " .. visibilityKey)
        swimming, falling = false, true
        check(valueFor("utility", "Movement Speed"):find("70%", 1, true), "visible jump keeps swim speed")
        moveSettings[visibilityKey] = false
        moveTest.cacheSettings()
        local before = movementReads
        swimming, falling = false, false
        check(moveAddon:RunUpdateStatsSafe() and movementReads == before, "hidden movement is not sampled: " .. visibilityKey)
        if visibilityKey == "isVisible" then
            swimming = true
            local status, speed = moveAddon.selfTest.ProbeRow("MovementSpeed")
            check(status == 0 and speed == 4.9, "the diagnostic can still sample movement while the HUD is hidden")
        end
        swimming, falling = false, true
        moveSettings[visibilityKey] = true
        moveTest.cacheSettings()
        check(valueFor("utility", "Movement Speed"):find("100%", 1, true), "a dry jump after hiding uses run speed: " .. visibilityKey)
    end
end
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
do
    -- Produced by the original Forever 1.18.6 exporter, before Offhand Hit.
    local file = assert(io.open("scripts/fixtures/profile-transfer-forever-v1-stats.spf", "rb"))
    local legacyText = file:read("*a")
    file:close()
    local transfer = addon.profileTransfer
    local legacy = transfer.Parse(legacyText)
    check(legacy ~= nil, "published legacy Forever stats export parses")
    check(legacy.values.showMeleeHit == true and legacy.values.showSpellCrit == false,
        "legacy transfer retains explicit stat choices")
    check(legacy.values.showOffhandHit == nil, "legacy transfer has no Offhand Hit choice")
    local destination = { showOffhandHit = true, showMeleeHit = false, showSpellCrit = true }
    local imported = transfer.BuildImportedSettings(destination, legacy, { stats = true })
    check(imported and imported.showOffhandHit == true and imported.showMeleeHit == true
        and imported.showSpellCrit == false, "legacy import preserves the destination's Offhand Hit")
    check(destination.showMeleeHit == false, "legacy import builds detached settings")
    destination.showOffhandHit = nil
    imported = transfer.BuildImportedSettings(destination, legacy, { stats = true })
    check(imported and imported.showOffhandHit == nil, "legacy import preserves absent Offhand Hit")

    local current = transfer.Parse(export)
    destination.showOffhandHit = not current.values.showOffhandHit
    imported = transfer.BuildImportedSettings(destination, current, { stats = true })
    check(imported and imported.showOffhandHit == current.values.showOffhandHit,
        "current import still applies its explicit Offhand Hit choice")
    local payload = assert(transfer.Base64Decode(legacyText:match("^SPF1:%x+:([A-Za-z0-9+/=]+)")))
    local malformed, removed = payload:gsub("\nshowMeleeHit=[^\n]+", "", 1)
    check(removed == 1, "legacy fixture includes Melee Hit")
    check(transfer.Parse(test.profileTransfer.encodePayload(malformed)) == nil,
        "legacy stats with another missing field are rejected")
    check(transfer.Parse(test.profileTransfer.encodePayload(malformed .. "\nshowOffhandHit=1")) == nil,
        "current field count cannot disguise a missing required stat")
end
do
    local firstEnv, firstAddon, firstTest = fixtures.loadStatsPro("enUS", {
        forever = true,
        unitGUID = function() return "Player-Forever-Audit-One" end,
        unitFullName = function() return "One", "Realm" end,
        classID = 1,
        getServerTime = function() return 100 end,
    })
    firstEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    local first = firstTest.profileState()
    local one = first.characters["Player-Forever-Audit-One"]
    check(one and one.displayName == "One-Realm" and one.classID == 1 and one.lastSeen == 100,
        "Forever stores clean character metadata on first login")
    check(first.profiles[first.profileID].name:match("^One%-Realm"),
        "new Forever profiles include the player name")
    check(firstAddon.profileRuntime.activeSpecID == 1 and firstAddon.profileRuntime.activeRole == nil,
        "Forever keeps a character-only profile context")

    local playerName
    local secondEnv, secondAddon, secondTest = fixtures.loadStatsPro("enUS", {
        forever = true, statsProDB = first.root,
        unitGUID = function() return "Player-Forever-Audit-Two" end,
        unitFullName = function() return playerName end,
        unitClassToken = "MAGE", classID = 8,
        getServerTime = function() return 200 end,
    })
    secondEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    local second = secondTest.profileState()
    local two = second.characters["Player-Forever-Audit-Two"]
    check(two and two.displayName == nil and two.classID == 8 and two.lastSeen == 200,
        "missing Forever player name leaves the other metadata available")
    playerName = "Two"
    secondEnv.__fireEvent("UNIT_NAME_UPDATE", "player")
    secondAddon.profileRuntime.ResolvePending()
    local updated = secondTest.profileState()
    check(updated.profileID == second.profileID and updated.settings == second.settings,
        "late Forever metadata preserves the assigned profile and settings")
    check(updated.characters["Player-Forever-Audit-Two"].displayName == "Two"
        and updated.characters["Player-Forever-Audit-One"].displayName == "One-Realm",
        "Forever profiles distinguish characters after the name event")
end
do
    local classReady = false
    local coldEnv, coldAddon, coldTest = fixtures.loadStatsPro("enUS", {
        forever = true,
        unitGUID = function() return "Player-Cold-Class" end,
        foreverAPIs = {
            UnitClass = function()
                if classReady then return "Mage", "MAGE", 8 end
            end,
        },
    })
    check(not coldAddon.hudPresets.definitions.compact.values.showSpellCrit, "cold fixture starts without class data")
    classReady = true
    coldEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    local settings = coldTest.profileState().settings
    check(settings.showIntellect == true and settings.showSpellCrit == true
        and settings.showManaRegenMP5 == true, "class data available at login determines first settings")
    check(coldAddon.hudPresets.definitions.compact.values.showSpellCrit == true,
        "class data available at login also refreshes Quick Setup")
end

do
    local function loginLateClass(options)
        local classReady = false
        local inCombat = false
        local guid = options.guidReady and "Player-Forever-LateClass" or nil
        local lateEnv, lateAddon, lateTest = fixtures.loadStatsPro("enUS", {
            forever = true,
            statsProDB = options.root,
            unitGUID = function() return guid end,
            inCombatLockdown = function() return inCombat end,
            foreverAPIs = { UnitClass = function()
                if classReady then return "Mage", "MAGE", 8 end
            end },
        })
        lateEnv.__fireEvent("PLAYER_ENTERING_WORLD")
        local before = lateTest.profileState()
        if options.keepUnknown then return before.root end
        if options.edit then before.settings.showSpellCrit = false end
        if options.roundTrip then
            check(lateAddon.profileOps.Assign(guid, 1, "p1"), "select a different existing profile before class resolution")
            check(lateAddon.profileOps.Assign(guid, 1, "p2"), "explicitly select the generic starter again")
        end
        if options.openSettings then lateAddon:OpenConfigMenu() end
        if options.openDialog then
            lateAddon:OpenConfigMenu()
            lateEnv.StatsProConfigFrame:Hide()
            check(lateAddon.profileUI.ShowSelfTestExport("SPS1:1\nrelease=fixture\n", "fixture report"),
                "standalone copy dialog opens before late class resolution")
        end
        if options.failApply then
            local apply = lateAddon.profileRuntime.applyActiveSettings
            rawset(lateAddon.profileRuntime, "applyActiveSettings", function()
                rawset(lateAddon.profileRuntime, "applyActiveSettings", apply)
                error("injected late class apply failure")
            end)
        end
        classReady, guid = true, "Player-Forever-LateClass"
        if options.openDialog then
            -- Evaluate the resolver with an open copy dialog independently of
            -- the shared pending-context UI refresh used by the name event.
            lateAddon.profileRuntime.ResolveCurrent(false)
        else
            lateEnv.__fireEvent("UNIT_NAME_UPDATE", "player")
            lateAddon.profileRuntime.ResolvePending()
        end
        if options.openSettings then
            check(lateEnv.StatsProConfigFrame:IsShown() and lateTest.profileState().settings == before.settings,
                "late class leaves open Settings and the starter untouched until Settings closes")
            if options.combatClose then
                inCombat = true
                lateEnv.__fireEvent("PLAYER_REGEN_DISABLED")
            end
            lateEnv.StatsProConfigFrame:Hide()
            if options.reopen then lateAddon:OpenConfigMenu() end
            lateEnv.__flushTimers(0)
            if options.reopen then
                check(lateEnv.StatsProConfigFrame:IsShown() and lateTest.profileState().settings == before.settings,
                    "queued late repair does not close Settings reopened in the meantime")
                lateEnv.StatsProConfigFrame:Hide()
                lateEnv.__flushTimers(0)
            end
            if options.combatClose then
                check(lateTest.profileState().settings == before.settings,
                    "closing Settings during combat does not apply the starter early")
                inCombat = false
                lateEnv.__fireEvent("PLAYER_REGEN_ENABLED")
            end
        end
        if options.openDialog then
            check(lateAddon.profileUI.operationDialog:IsShown() and lateTest.profileState().settings == before.settings,
                "late class leaves a standalone copy dialog untouched")
            lateAddon.profileUI.CloseOperationDialog()
            lateEnv.__flushTimers(0)
        end
        if options.failApply then
            local failed = lateTest.profileState()
            check(failed.settings == before.settings and failed.profileID == before.profileID,
                "failed late class apply restores the exact previous profile")
            lateEnv.__flushTimers(1)
        end
        local after = lateTest.profileState()
        check(after.characters[guid].classID == 8, "late class also refreshes metadata")
        check(lateAddon.hudPresets.definitions.compact.values.showSpellCrit == true,
            "Quick Setup learns class after first entering world")
        check(after.profileID == "p2" and after.root.account.nextProfileID == 3,
            "late class keeps one character profile allocation")
        if options.edit or options.root or options.roundTrip then
            check(after.settings == before.settings and after.settings.showSpellCrit ~= true,
                "late class preserves an edited or established profile")
        else
            check(after.settings.showIntellect == true and after.settings.showSpellCrit == true
                and after.settings.showManaRegenMP5 == true,
                "late class repairs a verified unmodified fresh starter")
        end
        local reset = assert(lateAddon.profileOps.BuildDefaultSettings())
        check(reset.showIntellect == true and reset.showSpellCrit == true and reset.showManaRegenMP5 == true,
            "explicit reset uses the now-known class even when an existing profile remains unchanged")
        return after.root
    end
    loginLateClass({ guidReady = false })
    loginLateClass({ guidReady = true })
    loginLateClass({ guidReady = true, failApply = true })
    loginLateClass({ guidReady = true, edit = true })
    loginLateClass({ guidReady = true, openSettings = true })
    loginLateClass({ guidReady = true, openSettings = true, edit = true })
    loginLateClass({ guidReady = true, openSettings = true, reopen = true })
    loginLateClass({ guidReady = true, openSettings = true, combatClose = true })
    loginLateClass({ guidReady = true, openDialog = true })
    loginLateClass({ guidReady = true, roundTrip = true })
    local genericRoot = loginLateClass({ guidReady = true, keepUnknown = true })
    loginLateClass({ guidReady = true, root = genericRoot })
end

do
    local function login(class, classID, guid, root)
        local characterEnv, _, characterTest = fixtures.loadStatsPro("enUS", {
            forever = true, statsProDB = root,
            unitClassToken = class, classID = classID,
            unitGUID = function() return guid end,
        })
        characterEnv.__fireEvent("PLAYER_ENTERING_WORLD")
        return characterTest.profileState(), characterTest
    end

    local warrior, warriorTest = login("WARRIOR", 1, "Player-Starter-Warrior")
    local oldSettings = warrior.settings
    local customRoot = assert(warriorTest.cloneSerializable(warrior.root))
    customRoot.profiles.p1.settings.showSpirit = true
    local mage = login("MAGE", 8, "Player-Starter-Mage", warrior.root)
    check(mage.settings.showIntellect == true and mage.settings.showSpirit == true
        and mage.settings.showSpellCrit == true and mage.settings.showSpellPowerFrost == true
        and mage.settings.showManaRegenMP5 == true,
        "new Forever character starts with their own class stats on an existing account")
    check(mage.settings.showMeleeCrit == false and mage.settings.showAttackPower == false,
        "new Forever character does not inherit the first class's rows")
    local returningWarrior = login("WARRIOR", 1, "Player-Starter-Warrior", mage.root)
    check(returningWarrior.settings == oldSettings and oldSettings.showAttackPower == true,
        "new Forever character leaves established character settings intact")
    local customMage = login("MAGE", 8, "Player-Starter-Mage", customRoot)
    check(customMage.settings.showSpirit == true and customMage.settings.showAttackPower == true
        and customMage.settings.showSpellCrit == false,
        "explicitly edited Forever defaults retain their stat selection")

    local mageStarter = login("MAGE", 8, "Player-Starter-Mage")
    mageStarter.root.profiles.p1.settings.showManaRegenMP5 = false
    local hunter = login("HUNTER", 3, "Player-Starter-Hunter", mageStarter.root)
    check(hunter.settings.showManaRegenMP5 == false and hunter.settings.showSpellCrit == true,
        "explicit MP5 opt-out does not resemble an old factory default")

    local originalWarrior, resetTest = login("WARRIOR", 1, "Player-Reset-Warrior")
    for _, stage in ipairs({ "validate", "commit", "apply" }) do
        resetTest.profileOps.setFailureStage(stage)
        local ok = resetTest.profileOps.fullWipe()
        local restored = resetTest.profileState()
        check(not ok and restored.root == originalWarrior.root and restored.settings == originalWarrior.settings,
            "failed Forever full wipe preserves the saved assignment at " .. stage)
    end
    resetTest.profileOps.setFailureStage(nil)
    check(resetTest.profileOps.fullWipe(), "Forever full wipe succeeds")
    local resetWarrior = resetTest.profileState()
    check(resetWarrior.profileID ~= resetWarrior.account.defaultProfileID and resetWarrior.settings.showAttackPower == true,
        "Forever full wipe gives the current character a detached class profile")
    resetWarrior.settings.showOffhandHit = true
    local resetMage = login("MAGE", 8, "Player-Reset-Mage", resetWarrior.root)
    check(resetMage.settings.showSpellCrit == true and resetMage.settings.showManaRegenMP5 == true
        and resetMage.settings.showAttackPower == false and resetMage.settings.showOffhandHit == false,
        "a new character after full wipe receives its own class setup")

    local damagedRoot = { dbVersion = originalWarrior.root.dbVersion }
    local damagedEnv, damagedAddon, damagedTest = fixtures.loadStatsPro("enUS", {
        forever = true, statsProDB = damagedRoot,
        unitGUID = function() return "Player-Recover-Warrior" end,
    })
    damagedEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    check(damagedAddon.profileOps.RecoverCorruptRoot({
        rootRef = damagedRoot, generation = damagedTest.profileState().generation,
    }), "Forever corrupt-root reset succeeds")
    check(damagedAddon.profileRuntime.ResolvePending(), "corrupt-root reset resolves the current character")
    local recoveredMage = login("MAGE", 8, "Player-Recover-Mage", damagedTest.profileState().root)
    check(recoveredMage.settings.showSpellCrit == true and recoveredMage.settings.showAttackPower == false,
        "corrupt-root recovery also leaves a class-neutral account starter")
end
for _, forever in ipairs({ false, true }) do
    local flavor = forever and "Forever" or "Retail"
    local commandEnv = fixtures.loadStatsPro("enUS", { forever = forever })
    commandEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    check(commandEnv.SLASH_STATSPRO1 == "/ss", flavor .. " registers /ss")
    check(commandEnv.SLASH_STATSPRO2 == "/statspro", flavor .. " registers /statspro")
    for _, alias in ipairs({ "/ss", "/statspro" }) do
        local handler
        for key, registeredAlias in pairs(commandEnv) do
            if registeredAlias == alias and type(key) == "string" then
                local command = key:match("^SLASH_(.-)%d+$")
                if command then handler = commandEnv.SlashCmdList[command] end
            end
        end
        check(type(handler) == "function", flavor .. " resolves " .. alias)
        handler("hide")
        check(not commandEnv.StatsProFrame:IsShown(), flavor .. " " .. alias .. " hide")
        handler("show")
        check(commandEnv.StatsProFrame:IsShown(), flavor .. " " .. alias .. " show")
        handler("toggle")
        check(not commandEnv.StatsProFrame:IsShown(), flavor .. " " .. alias .. " toggle off")
        handler("toggle")
        check(commandEnv.StatsProFrame:IsShown(), flavor .. " " .. alias .. " toggle on")
        handler("")
        check(commandEnv.StatsProConfigFrame:IsShown(), flavor .. " " .. alias .. " opens Settings")
        commandEnv.StatsProConfigFrame:Hide()
    end
end
for _, id in ipairs(test.hudPresets.order()) do
    check(test.hudPresets.startPreview(id), "preset preview " .. id)
    check(test.hudPresets.applyPreview(), "preset apply " .. id)
    check(test.hudPresets.currentID() == id, "preset current " .. id)
end
settings = test.profileState().settings
settings.showOffensive, settings.showMeleeCrit = true, true
settings.hideZeroOffensive = true
settings.showAttackPower, settings.showMeleeHit, settings.showRangedHaste = true, true, true
settings.showDefensive, settings.showDefense = true, true
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
local function hasStat(block, label, expected)
    local function plain(text) return (text:gsub("|cff%x%x%x%x%x%x", ""):gsub("|r", "")) end
    for index, rowLabel in ipairs(block.labels) do
        if plain(rowLabel):find(label, 1, true) == 1 then
            return plain(block.ratings[index] .. block.values[index]) == expected
        end
    end
    return false
end
do
    local readable, dead, inCombat, rejectHaste = false, false, false, false
    local haste, power = 25, 84
    local form, protectedHaste, protectedForm = nil, {}, {}
    local function readDefense()
        if readable then return 20, 3 end
    end
    local kitEnv, kitAddon, kitTest = fixtures.loadStatsPro("enUS", {
        forever = true,
        unitGUID = function() return "Player-ForeverRangedRecovery" end,
        inCombatLockdown = function() return inCombat end,
        issecretvalue = function(value)
            return rawequal(value, protectedHaste) or rawequal(value, protectedForm)
        end,
        roundToNearestString = function(value)
            assert(rawequal(value, protectedHaste) and not rejectHaste)
            return "32"
        end,
        foreverAPIs = {
            GetRangedHaste = function() if readable then return haste, 0 end end,
            UnitRangedAttackPower = function() if readable then return power, 0, 0 end end,
            UnitAttackPower = function() if readable then return power + 1, 1, 0 end end,
            UnitDefenseSkill = readDefense,
            GetShapeshiftFormID = function() return form end,
            CR_HIT_MELEE = 6,
            CR_HIT_RANGED = 7,
            CR_HIT_SPELL = 8,
            GetCombatRatingBonus = function(rating) if readable then return rating end end,
            GetHitModifier = function() return 1 end,
            GetOffhandHitModifier = function() return 2 end,
            GetRangedHitModifier = function() return 3 end,
            GetSpellHitModifier = function() return 4 end,
            UnitIsDeadOrGhost = function() return dead end,
        },
    })
    kitEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    local profile = kitTest.profileState().settings
    profile.showOffensive, profile.showRangedHaste, profile.showRangedAttackPower = true, true, true
    profile.showMeleeHit, profile.showOffhandHit, profile.showRangedHit, profile.showSpellHit = true, true, true, true
    profile.showAttackPower, profile.showDefensive, profile.showDefense = true, true, true
    profile.hideZeroOffensive = false
    profile.hideZeroDefensive = false
    kitTest.cacheSettings()
    local function expectRanged(expectedHaste, expectedPower, phase)
        local offense = kitTest.buildRenderBlocks()[2]
        check(hasStat(offense, "Ranged Haste", expectedHaste), phase .. " ranged haste")
        check(hasStat(offense, "Ranged Attack Power", expectedPower), phase .. " ranged power")
    end
    local function expectOtherCompound(phase, decorate)
        local hud = kitTest.buildRenderBlocks()
        for label, value in pairs({
            ["Melee Hit"] = "7.00%",
            ["Offhand Hit"] = "8.00%",
            ["Ranged Hit"] = "10.00%",
            ["Spell Hit"] = "12.00%",
            ["Attack Power"] = tostring(power + 2),
        }) do
            check(hasStat(hud[2], label, decorate(value)), phase .. " " .. label)
        end
        check(hasStat(hud[4], "Defense", decorate("23")), phase .. " Defense")
    end
    local function dash() return "—" end
    local function live(text) return text end
    local function previous(text) return "(" .. text .. ")" end
    expectRanged("—", "—", "cold unavailable")
    expectOtherCompound("cold unavailable", dash)
    readable = true
    expectRanged("25.00%", "84", "fresh stats")
    expectOtherCompound("fresh stats", live)
    readable, dead, inCombat = false, true, true
    kitEnv.__fireEvent("PLAYER_REGEN_DISABLED")
    kitEnv.__fireEvent("PLAYER_DEAD")
    expectRanged("(25.00%)", "(84)", "dead with unavailable stats")
    expectOtherCompound("dead with unavailable stats", previous)
    dead, inCombat = false, false
    kitEnv.__fireEvent("PLAYER_REGEN_ENABLED")
    kitEnv.__fireEvent("PLAYER_ALIVE")
    expectRanged("(25.00%)", "(84)", "alive out of combat with unavailable stats")
    expectOtherCompound("alive out of combat with unavailable stats", previous)
    readable, haste, power = true, 29, 101
    expectRanged("29.00%", "101", "next live values replace fallback")
    readable = false
    kitEnv.__fireEvent("PLAYER_EQUIPMENT_CHANGED", 18)
    check(kitAddon:RunUpdateStatsSafe(), "gear change refreshes the HUD safely")
    expectRanged("—", "—", "changed equipment discards old stats")
    expectOtherCompound("changed equipment discards old stats", dash)
    for _, event in ipairs({ "PLAYER_TALENT_UPDATE", "ACTIVE_TALENT_GROUP_CHANGED", "PLAYER_LEVEL_UP", "PLAYER_ENTERING_WORLD" }) do
        readable = true
        expectRanged("29.00%", "101", event .. " seed")
        expectOtherCompound(event .. " seed", live)
        kitEnv.__fireEvent("BAG_UPDATE_DELAYED")
        kitEnv.__fireEvent("COMBAT_RATING_UPDATE")
        readable = false
        expectRanged("(29.00%)", "(101)", "unrelated update keeps the last clean value")
        expectOtherCompound("unrelated update keeps the last clean value", previous)
        kitEnv.__fireEvent(event)
        kitEnv.__fireEvent(event)
        expectRanged("—", "—", event .. " clears old values even if emitted twice")
        expectOtherCompound(event .. " clears old values", dash)
    end
    profile.hideZeroOffensive = true
    kitTest.cacheSettings()
    readable, haste = true, 0
    check(not contains(kitTest.buildRenderBlocks()[2], "Ranged Haste"), "compound clean zero is hidden")
    haste = protectedHaste
    check(not contains(kitTest.buildRenderBlocks()[2], "Ranged Haste"), "compound same-context clean zero stays hidden")
    kitEnv.__fireEvent("ACTIVE_TALENT_GROUP_CHANGED")
    check(hasStat(kitTest.buildRenderBlocks()[2], "Ranged Haste", "32%"),
        "first live protected value in the new context is not suppressed by the old zero")
    rejectHaste = true
    check(not contains(kitTest.buildRenderBlocks()[2], "Ranged Haste"),
        "new context cannot infer nonzero when the native formatter fails")
    profile.hideZeroOffensive = false
    kitTest.cacheSettings()
    check(hasStat(kitTest.buildRenderBlocks()[2], "Ranged Haste", "—"),
        "formatting failure with no last clean value produces the cold marker")

    readable, haste = true, 29
    expectRanged("29.00%", "101", "normal form seed")
    readable = false
    kitEnv.__fireEvent("UPDATE_SHAPESHIFT_FORM")
    expectRanged("(29.00%)", "(101)", "duplicate normal-form event preserves last values")
    form = 1
    kitEnv.__fireEvent("UPDATE_SHAPESHIFT_FORM")
    expectRanged("—", "—", "new stance discards old values")
    readable, haste, power = true, 33, 105
    expectRanged("33.00%", "105", "new stance recovers")
    readable = false
    kitEnv.__fireEvent("UPDATE_SHAPESHIFT_FORM")
    expectRanged("(33.00%)", "(105)", "duplicate stance event preserves new values")
    form = protectedForm
    kitEnv.__fireEvent("UPDATE_SHAPESHIFT_FORM")
    expectRanged("—", "—", "unreadable new stance cannot reuse old values")
    readable, form = true, 1
    kitEnv.__fireEvent("UPDATE_SHAPESHIFT_FORM")
    expectRanged("33.00%", "105", "known stance can seed after unreadable identity")
    readable, form = false, nil
    kitEnv.__fireEvent("UPDATE_SHAPESHIFT_FORM")
    expectRanged("—", "—", "leaving a stance discards its values")

    profile.showOffensive, profile.showTertiary = false, false
    profile.showDurability, profile.showRepairCost = false, false
    for _, row in ipairs(kitAddon.forever.rows.character) do profile[row.showKey] = false end
    for _, row in ipairs(kitAddon.forever.rows.defensive) do profile[row.showKey] = row.key == "Defense" end
    readable = true
    kitTest.cacheSettings()
    check(kitAddon:RunUpdateStatsSafe(), "defensive-only source session seeds Defense")
    readable = false
    local reloadEnv, reloadAddon, reloadTest = fixtures.loadStatsPro("enUS", {
        forever = true,
        statsProDB = kitTest.profileState().root,
        unitGUID = function() return "Player-ForeverRangedRecovery" end,
        foreverAPIs = { UnitDefenseSkill = readDefense },
    })
    reloadEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    check(hasStat(reloadTest.buildRenderBlocks()[4], "Defense", "—"),
        "defensive-only reload renders a cold dash without carrying over a session cache")
    readable = true
    check(reloadAddon:RunUpdateStatsSafe(), "defensive-only reload recovers")
    local cleanPanel = reloadTest.panelVisualState()
    readable = false
    check(reloadAddon:RunUpdateStatsSafe(), "defensive-only fallback updates the HUD")
    local fallbackPanel = reloadTest.panelVisualState()
    check(hasStat(reloadTest.buildRenderBlocks()[4], "Defense", "(23)"),
        "defensive-only fallback has both parentheses")
    check(fallbackPanel.mainFrameHeight == cleanPanel.mainFrameHeight
        and fallbackPanel.mainRenderedRatingW == 0
        and fallbackPanel.mainRenderedValueW > cleanPanel.mainRenderedValueW,
        "parentheses grow only the existing value column and preserve row height")
end
check(hasStat(blocks[2], "Attack Power", "(11)"), "restricted AP shows the last pre-combat value")
check(hasStat(blocks[2], "Ranged Haste", "(14.00%)"), "restricted ranged haste uses the current fight snapshot")
check(hasStat(blocks[4], "Defense", "(5)"), "restricted defense uses the current fight snapshot")
check(hasStat(blocks[2], critLabel, "75%"), "restricted crit still shows its live value")
check(hasStat(blocks[2], "Melee Hit", "4.00%"), "clean hit remains live in combat")
hitBonus, hitModifier = -123456, -123456
check(hasStat(test.buildRenderBlocks()[2], "Melee Hit", "(4.00%)"), "restricted hit shows the last pre-combat value")
hitModifier = 0
check(hasStat(test.buildRenderBlocks()[2], "Melee Hit", "75%"), "exact restricted hit takes priority over fallback")
local round = env.C_StringUtil.RoundToNearestString
env.C_StringUtil.RoundToNearestString = nil
check(hasStat(test.buildRenderBlocks()[2], "Melee Hit", "(4.00%)"), "failed secret formatting uses the current snapshot")
env.C_StringUtil.RoundToNearestString = round
hitBonus, hitModifier = 5, 2
check(hasStat(test.buildRenderBlocks()[2], "Melee Hit", "7.00%"), "clean hit changes during combat")
hitBonus, hitModifier = -123456, -123456
check(hasStat(test.buildRenderBlocks()[2], "Melee Hit", "(7.00%)"), "a clean combat read replaces the previous sample")
local firstRestricted = table.concat(blocks[2].values, "\n") .. table.concat(blocks[2].ratings, "\n")
check(string.find(firstRestricted, "75", 1, true), "first restricted scalar displayed live")
secret = -123457
blocks = test.buildRenderBlocks()
local secondRestricted = table.concat(blocks[2].values, "\n") .. table.concat(blocks[2].ratings, "\n")
check(string.find(secondRestricted, "90", 1, true), "second consecutive restricted scalar displayed live")
check(not string.find(secondRestricted, "75", 1, true), "previous restricted scalar not cached")
combat, restricted = false, false
attackPower, hitBonus, hitModifier = 15, 0, 0
blocks = test.buildRenderBlocks()
check(hasStat(blocks[2], "Attack Power", "16"), "fresh AP immediately replaces fallback")
check(not contains(blocks[2], "Melee Hit"), "Hide Zero hides a confirmed zero")
combat, restricted = true, true
hitBonus, hitModifier = -123456, -123456
blocks = test.buildRenderBlocks()
check(hasStat(blocks[2], "Attack Power", "(16)"), "fallback refreshes before the next fight")
check(not contains(blocks[2], "Melee Hit"), "Hide Zero also hides a cached zero")
settings.hideZeroOffensive = false
test.cacheSettings()
check(hasStat(test.buildRenderBlocks()[2], "Melee Hit", "(0.00%)"), "cached zero is displayed when Hide Zero is off")
combat = false
check(hasStat(test.buildRenderBlocks()[2], "Attack Power", "(16)"), "fallback remains available outside combat")
combat = true
settings.showOffhandHit = true
test.cacheSettings()
check(hasStat(test.buildRenderBlocks()[2], "Offhand Hit", "—"), "first restricted read does not invent a fallback")
combat = false
test.buildRenderBlocks()
combat = true
check(hasStat(test.buildRenderBlocks()[2], "Attack Power", "(16)"), "unreadable sample leaves the last clean value intact")
combat, restricted = false, false
test.buildRenderBlocks()
combat, restricted = true, true
env.__fireEvent("PLAYER_REGEN_DISABLED")
combat = false
env.__fireEvent("PLAYER_REGEN_ENABLED")
combat = true
check(hasStat(test.buildRenderBlocks()[2], "Attack Power", "(16)"), "combat end keeps the last clean sample")
combat, restricted = false, false
settings.showTertiary, settings.showManaRegenMP5, settings.showCastingManaRegenMP5 = true, true, true
test.cacheSettings()
local function stripColor(text)
    return (text:gsub("|cff%x%x%x%x%x%x", ""):gsub("|r", ""))
end
local function hasManaRow(label, value)
    for _, block in ipairs(test.buildRenderBlocks()) do
        for index, rowLabel in ipairs(block.labels) do
            local text = block.ratings[index] .. block.values[index]
            local expectedLabel = label == "" and "" or label .. ":"
            if stripColor(rowLabel) == expectedLabel and stripColor(text) == value then
                return true
            end
        end
    end
    return false
end
check(hasManaRow("Mana Regen / 5 sec", "30.00"), "clean MP5")
combat = true
env.__fireEvent("PLAYER_REGEN_DISABLED")
check(hasManaRow("Mana Regen / 5 sec", "30.00") and hasManaRow("Casting Mana Regen / 5 sec", "5.00"),
    "both MP5 rows preserve distinct fixed rates in combat")
local _, diagnosticMP5 = addon.selfTest.ProbeRow("ManaRegenMP5")
check(diagnosticMP5 == 30, "self-test uses the same paired rate as the HUD")
combat, manaRegen, castingRegen = true, restrictedRegen, nextRestrictedRegen
check(hasManaRow("Mana Regen / 5 sec", "30.25"), "restricted base MP5 remains distinct in combat")
check(hasManaRow("Casting Mana Regen / 5 sec", "38.75"), "restricted casting MP5")
manaRegen, castingRegen = nextRestrictedRegen, restrictedRegen
check(hasManaRow("Mana Regen / 5 sec", "38.75"), "next restricted base MP5 is displayed live")
check(hasManaRow("Casting Mana Regen / 5 sec", "30.25"), "next casting MP5 is displayed live")
settings.labelStyle = "hidden"
test.cacheSettings()
check(hasManaRow("", "38.75/5s") and hasManaRow("", "30.25/5s"),
    "hidden-label restricted MP5 identifies both values as per five seconds")
settings.labelStyle = "full"
test.cacheSettings()
rejectMP5 = true
check(hasManaRow("Mana Regen / sec", "8"), "rejected paired base MP5 uses the per-second label")
check(hasManaRow("Casting Mana Regen / sec", "6"), "rejected casting MP5 uses the per-second label")
settings.labelStyle = "hidden"
test.cacheSettings()
check(hasManaRow("", "8/s") and hasManaRow("", "6/s"),
    "hidden-label MP5 fallbacks identify both values as per-second")
rejectMP5 = false
check(hasManaRow("", "8/s") and hasManaRow("", "6/s"),
    "protected MP5 formatter does not retry repeatedly in the same combat")
combat, manaRegen, castingRegen = false, 6, 1
env.__fireEvent("PLAYER_REGEN_ENABLED")
settings.showManaRegen, settings.showCastingManaRegen = true, true
test.cacheSettings()
check(hasManaRow("", "30.00/5s") and hasManaRow("", "5.00/5s")
    and hasManaRow("", "6.00/s") and hasManaRow("", "1.00/s"),
    "all clean hidden-label mana rows identify their unit")
settings.showManaRegen, settings.showCastingManaRegen = false, false
settings.showCastingManaRegenMP5 = false
settings.labelStyle = "full"
test.cacheSettings()
env.__fireEvent("PLAYER_REGEN_DISABLED")
check(hasManaRow("Mana Regen / 5 sec", "5.00"), "single MP5 follows combat entry while lockdown API lags")
combat = true
check(hasManaRow("Mana Regen / 5 sec", "5.00"), "single MP5 uses casting when lockdown catches up")
castingRegen = nextRestrictedRegen
check(hasManaRow("Mana Regen / 5 sec", "38.75"), "single MP5 uses first restricted casting rate")
castingRegen = restrictedRegen
check(hasManaRow("Mana Regen / 5 sec", "30.25"), "single MP5 uses next restricted casting rate")
manaRegen, castingRegen = 6, 1
env.__fireEvent("PLAYER_REGEN_ENABLED")
check(hasManaRow("Mana Regen / 5 sec", "30.00"), "single MP5 follows combat exit while lockdown API lags")
combat = false
check(hasManaRow("Mana Regen / 5 sec", "30.00"), "MP5 restored when restrictions end")
combat = true
check(hasManaRow("Mana Regen / 5 sec", "5.00"), "a settled hint cannot mask a missed entry event")
combat = false
env.__fireEvent("PLAYER_REGEN_DISABLED")
check(hasManaRow("Mana Regen / 5 sec", "5.00"), "a new unsettled transition overrides lockdown briefly")
env.__flushTimers(1)
check(hasManaRow("Mana Regen / 5 sec", "30.00"), "an unsettled transition cannot mask the API indefinitely")
env.__fireEvent("PLAYER_REGEN_ENABLED")
settings.hideZeroTertiary = true
test.cacheSettings()
combat, castingRegen = true, 0
check(not hasManaRow("Mana Regen / 5 sec", "0.00"), "Hide Zero hides clean zero casting rate")
combat, manaRegen = false, restrictedRegen
rejectMP5 = false
check(hasManaRow("Mana Regen / 5 sec", "30.25"), "casting zero does not hide protected resting rate")
manaRegen, castingRegen = 6, 1
settings.hideZeroTertiary = false
test.cacheSettings()
do
    local calls, classifications, normal, casting = 0, 0, 6, 1
    local mode
    local sampleEnv, sampleAddon, sampleTest = fixtures.loadStatsPro("enUS", {
        forever = true,
        unitGUID = function() return "Player-ManaSample" end,
        statsProDB = {
            showTertiary = true, hideZeroTertiary = false, showManaRegen = true,
            showCastingManaRegen = true, showManaRegenMP5 = true, showCastingManaRegenMP5 = true,
        },
        issecretvalue = function(value)
            if value == restrictedRegen or value == nextRestrictedRegen then
                classifications = classifications + 1
                return true
            end
            return false
        end,
        roundToNearestString = function(value)
            return value == restrictedRegen and "7" or "8"
        end,
        abbreviateNumbers = function(value)
            if value == restrictedRegen then return "35.00" end
            if value == nextRestrictedRegen then return "40.00" end
            return "10.25"
        end,
        foreverAPIs = {
            GetManaRegen = function()
                calls = calls + 1
                if mode == "mixed" then
                    return calls == 1 and restrictedRegen or nextRestrictedRegen, 0
                end
                if mode == "failure" then
                    if calls == 2 then error("mana API read failed") end
                    return restrictedRegen, calls == 1 and 2 or 4
                end
                return normal, casting
            end,
        },
    })
    sampleEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    local function renderMana()
        calls, classifications = 0, 0
        local result = {}
        for _, block in ipairs(sampleTest.buildRenderBlocks()) do
            for index, label in ipairs(block.labels) do
                result[stripColor(label)] = stripColor(block.ratings[index] .. block.values[index])
            end
        end
        return result
    end
    local rows = renderMana()
    check(calls == 1 and rows["Mana Regen / sec:"] == "6.00"
        and rows["Mana Regen / 5 sec:"] == "30.00"
        and rows["Casting Mana Regen / sec:"] == "1.00"
        and rows["Casting Mana Regen / 5 sec:"] == "5.00",
        "four clean mana rows share one API read")
    normal, casting = 9, 0
    rows = renderMana()
    check(calls == 1 and rows["Mana Regen / 5 sec:"] == "45.00"
        and rows["Casting Mana Regen / 5 sec:"] == "0.00",
        "next HUD pass samples changed rates and can reuse clean zero")
    mode = "mixed"
    rows = renderMana()
    check(calls == 2 and rows["Mana Regen / sec:"] == "7"
        and rows["Mana Regen / 5 sec:"] == "40.00"
        and rows["Casting Mana Regen / 5 sec:"] == "0.00",
        "restricted rates render separately while the clean sibling is shared")
    mode = "failure"
    rows = renderMana()
    check(calls == 3 and rows["Mana Regen / 5 sec:"] == "?"
        and rows["Casting Mana Regen / 5 sec:"] == "20.00",
        "a failed read does not leave a previously sampled clean rate in use")
    mode, normal, casting = nil, math.huge, 0
    rows = renderMana()
    check(calls == 2 and rows["Mana Regen / sec:"] == "?"
        and rows["Mana Regen / 5 sec:"] == "?" and rows["Casting Mana Regen / 5 sec:"] == "0.00",
        "nonfinite rates are never stored as clean samples")
    local single = sampleTest.profileState().settings
    single.showManaRegen, single.showCastingManaRegen, single.showCastingManaRegenMP5 = false, false, false
    sampleTest.cacheSettings()
    normal, casting = 6, restrictedRegen
    rows = renderMana()
    check(calls == 1 and classifications == 0 and rows["Mana Regen / 5 sec:"] == "30.00",
        "single adaptive mana row does not classify the unused API result")
    normal = 8
    local _, diagnostic = sampleAddon.selfTest.ProbeRow("ManaRegenMP5")
    check(calls == 2 and diagnostic == 40,
        "standalone self-test reads live independently of the HUD sample")
end
do
    local coldRegen, coldCrit = restrictedRegen, restrictedRegen
    local coldEnv, _, coldTest = fixtures.loadStatsPro("enUS", {
        forever = true,
        unitGUID = function() return "Player-ColdCombat" end,
        statsProDB = {
            showTertiary = true, hideZeroTertiary = true, showManaRegenMP5 = true,
            showOffensive = true, hideZeroOffensive = true, showMeleeCrit = true, showOffhandHit = true,
        },
        issecretvalue = function(number) return rawequal(number, restrictedRegen) end,
        abbreviateNumbers = function() return nil end,
        roundToNearestString = function() return "6" end,
        foreverAPIs = {
            GetCritChance = function() return coldCrit end,
            GetManaRegen = function() return coldRegen end,
        },
    })
    coldEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    local function visibleLabels()
        local labels = {}
        for _, block in ipairs(coldTest.buildRenderBlocks()) do
            for _, label in ipairs(block.labels) do
                labels[stripColor(label)] = true
            end
        end
        return labels
    end
    local visible = visibleLabels()
    check(visible["Melee Crit:"] and visible["Mana Regen / sec:"],
        "Hide Zero keeps live protected values on first restricted render")
    check(not visible["Offhand Hit:"], "Hide Zero suppresses genuinely unavailable stats")
    coldRegen, coldCrit = 0, 0
    visibleLabels()
    coldRegen, coldCrit = restrictedRegen, restrictedRegen
    visible = visibleLabels()
    check(not visible["Melee Crit:"] and not visible["Mana Regen / sec:"],
        "protected rows reuse an observed clean zero")
end
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
local help = "Parentheses show the last reliable value. A dash means no reliable value is available."
local _, compoundDetail = env.StatsProForeverMeleeHit.statsProTooltipProvider(env.StatsProForeverMeleeHit)
check(compoundDetail == help, "compound tooltip explains both display markers")
for _, group in ipairs({ "offensive", "defensive", "utility" }) do
    local master = env["StatsProForever" .. group .. "Master"]
    local row = addon.forever.rows[group][1]
    local child = env["StatsProForever" .. row.key]
    local hideZero = env["StatsProForever" .. group .. "HideZero"]
    local selection = test.profileState().settings[row.showKey]
    for _, enabled in ipairs({ false, true }) do
        master:SetChecked(enabled)
        master.scripts.OnClick(master)
        check(child:IsEnabled() == enabled, group .. " child follows live master toggle")
        check(hideZero:IsEnabled() == enabled, group .. " hide zero follows live master toggle")
        check(test.profileState().settings[row.showKey] == selection,
            group .. " master toggle preserves individual row choices")
    end
    local _, detail = child.statsProTooltipProvider(child)
    check(detail == "A ? means this stat is unavailable or cannot be calculated safely.",
        group .. " tooltip explains unavailable stat values")
    local masterKey = ({ offensive = "showOffensive", defensive = "showDefensive", utility = "showTertiary" })[group]
    test.profileState().settings[masterKey] = false
    test.cacheSettings()
    addon.profileRuntime.RefreshConfigControls()
    check(not child:IsEnabled() and not hideZero:IsEnabled(), group .. " refresh restores dependency state")
    local blocked = child.statsProTooltipProvider(child)
    check(blocked:find("Requires ", 1, true), group .. " disabled row explains its master dependency")
    master:SetChecked(true)
    master.scripts.OnClick(master)
end
check(test.settingsShellState().shell.titleMetadata:GetText():find("Forever Beta", 1, true),
    "Settings header identifies Forever beta")
check(test.launcherTitleText():find("Forever Beta", 1, true), "Settings launcher identifies Forever beta")
retailAddon:OpenConfigMenu()
check(retailTest.settingsShellState().shell.titleMetadata:GetText():find("Settings  v", 1, true),
    "Retail Settings header stays unchanged")
check(not retailTest.launcherTitleText():find("Forever", 1, true), "Retail launcher keeps its existing identity")
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
check(addon.selfTest.env.release == test.addonVersion(),
    "Forever selftest identifies its own build rather than the Retail release")
local observedKeys = {}
for _, key in ipairs(addon.selfTest.rowKeys) do observedKeys[key] = true end
check(observedKeys.SpellCrit and not observedKeys.Spirit and not observedKeys.mastery,
    "selftest catalogs only selected Forever rows")
addon.selfTest.TakeSample(false, false)
addon.selfTest.BuildReport()
local diagnostic = addon.selfTest.BuildPayload()
check(diagnostic:find("\nrelease=" .. test.addonVersion() .. "\n", 1, true),
    "copied Forever diagnostic retains the flavor build version")
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
local mp5Control = env.StatsProForeverManaRegenMP5
local _, mp5Help = mp5Control.statsProTooltipProvider()
local _, castingHelp = longControl.statsProTooltipProvider()
check(mp5Help:find("out of combat and the casting rate in combat", 1, true)
    and mp5Help:find("both 5-second rows", 1, true)
    and not castingHelp:find("both 5-second rows", 1, true),
    "only the adaptive row explains its mode switch and how to show both rates")
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
    check(repairTest.buildRenderBlocks()[7].repairStr == "—", "incomplete repair row shows a dash instead of partial sum")
    phase = "ready"
    check(repairEnv.__flushNextTimer(1), "repair retry timer runs")
    check(repairAddon:RunUpdateStatsSafe(), "repair retry update")
    check(repairTest.durabilityState().repairCostComplete and repairTest.durabilityState().repairCost == 579,
        "repair sums repairCost, not sellPrice")
    check(repairTest.buildRenderBlocks()[7].repairStr ~= "" and repairTest.buildRenderBlocks()[7].repairStr ~= "—",
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
do
    local rangedReady = false
    local gearEnv, gearAddon, gearTest = fixtures.loadStatsPro("enUS", {
        forever = true, unitGUID = function() return "Player-RangedHydrationForever" end,
        statsProDB = { showRepairCost = true, showDurability = true },
        getInventoryItemDurability = function(slot)
            if slot == 1 then return 80, 100 end
            if slot == 18 and rangedReady then return 20, 100 end
        end,
        getTooltipInventoryItem = function(_, slot)
            return { repairCost = slot == 18 and 200 or 100 }
        end,
    })
    -- Jewelry's cached nil/nil durability is complete; the same shape for an
    -- uncached ranged weapon must keep the aggregate unknown until hydration.
    gearEnv.GetInventoryItemID = function(_, slot)
        if slot == 2 then return 1002 end
        if slot == 18 then return 1018 end
    end
    gearEnv.C_Item = gearEnv.C_Item or {}
    gearEnv.C_Item.IsItemDataCachedByID = function(itemID)
        return itemID ~= 1018 or rangedReady
    end
    local money = gearEnv.GetCoinTextureString
    gearEnv.GetCoinTextureString = nil
    gearEnv.C_CurrencyInfo = { GetCoinTextureString = money }
    gearEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    check(gearAddon:RunUpdateStatsSafe(), "Forever ranged hydration initial update")
    local pending = gearTest.durabilityState()
    check(not pending.durabilityComplete and not pending.repairCostComplete,
        "uncached ranged weapon prevents partial durability and repair totals")
    check(gearTest.buildRenderBlocks()[7].repairStr == "—", "uncached ranged repair is unknown")
    check(not pending.dirty, "initial hydration scan coalesces work")
    gearEnv.__fireEvent("ITEM_DATA_LOAD_RESULT", 1002, true)
    check(not gearTest.durabilityState().dirty, "cached jewelry callback does not invalidate ranged hydration")
    rangedReady = true
    gearEnv.__fireEvent("ITEM_DATA_LOAD_RESULT", 1018, true)
    check(gearTest.durabilityState().dirty, "matching ranged item load invalidates cached aggregate")
    check(gearAddon:RunUpdateStatsSafe(), "Forever ranged hydration recovery update")
    local ready = gearTest.durabilityState()
    check(ready.durabilityComplete and ready.durabilityValue == 50,
        "hydrated ranged weapon contributes while cached nil jewelry remains complete")
    check(ready.repairCostComplete and ready.repairCost == 300,
        "hydrated ranged repair totals include both damaged durable slots")
    check(gearTest.buildRenderBlocks()[7].repairStr == "coin:300:14",
        "Forever ranged gear renders through namespaced money API without legacy global")
    check(gearEnv.StatsProFrame:IsShown(), "Forever HUD remains shown after hydration and money formatting")
end

do
    local paletteEnv, paletteAddon, paletteTest = fixtures.loadStatsPro("enUS", {
        forever = true, unitGUID = function() return "Player-ForeverPalette" end,
    })
    paletteEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    local function CustomPalette()
        local active = paletteTest.profileState().settings
        active.labelStyle = "full"
        active.showOffensive, active.showDefensive, active.showTertiary = true, true, true
        active.hideZeroOffensive, active.hideZeroDefensive, active.hideZeroTertiary = false, false, false
        for _, rows in pairs(paletteAddon.forever.rows) do
            for _, row in ipairs(rows) do active[row.showKey] = true end
        end
        for key in pairs(paletteAddon.forever.colorDefaults) do
            active.colors[key] = { r = .13, g = .27, b = .41 }
        end
        paletteTest.cacheSettings()
        return active, active.colors
    end
    local active, customColors = CustomPalette()
    local originalRoot = paletteEnv.StatsProDB
    check(paletteTest.appearancePresets.startPreview("monochrome"), "Forever monochrome preview starts")
    for _, block in ipairs(paletteTest.buildRenderBlocks()) do
        for _, label in ipairs(block.labels) do
            local red, green, blue = label:match("^|cff(%x%x)(%x%x)(%x%x)")
            check(red and red == green and red == blue, "actual Forever monochrome HUD labels are grayscale")
        end
    end
    check(paletteTest.appearancePresets.cancelPreview(), "Forever monochrome preview cancels")
    check(paletteEnv.StatsProDB == originalRoot and paletteTest.profileState().settings == active
        and active.colors == customColors, "cancel preserves exact custom profile palette identities")
    for key in pairs(paletteAddon.forever.colorDefaults) do
        local color = active.colors[key]
        check(color.r == .13 and color.g == .27 and color.b == .41,
            "cancel restores custom Forever color " .. key)
    end
    local groupOrder = { "character", "offensive", "utility", "defensive" }
    for _, id in ipairs(paletteTest.appearancePresets.order()) do
        CustomPalette()
        check(paletteTest.appearancePresets.startPreview(id), "Forever palette previews " .. id)
        check(paletteTest.appearancePresets.applyPreview(), "Forever palette applies " .. id)
        local applied = paletteTest.profileState().settings
        check(paletteTest.appearancePresets.currentID() == id, "Forever palette is recognized " .. id)
        local blocks = paletteTest.buildRenderBlocks()
        for key in pairs(paletteAddon.forever.colorDefaults) do
            local color = applied.colors[key]
            check(color ~= nil, id .. " has explicit Forever color " .. key)
            if id == "monochrome" then
                check(color.r == color.g and color.g == color.b, "monochrome palette stays gray " .. key)
            elseif id == "high-contrast" then
                check(math.max(color.r, color.g, color.b) == 1, "high-contrast palette stays bright " .. key)
            end
        end
        for index, group in ipairs(groupOrder) do
            for rowIndex, row in ipairs(paletteAddon.forever.rows[group]) do
                local color = applied.colors[row.colorKey]
                local expected = string.format("|cff%02x%02x%02x", math.floor(color.r * 255 + .5),
                    math.floor(color.g * 255 + .5), math.floor(color.b * 255 + .5))
                check(blocks[index].labels[rowIndex]:sub(1, 10) == expected,
                    id .. " actual HUD renders palette for " .. row.key)
            end
        end
    end
    for _, definition in pairs(retailTest.appearancePresets.definitions()) do
        for key in pairs(paletteAddon.forever.colorDefaults) do
            check(definition.colors[key] == nil, "Retail palette excludes Forever color " .. key)
        end
    end
    check(paletteAddon:RunUpdateStatsSafe(), "Forever renders its full stat catalog")
    local tooltipState = paletteTest.mainPanelTooltipState()
    check(tooltipState.overlayCount > 0 and tooltipState.lastTargetRows[1].key == "Strength"
        and tooltipState.lastTargetRows[1].target == nil,
        "Forever renders row tooltips independently of Archon comparison data")
    paletteTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    local tooltip = paletteEnv.StatsProTargetTooltip
    check(tooltip:IsShown() and tooltip.lines[1].left == "Strength", "Forever hover opens the actual stat")
    paletteTest.fireMainPanelTooltipOverlayForSmoke(1, "OnLeave")
    check(not tooltip:IsShown(), "Forever hover closes when the pointer leaves")
end
do
    local combatNow = false
    local firstAP, secondAP, protectedMultiplier = {}, {}, {}
    local currentAP = firstAP
    local conversionActive = false
    local apEnv, apAddon, apTest = fixtures.loadStatsPro("enUS", {
        forever = true,
        unitGUID = function() return "Player-ForeverProtectedAP" end,
        inCombatLockdown = function() return combatNow end,
        issecretvalue = function(value)
            return rawequal(value, firstAP) or rawequal(value, secondAP)
                or rawequal(value, protectedMultiplier)
        end,
        roundToNearestString = function(value)
            if rawequal(value, firstAP) then return "79" end
            if rawequal(value, secondAP) then return "95" end
            error("unexpected AP passed to native formatter")
        end,
        foreverAPIs = {
            UnitAttackPower = function()
                if combatNow then return currentAP, currentAP, currentAP end
                return 27, 52, 0
            end,
            GetOverrideAPBySpellPower = function() return combatNow and protectedMultiplier or 0 end,
            HasSPEffectsAttackPower = function() return conversionActive end,
            PlayerEffectiveAttackPower = function()
                return 207, 43, 128, combatNow and currentAP or 79, 0
            end,
        },
    })
    apEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    local apSettings = apTest.profileState().settings
    apSettings.showOffensive, apSettings.showAttackPower = true, true
    apSettings.hideZeroOffensive, apSettings.splitOffensive = true, true
    apTest.cacheSettings()
    check(hasStat(apTest.buildRenderBlocks()[2], "Attack Power", "79"),
        "clean AP establishes the character-sheet comparison")
    combatNow = true
    apEnv.__fireEvent("PLAYER_REGEN_DISABLED")
    check(hasStat(apTest.buildRenderBlocks()[2], "Attack Power", "79"),
        "first protected AP is rendered without an approximation marker")
    currentAP = secondAP
    for _, locale in ipairs({ "enUS", "enGB", "deDE", "esES", "esMX", "frFR",
        "itIT", "ptBR", "ruRU", "koKR", "zhCN", "zhTW" }) do
        apEnv.StatsProDB.account.forceLocale = locale
        for _, style in ipairs({ "full", "short", "hidden" }) do
            apSettings.labelStyle = style
            apTest.cacheSettings()
            local function verifyAP(expected)
                local rendered = apTest.buildRenderBlocks()
                for _, mode in ipairs({ "flat", "sectioned", "split" }) do
                    local main, side = apTest.routeRenderBlocks(rendered, mode, { splitOffensive = true }, style)
                    local bucket = mode == "split" and side or main
                    local found = false
                    for index, value in ipairs(bucket.values) do
                        if stripColor(bucket.ratings[index] .. value) == expected then found = true end
                    end
                    check(found, locale .. " " .. style .. " " .. mode .. " renders AP " .. expected)
                end
            end
            combatNow = false
            verifyAP("79")
            combatNow = true
            verifyAP("95")
            conversionActive = true
            verifyAP("(79)")
            conversionActive = false
            verifyAP("(79)")
        end
    end
    check(apAddon:RunUpdateStatsSafe(), "native AP display values flow through the real HUD update")

    apEnv.StatsProDB.account.forceLocale = "enUS"
    apSettings.labelStyle = "full"
    apSettings.hideZeroOffensive = false
    apTest.cacheSettings()
    conversionActive = true
    check(hasStat(apTest.buildRenderBlocks()[2], "Attack Power", "(79)"),
        "active conversion uses the last validated pre-combat total")
    conversionActive = false
    apEnv.__fireEvent("PLAYER_EQUIPMENT_CHANGED", 16, true)
    check(hasStat(apTest.buildRenderBlocks()[2], "Attack Power", "—"),
        "combat equipment change discards AP parity and the last clean number")
    combatNow = false
    apEnv.__fireEvent("PLAYER_REGEN_ENABLED")
    check(hasStat(apTest.buildRenderBlocks()[2], "Attack Power", "79"),
        "the next clean equipment sample recovers AP")
end
do
    local stat = 130
    local secretStat = {}
    local hoverEnv, hoverAddon, hoverTest = fixtures.loadStatsPro("enUS", {
        forever = true,
        unitGUID = function() return "Player-ForeverTooltip" end,
        issecretvalue = function(value) return value == secretStat end,
        roundToNearestString = function(value) return value == secretStat and "131" or tostring(value) end,
        getInventoryItemDurability = function(slot) if slot == 1 then return 90, 100 end end,
        getTooltipInventoryItem = function() return { repairCost = 12345 } end,
        foreverAPIs = {
            UnitStat = function() return 0, stat, 0, 0 end,
        },
    })
    hoverEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    local settings = hoverTest.profileState().settings
    for _, group in pairs(hoverAddon.forever.rows) do
        for _, row in ipairs(group) do settings[row.showKey] = false end
    end
    settings.showStrength, settings.showDurability, settings.showRepairCost = true, false, true
    settings.isLocked, settings.showItemLevel = false, false
    settings.fontSize = 24
    settings.displayMode = "sectioned"
    hoverTest.cacheSettings()
    check(hoverAddon:RunUpdateStatsSafe(), "Forever sectional hover updates")
    local info = hoverTest.mainPanelTooltipState()
    check(not info.firstShown and info.secondShown and info.lastTargetRows[1] == false,
        "section header has no overlay and stat keeps its visual index")
    local frame = hoverEnv.StatsProFrame
    frame.GetRight = function() return 990 end
    frame.GetEffectiveScale = function() return 1 end
    hoverEnv.UIParent.GetEffectiveScale = function() return 1 end
    hoverEnv.UIParent:SetWidth(1000)
    hoverTest.fireMainPanelTooltipOverlayForSmoke(2, "OnEnter")
    local tooltip = hoverEnv.StatsProTargetTooltip
    check(tooltip and tooltip:IsShown() and tooltip.lines[1].left == "Strength",
        "actual row opens its own tooltip")
    local point, relativeTo, relativePoint = tooltip:GetPoint()
    check(point == "TOPRIGHT" and relativeTo == tooltip:GetOwner() and relativePoint == "TOPLEFT",
        "tooltip opens inward beside the hovered row near the right edge")
    check(#tooltip.lines == 1 and tooltip.lines[1].right:find("130", 1, true)
        and tooltip.backdropColor.a == 1 and not tooltip.statDivider:IsShown()
        and tooltip.regions[1].leftText.justifyH == "LEFT"
        and tooltip.regions[1].rightText.justifyH == "RIGHT",
        "a stat without confirmed details shows just its header with no empty separator")
    local layouts = 0
    local oldLayout = tooltip.Layout
    tooltip.Layout = function(self)
        layouts = layouts + 1
        return oldLayout(self)
    end
    tooltip.layoutReusable = true
    check(hoverAddon:RunUpdateStatsSafe() and layouts == 0, "identical clean hover reuses its layout")
    hoverEnv.__fireEvent("UI_SCALE_CHANGED")
    check(hoverAddon:RunUpdateStatsSafe() and layouts == 1, "scale event invalidates the same hover layout")
    local reads = 0
    local function model(meta, add)
        if meta.key == "Strength" and meta.state == "clean" then
            reads = reads + 1
            add("Attack Power", tostring(meta.value * 2))
            add("Per point", "2", "rate")
            add(string.rep("Long translated label ", 10), "260")
        end
    end
    hoverAddon.forever.BuildAttackPowerTooltip = model
    check(hoverAddon:RunUpdateStatsSafe() and reads == 1, "only the hovered row calculates details")
    local totalLabel, rateLabel, nextLabel = tooltip.regions[2].leftText,
        tooltip.regions[3].leftText, tooltip.regions[4].leftText
    local _, _, _, totalX, totalY = totalLabel:GetPoint()
    local _, _, _, rateX, rateY = rateLabel:GetPoint()
    local _, _, _, _, nextY = nextLabel:GetPoint()
    check(#tooltip.lines == 4 and tooltip.statDivider:IsShown()
        and tooltip.lines[2].left == "Attack Power" and tooltip.lines[2].right == "260"
        and tooltip.lines[3].left == "Per point" and tooltip.lines[3].right == "2",
        "the confirmed contribution follows the header immediately with its per-point rate")
    check(rateX > totalX and totalY - rateY - totalLabel:GetHeight() < rateY - nextY - rateLabel:GetHeight(),
        "the indented rate is grouped more tightly with its contribution than with the next row")
    local last = tooltip.regions[#tooltip.lines]
    check(last.leftText.wordWrap and last.leftText:GetWidth() <= 224
        and last.leftText:GetHeight() > totalLabel:GetHeight(),
        "long detail captions wrap inside a bounded column")
    stat = secretStat
    check(hoverAddon:RunUpdateStatsSafe() and reads == 1 and tooltip:IsShown(),
        "restricted clean-input model is skipped while the tooltip stays open")
    info = hoverTest.mainPanelTooltipState()
    check(info.lastTargetRows[2].state == "secret" and info.lastTargetRows[2].value == nil,
        "protected raw input never enters tooltip metadata")
    check(#tooltip.lines == 1 and not tooltip.statDivider:IsShown() and not totalLabel:IsShown(),
        "a restricted reading clears the previous contribution rows and separator")
    hoverAddon.forever.ShowStatTooltip(tooltip:GetOwner(),
        { key = "Strength", label = "Strength", state = "stale", display = "(130)" })
    check(#tooltip.lines == 2 and tooltip.lines[2].left == "Last reliable reading",
        "stale totals retain their status note")

    settings.showStrength, settings.showAgility = false, true
    settings.displayMode, settings.splitRepairCost = "split", true
    hoverTest.cacheSettings()
    check(hoverAddon:RunUpdateStatsSafe() and not tooltip:IsShown(),
        "layout and semantic row changes retire an open tooltip")
    local coinFormatter = hoverEnv.GetCoinTextureString
    local coinSize
    hoverEnv.GetCoinTextureString = function(amount, size)
        coinSize = size
        return coinFormatter(amount, size)
    end
    hoverTest.firePanelTooltipOverlayForSmoke("side", 1, "OnEnter")
    check(tooltip:IsShown() and tooltip.lines[1].left == "Repair",
        "dedicated repair-only panel has its own hover row")
    check(coinSize == select(2, tooltip.regions[1].rightText:GetFont()), "repair coins match the header font")
    check(#tooltip.lines == 1 and not tooltip.statDivider:IsShown(), "repair shows just the current cost")
    hoverTest.firePanelTooltipOverlayForSmoke("side", 1, "OnDragStart")
    check(not tooltip:IsShown() and hoverTest.panelTooltipState("side").wasDragging,
        "starting a drag closes the Forever tooltip")
    hoverTest.firePanelTooltipOverlayForSmoke("side", 1, "OnDragStop")
    settings.showRepairCost = false
    hoverTest.cacheSettings()
    check(hoverAddon:RunUpdateStatsSafe() and not hoverTest.panelTooltipState("side").shown[1],
        "removing repair retires its separate overlay")
end
do
    local inCombat = false
    local rateEnv, rateAddon, rateTest = fixtures.loadStatsPro("enUS", {
        forever = true,
        unitGUID = function() return "Player-ForeverMP5Tooltip" end,
        inCombatLockdown = function() return inCombat end,
        foreverAPIs = { GetManaRegen = function() return 7, 1 end },
    })
    rateEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    local rateSettings = rateTest.profileState().settings
    for _, group in pairs(rateAddon.forever.rows) do
        for _, row in ipairs(group) do rateSettings[row.showKey] = false end
    end
    rateSettings.showTertiary, rateSettings.showManaRegenMP5 = true, true
    rateSettings.showItemLevel, rateSettings.showDurability, rateSettings.showRepairCost = false, false, false
    rateSettings.displayMode = "flat"
    rateTest.cacheSettings()
    check(rateAddon:RunUpdateStatsSafe(), "single adaptive MP5 draws before combat")
    rateTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    local tooltip = rateEnv.StatsProTargetTooltip
    local owner = tooltip and tooltip:GetOwner()
    check(tooltip:IsShown() and tooltip.lines[1].right:find("35.00", 1, true),
        "hovering the adaptive MP5 starts with the resting rate")
    inCombat = true
    rateEnv.__fireEvent("PLAYER_REGEN_DISABLED")
    check(rateAddon:RunUpdateStatsSafe() and tooltip:IsShown() and tooltip:GetOwner() == owner
        and tooltip.lines[1].right:find("5.00", 1, true) and not tooltip.lines[1].right:find("35.00", 1, true),
        "the same hover stays open and updates to the casting rate")
    inCombat = false
    rateEnv.__fireEvent("PLAYER_REGEN_ENABLED")
    check(rateAddon:RunUpdateStatsSafe() and tooltip:IsShown() and tooltip:GetOwner() == owner
        and tooltip.lines[1].right:find("35.00", 1, true),
        "the same hover restores the resting rate after combat")
end
do
    local inCombat, restrictedResting = false, false
    local protectedCasting, protectedResting = {}, {}
    local rateEnv, rateAddon, rateTest = fixtures.loadStatsPro("enUS", {
        forever = true,
        unitGUID = function() return "Player-ForeverMP5FallbackLabel" end,
        inCombatLockdown = function() return inCombat end,
        issecretvalue = function(value) return rawequal(value, protectedCasting)
            or rawequal(value, protectedResting) end,
        setFormattedText = function(_, _, value) return value == protectedCasting and "2.00" or "5.00" end,
        foreverAPIs = {
            GetManaRegen = function() return restrictedResting and protectedResting or 5, protectedCasting end,
            AbbreviateNumbers = function() return "2.05" end,
        },
    })
    rateEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    local rateSettings = rateTest.profileState().settings
    for _, group in pairs(rateAddon.forever.rows) do
        for _, row in ipairs(group) do rateSettings[row.showKey] = false end
    end
    rateSettings.showTertiary, rateSettings.showManaRegen, rateSettings.showManaRegenMP5 = true, true, true
    rateSettings.showItemLevel, rateSettings.showDurability, rateSettings.showRepairCost = false, false, false
    rateSettings.displayMode, rateSettings.labelStyle = "flat", "full"

    for _, locale in ipairs({ "enUS", "ruRU" }) do
        rateEnv.StatsProDB.account.forceLocale = locale
        rateTest.cacheSettings()
        local function checkRows(label, value)
            local block = rateTest.buildRenderBlocks()[3]
            check(#block.labels == 2 and hasStat(block, rateAddon.forever.Translate("Mana Regen / sec", locale), "5.00"),
                locale .. " resting per-second rate remains enabled")
            check(block.targetRows[2].key == "ManaRegenMP5" and block.targetRows[2].label == label
                and stripColor(block.labels[2]) == rateAddon.forever.Translate(label, locale) .. ":"
                and stripColor(block.ratings[2] .. block.values[2]) == value,
                locale .. " adaptive mana row uses its actual rate and unit")
        end

        check(rateAddon:RunUpdateStatsSafe(), "the adaptive mana row renders before combat")
        checkRows("Mana Regen / 5 sec", "25.00")
        rateTest.fireMainPanelTooltipOverlayForSmoke(2, "OnEnter")
        local tooltip = rateEnv.StatsProTargetTooltip
        local owner = tooltip:GetOwner()
        inCombat = true
        rateEnv.__fireEvent("PLAYER_REGEN_DISABLED")
        check(rateAddon:RunUpdateStatsSafe(), "the adaptive row keeps a live value when MP5 scaling is unavailable")
        checkRows("Casting Mana Regen / sec", "2.00")
        check(tooltip:IsShown() and tooltip:GetOwner() == owner
            and tooltip.lines[1].left == rateAddon.forever.Translate("Casting Mana Regen / sec", locale)
            and #tooltip.lines == 1 and stripColor(tooltip.lines[1].right) == "2.00",
            locale .. " the open tooltip follows the casting fallback without changing ownership")

        inCombat = false
        rateEnv.__fireEvent("PLAYER_REGEN_ENABLED")
        check(rateAddon:RunUpdateStatsSafe(), "the adaptive mana row renders after combat")
        checkRows("Mana Regen / 5 sec", "25.00")
        check(tooltip:IsShown() and tooltip:GetOwner() == owner
            and tooltip.lines[1].left == rateAddon.forever.Translate("Mana Regen / 5 sec", locale),
            locale .. " the open tooltip restores its usual resting caption")
        restrictedResting = true
        check(rateAddon:RunUpdateStatsSafe(), "the resting fallback accepts its live per-second value")
        checkRows("Mana Regen / sec", "5.00")
        check(tooltip:IsShown() and tooltip:GetOwner() == owner
            and tooltip.lines[1].left == rateAddon.forever.Translate("Mana Regen / sec", locale)
            and #tooltip.lines == 1 and stripColor(tooltip.lines[1].right) == "5.00",
            locale .. " the resting fallback shows the live per-second rate without a description")
        restrictedResting = false
    end
end
do
    local protectedNumber = {}
    local protectedText = "protected number text"
    local function isProtected(value)
        return rawequal(value, protectedNumber) or value == protectedText
    end
    local function renderText(blocks, key)
        for _, block in ipairs(blocks) do
            if block.splitKey == key then
                return table.concat(block.ratings) .. table.concat(block.values)
            end
        end
        error("expected to find HUD block " .. key)
    end
    for _, flavor in ipairs({ "Retail", "Forever" }) do
        local isForever = flavor == "Forever"
        for _, scenario in ipairs({
            { "empty primary", "", "13", "13%" },
            { "empty fallback", false, "", "?%" },
            { "protected primary", protectedText, "unexpected fallback", protectedText },
            { "protected fallback", false, protectedText, protectedText .. "%" },
        }) do
            local name, primary, fallback, expected = unpack(scenario)
            local fallbackCalls = 0
            local client, subject, view = fixtures.loadStatsPro("enUS", {
                forever = isForever,
                statsProDB = {
                    dbVersion = 9, showDefensive = true, showParry = true,
                    showPercentage = true, showRating = false, hideZeroDefensive = false,
                },
                issecretvalue = isProtected,
                getParryChance = function() return protectedNumber end,
                setFormattedText = function(_, _, value)
                    assert(rawequal(value, protectedNumber))
                    if primary == false then error("native formatter unavailable") end
                    return primary
                end,
                roundToNearestString = function(value)
                    assert(rawequal(value, protectedNumber))
                    fallbackCalls = fallbackCalls + 1
                    return fallback
                end,
            })
            client.__fireEvent("PLAYER_ENTERING_WORLD")
            check(subject:RunUpdateStatsSafe(), flavor .. " " .. name .. " formatting does not abort")
            local text = renderText(view.buildRenderBlocks(), "splitDefensive")
            check(text:find(expected, 1, true) ~= nil, flavor .. " " .. name .. " yields " .. expected)
            check((fallbackCalls == 0) == (name == "protected primary"),
                flavor .. " " .. name .. " observes the native fallback boundary")
        end

        local client, subject, view = fixtures.loadStatsPro("enUS", {
            forever = isForever,
            statsProDB = {
                dbVersion = 9, showTertiary = true, showSpeed = true, showMovementSpeed = true,
                showPercentage = true, showRating = false, hideZeroTertiary = false,
            },
            issecretvalue = isProtected,
            getUnitSpeed = function() return 0, protectedNumber end,
            abbreviateNumbers = function(value)
                if rawequal(value, protectedNumber) then return "" end
                return value == 7 and "100%" or "150%"
            end,
            setFormattedText = function(_, format, value)
                assert(rawequal(value, protectedNumber) and format == "%.1f yd/s")
                return "12.5 yd/s"
            end,
        })
        client.__fireEvent("PLAYER_ENTERING_WORLD")
        check(subject:RunUpdateStatsSafe(), flavor .. " empty scaled movement formatting does not abort")
        check(renderText(view.buildRenderBlocks(), "splitTertiary"):find("12.5 yd/s", 1, true) ~= nil,
            flavor .. " empty scaled movement text uses live yards per second")
    end

    local spellReads = 0
    local client, subject = fixtures.loadStatsPro("enUS", {
        getSpellCritChance = function()
            spellReads = spellReads + 1
            return 2
        end,
    })
    client.MAX_SPELL_SCHOOLS = 10000
    subject.GetBestCritChance()
    check(spellReads == 6, "an overwritten upper bound cannot expand the supported spell school scan")
    spellReads = 0
    client.MAX_SPELL_SCHOOLS = 5
    subject.GetBestCritChance()
    check(spellReads == 4, "a valid smaller school limit still controls the scan")
end
print("StatsPro Forever HUD integration: PASS (" .. count .. " checks)")
