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

do
    local available, combat = false, false
    local function allowFont(_, path)
        return available or not path:find("AntraktUISans.ttf", 1, true)
    end
    local env, addon, test = loadStatsPro("enUS", {
        lsmFonts = {},
        unitGUID = function() return "Player-1-COLD-NAME" end,
        unitFullName = function() return "Охотник", "Сервер" end,
        getSpecialization = function() return 1 end,
        specID = 73,
        setFontResult = allowFont,
        fontObjectSetFontResult = allowFont,
        inCombatLockdown = function() return combat end,
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    addon:OpenConfigMenu()
    local header = env.StatsProActiveProfileButton.statsProText
    local baseline = addon.sharedFonts.baseline.path
    local fallback = header:GetFont()
    local text = header:GetText()
    local first = env.UIParent:CreateFontString()
    assert(test.registerConfigFont(first, 12, nil, "coldNameRows", true))
    assert(fallback and fallback ~= baseline and text:find("Охотник", 1, true),
        "cold names keep a valid font and their original text")
    addon:RunUpdateStatsSafe()
    combat, available = true, true
    env.__flushTimers(1)
    addon:RunUpdateStatsSafe()
    assert(header:GetFont() == fallback, "cold-name recovery waits for combat to end")
    combat = false
    local second = env.UIParent:CreateFontString()
    assert(test.registerConfigFont(second, 12, nil, "coldNameRows", true))
    assert(first:GetFont() == baseline and second:GetFont() == baseline,
        "registering a new row can upgrade an existing shared font group")
    assert(addon.fontRuntime.ConfigFontDiagnostic():find("mismatched=0", 1, true),
        "upgrading a shared font group updates diagnostics for its existing rows")
    addon.profileUI.OpenManager(true)
    assert(addon.profileUI.managerRows[1].text:GetFont() == baseline and header:GetFont() == fallback,
        "new regions can use the ready face before the existing regions are reconciled")
    for _ = 1, 12 do addon:RunUpdateStatsSafe(); env.__flushTimers(1) end
    assert(header:GetFont() == baseline and header:GetText() == text,
        "cold names automatically recover the bundled font and original text")
    assert(test.configFontState().currentFont == fallback, "name recovery preserves the English UI face")
end
do
    local headerSizeReady = false
    local function allowFont(_, path, size)
        return headerSizeReady or size ~= 12 or not path:find("AntraktUISans.ttf", 1, true)
    end
    local env, addon = loadStatsPro("enUS", {
        lsmFonts = {},
        unitGUID = function() return "Player-1-COLD-NAME-SIZE" end,
        unitFullName = function() return "Охотник", "Сервер" end,
        getSpecialization = function() return 1 end,
        specID = 73,
        setFontResult = allowFont,
        fontObjectSetFontResult = allowFont,
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    addon:OpenConfigMenu()
    local header = env.StatsProActiveProfileButton.statsProText
    local baseline = addon.sharedFonts.baseline.path
    assert(header:GetFont() ~= baseline, "probe readiness alone does not guarantee the requested size")
    headerSizeReady = true
    for _ = 1, 12 do addon:RunUpdateStatsSafe(); env.__flushTimers(1) end
    assert(header:GetFont() == baseline, "a failed name role recovers after its size becomes available")
end
print(flavor .. " cold name font recovery regressions passed")

-- A client exposing only the namespaced money API must still render both gear rows.
for _, mode in ipairs({ "modern", "modern-only", "legacy", "missing", "throwing",
    "nil-return", "number-return", "empty-return", "secret-return", "plain-only",
    "plain-fallback", "plain-secret", "plain-throwing", "legacy-rescue", "aliased-texture" }) do
    local env, addon, test = loadStatsPro("enUS", {
        statsProDB = { showDurability = true, showRepairCost = true },
        getInventoryItemDurability = function(slot)
            if slot == 1 then return 70, 100 end
        end,
        getTooltipInventoryItem = function() return { repairCost = 4458354 } end,
        issecretvalue = function(value) return value == "restricted-money" end,
    })
    local legacy = env.GetCoinTextureString
    local plainCalls, legacyCalls, textureCalls = 0, 0, 0
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
    if mode:find("plain-", 1, true) then
        env.C_CurrencyInfo = { GetCoinText = function(amount, separator)
            plainCalls = plainCalls + 1
            assert(amount == 4458354 and separator == " ", "native plain formatter needs the exact copper amount")
            if mode == "plain-secret" then return "restricted-money" end
            if mode == "plain-throwing" then error("plain formatter unavailable") end
            return "445 Gold 83 Silver 54 Copper"
        end }
        if mode == "plain-fallback" then
            env.C_CurrencyInfo.GetCoinTextureString = function() return "restricted-money" end
        end
    end
    if mode == "legacy-rescue" or mode == "aliased-texture" then
        local function unusableTexture()
            textureCalls = textureCalls + 1
            return nil
        end
        env.GetCoinTextureString = mode == "aliased-texture" and unusableTexture or function(...)
            legacyCalls = legacyCalls + 1
            return legacy(...)
        end
        env.C_CurrencyInfo = {
            GetCoinTextureString = unusableTexture,
            GetCoinText = function() plainCalls = plainCalls + 1 end,
        }
    end
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    assert(addon:RunUpdateStatsSafe(), mode .. ": repair formatting must not abort HUD rendering")
    assert(env.StatsProFrame:IsShown(), mode .. ": HUD remains visible")
    local state = test.durabilityState()
    assert(state.durabilityValue == 70 and state.repairCost == 4458354, mode .. ": gear data remains complete")
    plainCalls, legacyCalls, textureCalls = 0, 0, 0
    local text = test.formatRepairCost(4458354, 15)
    local expected = "—"
    if mode == "modern" or mode == "modern-only" or mode == "legacy" or mode == "legacy-rescue" then
        expected = "coin:4458354:15"
    elseif mode == "plain-only" or mode == "plain-fallback" then
        expected = "445 Gold 83 Silver 54 Copper"
    end
    assert(text == expected, mode .. ": repair display")
    if mode:find("plain-", 1, true) then
        assert(plainCalls == 1, mode .. ": use the native plain formatter")
    elseif mode == "legacy-rescue" then
        assert(textureCalls == 1 and legacyCalls == 1 and plainCalls == 0,
            "a working distinct legacy texture formatter takes priority over plain text")
    elseif mode == "aliased-texture" then
        assert(textureCalls == 1 and plainCalls == 1, "a failing aliased texture formatter is called only once")
    end
    if mode == "plain-fallback" then
        env.__fireEvent("AUCTION_HOUSE_SHOW")
        assert(addon:RunUpdateStatsSafe(), "known repair data still renders during an auction")
        local repairBlock
        for _, block in ipairs(test.buildRenderBlocks()) do
            if block.splitKey == "splitRepairCost" then
                repairBlock = block
                break
            end
        end
        assert(repairBlock and repairBlock.repairStr == expected and repairBlock.repairLabelStr:find("Repair", 1, true),
            "the auction HUD uses exact plain text when texture formatting fails")
    end
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

for _, modernInteraction in ipairs({ false, true }) do
    local cost, reads = 300, 0
    local env, addon, test = loadStatsPro("enUS", {
        statsProDB = { showDurability = true, showRepairCost = true },
        getInventoryItemDurability = function(slot)
            if slot == 1 then return 80, 100 end
        end,
        getTooltipInventoryItem = function()
            reads = reads + 1
            if cost then return { repairCost = cost } end
        end,
    })
    local function repairBlock()
        for _, block in ipairs(test.buildRenderBlocks()) do
            if block.splitKey == "splitRepairCost" then return block end
        end
    end
    local auctioneer, banker = 21, 8
    env.Enum = modernInteraction and { PlayerInteractionType = { Auctioneer = auctioneer } } or nil
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    if modernInteraction then
        env.__fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", auctioneer)
    else
        env.__fireEvent("AUCTION_HOUSE_SHOW")
    end
    assert(addon:RunUpdateStatsSafe() and repairBlock().repairStr == test.formatRepairCost(300, 14),
        "auction does not hide a readable repair cost")
    cost = nil
    env.__fireEvent("UPDATE_INVENTORY_DURABILITY")
    assert(addon:RunUpdateStatsSafe(), "unavailable auction-time repair data does not interrupt the HUD")
    env.__fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", banker)
    assert(repairBlock().repairStr == "" and repairBlock().repairLabelStr == nil
        and test.durabilityState().durabilityValue == 80,
        "auction hides the unresolved repair row and keeps readable durability")
    cost = 450
    local before = reads
    if modernInteraction then
        env.__fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", auctioneer)
    else
        env.__fireEvent("AUCTION_HOUSE_CLOSED")
    end
    local generation = addon.durabilityRuntime.generation
    env.__fireEvent("AUCTION_HOUSE_CLOSED")
    env.__fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", auctioneer)
    assert(reads == before and test.durabilityState().dirty,
        "closing the auction queues a repair refresh without reading in the event handler")
    assert(addon.durabilityRuntime.generation == generation,
        "duplicate close notifications don't reopen the retry budget")
    assert(addon:RunUpdateStatsSafe() and reads == before + 1 and test.durabilityState().repairCost == 450,
        "closing the auction restores the current cost")
    before = reads
    env.__fireEvent("AUCTION_HOUSE_CLOSED")
    assert(addon:RunUpdateStatsSafe() and reads == before, "complete repair costs need no extra auction-close scan")
    cost = nil
    env.__fireEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", banker)
    env.__fireEvent("UPDATE_INVENTORY_DURABILITY")
    assert(addon:RunUpdateStatsSafe() and repairBlock().repairStr == "—",
        "other NPC interactions do not suppress unresolved repair")
end
print(flavor .. " auction repair display regressions passed")

for _, missing in ipairs({ "durability", "repair", "empty" }) do
    for _, persistent in ipairs({ false, true }) do
        local available, reads = true, 0
        local env, addon, test = loadStatsPro("enUS", {
            statsProDB = { showDurability = true, showRepairCost = true, showItemLevel = false },
            getInventoryItemDurability = function(slot)
                if slot ~= 1 then return end
                reads = reads + 1
                if missing == "repair" or available then return available and 60 or 65, 100 end
            end,
            getTooltipInventoryItem = function()
                if missing ~= "repair" or available then return { repairCost = 200 } end
            end,
        })
        if missing ~= "empty" then
            env.GetInventoryItemID = function(_, slot) if slot == 1 then return 1337 end end
            env.C_Item = { IsItemDataCachedByID = function() return true end }
        end
        env.__fireEvent("PLAYER_ENTERING_WORLD")
        assert(test.durabilityState().durabilityValue == 60 and test.durabilityState().repairCost == 200,
            "fixture starts with complete wear and repair cost")
        local after = env.C_Timer.After
        local arms = 0
        local retryKind = missing == "repair" and "repair" or "durability"
        local attemptKey, scheduledKey = retryKind .. "RetryAttempt", retryKind .. "RetryScheduled"
        env.C_Timer.After = function(delay, callback)
            after(delay, callback)
            if delay >= 1 then
                arms = arms + 1
                if persistent or arms == 1 then error("native gear retry timer rejected") end
            end
        end
        available = false
        env.__fireEvent("UPDATE_INVENTORY_DURABILITY")
        assert(addon:RunUpdateStatsSafe(), "a rejected gear retry timer cannot abort the HUD update")
        local first = test.durabilityState()
        assert(arms == 1 and first[attemptKey] == 1 and not first[scheduledKey] and first.dirty,
            "failed arm spends one attempt and leaves a coalesced update")
        if persistent then
            for _ = 1, 2 * first.retryLimit do assert(addon:RunUpdateStatsSafe()) end
            local exhausted = test.durabilityState()
            local before = reads
            assert(arms == first.retryLimit and exhausted[attemptKey] == first.retryLimit
                and not exhausted[scheduledKey] and not exhausted.dirty,
                "persistent failure spends only the bounded retry budget")
            assert(exhausted.durabilityValue ~= nil and exhausted.repairCost == nil,
                "failed timers cannot replace last clean wear with an authoritative empty inventory")
            env.__flushTimers(15)
            assert(addon:RunUpdateStatsSafe() and reads == before,
                "partially registered timers cannot wake an exhausted generation")
            env.__fireEvent("UPDATE_INVENTORY_DURABILITY")
        end
        available = true
        assert(addon:RunUpdateStatsSafe(), "the next coalesced update succeeds")
        local recovered = test.durabilityState()
        assert(recovered.durabilityValue == 60 and recovered.repairCost == 200 and not recovered.dirty
            and not recovered[scheduledKey], "complete gear data recovers")
        if not persistent then
            local before = reads
            env.__flushTimers(1)
            assert(addon:RunUpdateStatsSafe() and reads == before,
                "a partially registered timer cannot wake already recovered gear")
        end
    end
end
print(flavor .. " durability and repair timer recovery regressions passed")

for _, persistentFailure in ipairs({ false, true }) do
    local available, reads = true, 0
    local function readAverageItemLevel()
        reads = reads + 1
        if available then return 101, 100 end
    end
    local env, addon, test = loadStatsPro("enUS", {
        statsProDB = { showItemLevel = true, showDurability = false, showRepairCost = false },
        getAverageItemLevel = readAverageItemLevel,
        foreverAPIs = { GetAverageItemLevel = readAverageItemLevel },
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    assert(test.itemLevelState().equipped == 100, "fixture first samples equipped item level")
    local after = env.C_Timer.After
    local arms = 0
    env.C_Timer.After = function(delay, callback)
        if delay >= 1 then
            arms = arms + 1
            if persistentFailure or arms == 1 then
                -- The native timer may register a callback before raising.
                after(delay, callback)
                error("native item-level retry timer rejected")
            end
        end
        return after(delay, callback)
    end
    available = false
    env.__fireEvent("BAG_UPDATE_DELAYED")
    local retryLimit = test.itemLevelState().retryLimit
    for _ = 1, retryLimit do
        assert(addon:RunUpdateStatsSafe(), "a rejected item-level timer cannot abort the HUD update")
    end
    assert(arms == 1 and test.itemLevelState().dirty,
        "failed timer arm leaves one bounded retry on the existing ticker")
    if persistentFailure then
        for _ = 1, 12 do assert(addon:RunUpdateStatsSafe()) end
        assert(arms == 4 and not test.itemLevelState().dirty, "persistent timer failures exhaust bounded attempts")
        local settledReads = reads
        env.__flushTimers(15)
        assert(addon:RunUpdateStatsSafe() and settledReads == reads,
            "partially registered timers cannot wake an exhausted generation")
        env.__fireEvent("BAG_UPDATE_DELAYED")
    end
    available = true
    assert(addon:RunUpdateStatsSafe() and test.itemLevelState().complete,
        "a readable item level recovers on the next eligible scan")
end

do
    local slot = forever and 18 or 17
    local equippedID, current, maximum = 1337, 40, 100
    local identityUnavailable, durabilityUnavailable = false, false
    local env, addon, test = loadStatsPro("enUS", {
        statsProDB = { showDurability = true, showRepairCost = true, useWorstDurability = false },
        getInventoryItemDurability = function(index)
            if index == 1 then return 80, 100 end
            if index == slot then
                if durabilityUnavailable then error("equipped durability temporarily unavailable") end
                return current, maximum
            end
        end,
        getTooltipInventoryItem = function(_, index)
            return { repairCost = index == slot and 300 or 100 }
        end,
    })
    env.GetInventoryItemID = function(_, index)
        if index == slot then
            if identityUnavailable then error("equipped identity temporarily unavailable") end
            return equippedID
        end
    end
    env.C_Item = { IsItemDataCachedByID = function() return true end }
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    local state = test.durabilityState()
    assert(state.durabilityComplete and state.durabilityValue == 60 and state.repairCost == 400,
        "both durable pieces seed the complete equipped totals")
    current, maximum = nil, nil
    env.__fireEvent("UPDATE_INVENTORY_DURABILITY")
    assert(addon:RunUpdateStatsSafe(), "temporary empty durability data renders safely")
    state = test.durabilityState()
    assert(not state.durabilityComplete and state.durabilityValue == 60,
        "a cached, still-equipped durable item cannot silently disappear from the average")
    assert(not state.repairCostComplete and state.repairCost == nil and state.durabilityRetryScheduled,
        "repair must not show a partial total while the same durable item is unreadable")
    current, maximum = 10, 100
    assert(env.__flushNextTimer() and addon:RunUpdateStatsSafe(), "durability retry reads the restored item")
    state = test.durabilityState()
    assert(state.durabilityComplete and state.durabilityValue == 45 and state.repairCost == 400,
        "complete readings resume as soon as the existing item is readable")
    current, maximum = nil, nil
    env.__fireEvent("UPDATE_INVENTORY_DURABILITY")
    assert(addon:RunUpdateStatsSafe(), "durable item can become temporarily unreadable again")
    local limit = test.durabilityState().retryLimit
    for _ = 1, limit do
        assert(env.__flushNextTimer() and addon:RunUpdateStatsSafe(), "drain bounded durability retries")
    end
    state = test.durabilityState()
    assert(not state.dirty and not state.durabilityRetryScheduled and state.repairCost == nil,
        "exhausted retries leave the cost unresolved")
    env.__fireEvent("GET_ITEM_INFO_RECEIVED", 99, true)
    env.__fireEvent("GET_ITEM_INFO_RECEIVED", 1337, false)
    equippedID = 99
    env.__fireEvent("GET_ITEM_INFO_RECEIVED", 1337, true)
    assert(not test.durabilityState().dirty, "foreign, failed and stale item data cannot wake durability")
    equippedID = 1337
    env.__fireEvent("ITEM_DATA_LOAD_RESULT", 1337, true)
    assert(test.durabilityState().dirty and addon:RunUpdateStatsSafe(), "first matching event wakes the scan")
    state = test.durabilityState()
    assert(state.durabilityRetryAttempt == limit and not state.durabilityRetryScheduled,
        "a matching event does not restart the bounded retry budget")
    env.__fireEvent("ITEM_DATA_LOAD_RESULT", 1337, true)
    assert(not test.durabilityState().dirty, "a duplicate readiness event cannot spin another scan")
    identityUnavailable = true
    env.__fireEvent("UPDATE_INVENTORY_DURABILITY")
    assert(addon:RunUpdateStatsSafe(), "new inventory generation can collect fresh evidence")
    env.__fireEvent("ITEM_DATA_LOAD_RESULT", 1337, true)
    assert(not test.durabilityState().dirty, "unknown current identity cannot validate item readiness")
    identityUnavailable = false
    current, maximum = 30, 100
    env.__fireEvent("ITEM_DATA_LOAD_RESULT", 1337, true)
    assert(test.durabilityState().dirty and addon:RunUpdateStatsSafe(), "next generation can use matching late data")
    state = test.durabilityState()
    assert(state.durabilityComplete and state.durabilityValue == 55 and state.repairCost == 400,
        "matching readiness restarts complete durability and repair")
    durabilityUnavailable = true
    env.__fireEvent("UPDATE_INVENTORY_DURABILITY")
    assert(addon:RunUpdateStatsSafe(), "durability exceptions leave the scan incomplete")
    for _ = 1, limit do
        assert(env.__flushNextTimer() and addon:RunUpdateStatsSafe(), "drain retries after API failure")
    end
    durabilityUnavailable = false
    env.__fireEvent("ITEM_DATA_LOAD_RESULT", 1337, true)
    assert(test.durabilityState().dirty and addon:RunUpdateStatsSafe(), "late data also recovers after API exceptions")
    state = test.durabilityState()
    assert(state.durabilityComplete and state.durabilityValue == 55 and state.repairCost == 400,
        "late recovery restores complete totals after API exceptions")
    for _, partial in ipairs({ {}, { current = 110 } }) do
        current, maximum = partial.current, 100
        env.__fireEvent("UPDATE_INVENTORY_DURABILITY")
        assert(addon:RunUpdateStatsSafe(), "invalid durability pair leaves the scan incomplete")
        for _ = 1, limit * 3 do
            state = test.durabilityState()
            if not (state.durabilityRetryScheduled or state.repairRetryScheduled) then break end
            assert(env.__flushNextTimer() and addon:RunUpdateStatsSafe(), "drain retries after invalid pair")
        end
        state = test.durabilityState()
        assert(not state.dirty and not state.durabilityRetryScheduled and not state.repairRetryScheduled
            and state.durabilityValue == 55 and state.repairCost == nil,
            "invalid durability pairs preserve the last total and suppress incomplete repair")
        current = 30
        env.__fireEvent("ITEM_DATA_LOAD_RESULT", 1337, true)
        assert(test.durabilityState().dirty and addon:RunUpdateStatsSafe(),
            "matching late item data wakes the scan after an invalid durability pair")
        state = test.durabilityState()
        assert(state.durabilityComplete and state.durabilityValue == 55 and state.repairCost == 400,
            "late item data recovers both totals after invalid pairs")
    end
    equippedID, durabilityUnavailable = 99, true
    env.__fireEvent("PLAYER_EQUIPMENT_CHANGED", slot, true)
    assert(addon:RunUpdateStatsSafe(), "replacement with unavailable durability remains incomplete")
    for _ = 1, limit + 1 do
        if not test.durabilityState().durabilityRetryScheduled then break end
        assert(env.__flushNextTimer() and addon:RunUpdateStatsSafe(), "drain retries for replacement item")
    end
    state = test.durabilityState()
    assert(state.durabilityRetryAttempt == limit and not state.durabilityRetryScheduled,
        "replacement item retries stop at the configured limit")
    env.__fireEvent("ITEM_DATA_LOAD_RESULT", 1337, true)
    assert(not test.durabilityState().dirty, "old item cannot wake the replacement scan")
    env.__fireEvent("ITEM_DATA_LOAD_RESULT", 99, true)
    assert(test.durabilityState().dirty and addon:RunUpdateStatsSafe(), "replacement ID wakes its own scan")
    state = test.durabilityState()
    assert(state.durabilityRetryAttempt == limit and not state.durabilityRetryScheduled,
        "replacement readiness after API failure does not restart the retry budget")
    env.__fireEvent("GET_ITEM_INFO_RECEIVED", 99, true)
    assert(not test.durabilityState().dirty, "duplicates cannot wake an unavailable replacement again")
    equippedID = 100
    env.__fireEvent("PLAYER_EQUIPMENT_CHANGED", slot, true)
    assert(addon:RunUpdateStatsSafe(), "a new inventory generation retries the next replacement")
    durabilityUnavailable, current, maximum = false, 50, 100
    env.__fireEvent("GET_ITEM_INFO_RECEIVED", 100, true)
    assert(test.durabilityState().dirty and addon:RunUpdateStatsSafe(), "late replacement data completes the scan")
    state = test.durabilityState()
    assert(state.durabilityComplete and state.durabilityValue == 65 and state.repairCost == 400,
        "newly readable replacement contributes its own durability and repair cost")
    equippedID, current, maximum = 99, 0, 0
    env.__fireEvent("PLAYER_EQUIPMENT_CHANGED", slot, true)
    assert(addon:RunUpdateStatsSafe(), "replacement slot renders safely")
    state = test.durabilityState()
    assert(state.durabilityComplete and state.durabilityValue == 80 and state.repairCost == 100,
        "a different cached item with no durability does not inherit the old identity")
end
print(flavor .. " equipped durability completeness regressions passed")

do
    local pendingSlot = forever and 18 or 16
    local available, reads = false, 0
    local identityMode, secretItem = "throws", {}
    local equipped = { [1] = 1001, [11] = 1011, [17] = 1017, [pendingSlot] = 2000 }
    local env, addon, test = loadStatsPro("enUS", {
        statsProDB = { showDurability = true, showRepairCost = true, useWorstDurability = false },
        getInventoryItemDurability = function(slot)
            if slot == 1 then return 80, 100 end
            if slot == pendingSlot then
                reads = reads + 1
                if available then return 20, 100 end
            end
        end,
        getTooltipInventoryItem = function(_, slot) return { repairCost = slot == 1 and 100 or 300 } end,
        issecretvalue = function(value) return value == secretItem end,
    })
    env.GetInventoryItemID = function(_, slot)
        if slot == pendingSlot then
            if identityMode == "throws" then error("equipped identity unavailable") end
            if identityMode == "secret" then return secretItem end
            if identityMode == "invalid" then return 0 end
        end
        return equipped[slot]
    end
    env.Enum = { InventoryType = { IndexHoldableType = 23, IndexRelicType = 28 } }
    env.C_Item = {
        IsItemDataCachedByID = function() return true end,
        GetItemInventoryTypeByID = function(itemID)
            if itemID == 1017 then return env.Enum.InventoryType.IndexHoldableType end
            if itemID == 2001 then return env.Enum.InventoryType.IndexRelicType end
        end,
    }
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    for _, mode in ipairs({ "throws", "secret", "invalid", "cached" }) do
        identityMode = mode
        env.__fireEvent("UPDATE_INVENTORY_DURABILITY")
        assert(addon:RunUpdateStatsSafe(), mode .. ": the HUD remains usable")
        local state = test.durabilityState()
        assert(not state.durabilityComplete and not state.repairCostComplete and state.repairCost == nil,
            mode .. ": an unreadable potentially durable slot must not publish partial gear totals")
    end
    local state = test.durabilityState()
    local initialReads = reads
    for _ = 1, state.retryLimit + 10 do
        if not test.durabilityState().durabilityRetryScheduled then break end
        assert(env.__flushNextTimer() and addon:RunUpdateStatsSafe(), "retry the new cached item")
    end
    state = test.durabilityState()
    assert(not state.durabilityRetryScheduled and state.durabilityRetryAttempt == state.retryLimit
        and reads == initialReads + state.retryLimit, "a newly observed cached item cannot retry without a bound")
    local exhaustedReads = reads
    env.__fireEvent("GET_ITEM_INFO_RECEIVED", 1017, true)
    assert(addon:RunUpdateStatsSafe() and exhaustedReads == reads, "a holdable item cannot wake the scan")
    available = true
    env.__fireEvent("GET_ITEM_INFO_RECEIVED", 2000, true)
    assert(addon:RunUpdateStatsSafe() and reads == exhaustedReads + 1, "the current item can wake one scan")
    state = test.durabilityState()
    assert(state.durabilityComplete and state.durabilityValue == 50 and state.repairCost == 400,
        "the full durability and exact repair cost exclude only empty and non-durable slots")
    if forever then
        equipped[pendingSlot], available = 2001, false
        env.__fireEvent("PLAYER_EQUIPMENT_CHANGED", pendingSlot, true)
        assert(addon:RunUpdateStatsSafe(), "a relic replacement renders safely")
        state = test.durabilityState()
        assert(state.durabilityComplete and state.durabilityValue == 80 and state.repairCost == 100,
            "a Forever relic is a non-durable item in the ranged slot")
    end
end
print(flavor .. " newly observed equipped item completeness regressions passed")

for _, history in ipairs({ "cold", "replacement", "repair-only" }) do
    local slot = forever and 18 or 16
    local id, identityReady, pairReady, priceReady = 1000, history ~= "cold", true, true
    local env, addon, test = loadStatsPro("enUS", {
        statsProDB = { showDurability = true, showRepairCost = true, useWorstDurability = false },
        getInventoryItemDurability = function(index)
            if index == 1 then return 80, 100 end
            if index == slot and pairReady then return 30, 100 end
        end,
        getTooltipInventoryItem = function(_, index)
            if index == 1 then return { repairCost = 100 } end
            if priceReady then return { repairCost = 300 } end
        end,
    })
    env.GetInventoryItemID = function(_, index)
        if index ~= slot then return end
        if not identityReady then error("equipment identity is unavailable") end
        return id
    end
    if history ~= "cold" then env.__fireEvent("PLAYER_ENTERING_WORLD") end
    id, identityReady, pairReady, priceReady = 2000, false, history == "repair-only", false
    if history == "cold" then
        env.__fireEvent("PLAYER_ENTERING_WORLD")
    else
        env.__fireEvent("PLAYER_EQUIPMENT_CHANGED", slot, true)
    end
    local retries = test.durabilityState().retryLimit
    for _ = 1, retries * 3 do
        assert(addon:RunUpdateStatsSafe())
        local state = test.durabilityState()
        if not (state.durabilityRetryScheduled or state.repairRetryScheduled) then break end
        assert(env.__flushNextTimer())
    end
    local state = test.durabilityState()
    assert(not state.dirty and not state.repairCostComplete
        and not state.durabilityRetryScheduled and not state.repairRetryScheduled)
    env.__fireEvent("ITEM_DATA_LOAD_RESULT", id, true)
    assert(not test.durabilityState().dirty, "event must not wake gear while its identity is still hidden")
    identityReady, pairReady, priceReady = true, true, true
    env.__fireEvent("GET_ITEM_INFO_RECEIVED", 1000, true)
    assert(not test.durabilityState().dirty, "old item identity cannot wake the newly readable slot")
    env.__fireEvent("ITEM_DATA_LOAD_RESULT", id, true)
    assert(test.durabilityState().dirty and addon:RunUpdateStatsSafe(),
        history .. ": matching late identity wakes the exhausted scan")
    state = test.durabilityState()
    assert(state.durabilityComplete and state.durabilityValue == 55 and state.repairCost == 400)
    env.__fireEvent("GET_ITEM_INFO_RECEIVED", id, true)
    assert(not test.durabilityState().dirty, "duplicate item events do not reopen the settled scan")
end
print(flavor .. " late equipment identity recovery passed")

do
    local firstSlot, secondSlot = 16, forever and 18 or 17
    local durable, scans = false, 0
    local equipped = { [firstSlot] = 1001, [secondSlot] = 1002 }
    local env, addon, test = loadStatsPro("enUS", {
        statsProDB = { showDurability = true, showRepairCost = true },
        getInventoryItemDurability = function(slot)
            if slot == firstSlot then scans = scans + 1 end
            if slot == 1 or (equipped[slot] and durable) then return 80, 100 end
        end,
        getTooltipInventoryItem = function() return { repairCost = 100 } end,
    })
    env.GetInventoryItemID = function(_, slot) return equipped[slot] end
    env.C_Item = { IsItemDataCachedByID = function() return false end }
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    local before = scans
    for i = 1, 25 do
        local event = i % 2 == 0 and "ITEM_DATA_LOAD_RESULT" or "GET_ITEM_INFO_RECEIVED"
        env.__fireEvent(event, 1001, true)
        assert(addon:RunUpdateStatsSafe(), "duplicate cold readiness is safe")
    end
    assert(scans == before + 1, "one cold slot cannot repeatedly restart the scan while metadata stays unavailable")
    env.__fireEvent("ITEM_DATA_LOAD_RESULT", 1002, true)
    assert(test.durabilityState().dirty and addon:RunUpdateStatsSafe(),
        "another cold equipped slot may still wake the scan")
    env.__fireEvent("ITEM_DATA_LOAD_RESULT", 1001, true)
    assert(not test.durabilityState().dirty, "the other cold slot's wakeup does not reset deduplication")
    env.__fireEvent("PLAYER_EQUIPMENT_CHANGED", firstSlot, true)
    assert(addon:RunUpdateStatsSafe(), "a real equipment event resets cold readiness")
    durable = true
    env.__fireEvent("ITEM_DATA_LOAD_RESULT", 1001, true)
    assert(test.durabilityState().dirty and addon:RunUpdateStatsSafe(), "current gear may wake the new generation")
    local state = test.durabilityState()
    assert(state.durabilityComplete and state.repairCostComplete and state.repairCost == 300,
        "a fresh bounded scan recovers the complete equipment totals")
end
print(flavor .. " cold equipped item readiness is bounded")

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

do
    local guid = "Player-PartialRealm"
    local name, realm = "Дима", nil
    local secretRealm = setmetatable({}, { __concat = function() error("restricted realm cannot enter a name") end })
    local env, addon, test = loadStatsPro("enUS", {
        unitGUID = function() return guid end,
        unitFullName = function() return name, realm end,
        unitClassToken = "MAGE",
        getSpecialization = function() return 1 end,
        specID = 64,
        issecretvalue = function(value) return rawequal(value, secretRealm) end,
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    local original = test.profileState()
    local nextProfileID = original.account.nextProfileID
    assert(original.profileID and original.characters[guid].displayName == "Дима",
        "an unqualified first reading still initializes the character")
    local function expectDisplay(expected)
        env.__fireEvent("UNIT_NAME_UPDATE", "player")
        env.__flushTimers(0)
        local current = test.profileState()
        assert(current.characters[guid].displayName == expected
            and addon.profileRuntime.activeDisplayName == expected)
        assert(current.profileID == original.profileID and current.settings == original.settings
            and current.account.nextProfileID == nextProfileID, "metadata updates retain the same profile")
    end
    realm = "Гордунни"
    expectDisplay("Дима-Гордунни")
    for _, partial in ipairs({ {}, { realm = "" }, { realm = secretRealm } }) do
        realm = partial.realm
        expectDisplay("Дима-Гордунни")
    end
    realm = "ДругойСервер"
    expectDisplay("Дима-ДругойСервер")
    name, realm = "НовоеИмя", nil
    expectDisplay("НовоеИмя")
    realm = "ДругойСервер"
    expectDisplay("НовоеИмя-ДругойСервер")
    print(flavor .. " qualified character metadata survives partial realm readings")
end

local function rejectArm(env, selectedDelay)
    local original = env.C_Timer.After
    local retired
    env.C_Timer.After = function(delay, callback)
        if delay == selectedDelay then
            if not retired then retired = callback end
            error("injected timer registration rejection")
        end
        return original(delay, callback)
    end
    return function()
        env.C_Timer.After = original
        return assert(retired, "the intended timer arm was rejected")
    end
end

local function advanceTicker(env, elapsed)
    for _, frame in ipairs(env.__frames) do
        if frame.scripts and frame.scripts.OnUpdate then
            frame.scripts.OnUpdate(frame, elapsed)
            return
        end
    end
    error("profile recovery needs the persistent ticker")
end

if not forever then
    do
        local env, addon, test = loadStatsPro("enUS", {
            unitGUID = function() return "Player-PositionRollback" end,
            specIndex = 1, specID = 64,
        })
        env.__fireEvent("PLAYER_ENTERING_WORLD")
        local original = addon.dbRuntime.GetActiveSettings()
        original.xOfs, original.yOfs = false, nil
        test.profileOps.setFailureStage("validate")
        local currentProfileID = test.profileState().profileID
        assert(currentProfileID, "the fixture has an active profile")
        assert(not test.profileOps.resetProfile(currentProfileID), "candidate validation rejects the reset")
        assert(rawequal(original, addon.dbRuntime.GetActiveSettings())
            and rawget(original, "xOfs") == false and rawget(original, "yOfs") == nil,
            "rollback preserves explicit false independently of an absent position field")
    end

    do
        local env, _, test = loadStatsPro("enUS", {
            unitGUID = function() return "Player-BootstrapNoSpec" end,
            getSpecialization = function() return nil end,
        })
        local restoreTimer = rejectArm(env, 0.1)
        env.__fireEvent("PLAYER_ENTERING_WORLD")
        local rejectedCallback = restoreTimer()
        rejectedCallback()
        advanceTicker(env, 0.05)
        assert(not env.StatsProFrame:IsShown(), "fallback waits for the usual no-spec settlement delay")
        advanceTicker(env, 0.05)
        assert(env.StatsProFrame:IsShown() and not test.profileRuntimeState().pendingResolution,
            "cold no-spec settlement recovers from a rejected timer without an additional event")
    end

    local function profileFixture()
        local identity = { spec = 64, index = 1, combat = false }
        local env, addon, test = loadStatsPro("enUS", {
            unitClassToken = "MAGE",
            unitGUID = function() return "Player-RetryTimerArm" end,
            inCombatLockdown = function() return identity.combat end,
            getSpecialization = function() return identity.index end,
            getSpecializationInfo = function()
                return identity.spec, "Mage", nil, nil, "DAMAGER", 4
            end,
        })
        env.__fireEvent("PLAYER_ENTERING_WORLD")
        assert(test.profileRuntimeState().activeSpecID == 64)
        return identity, env, addon.profileRuntime, test
    end

    do
        local identity, env, runtime, test = profileFixture()
        local restoreTimer = rejectArm(env, 0)
        identity.spec = 63
        env.__fireEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
        local rejectedCallback = restoreTimer()
        assert(runtime.pendingResolution and runtime.scheduledToken == nil,
            "failed registration leaves no phantom immediate callback")
        env.__fireEvent("UNIT_NAME_UPDATE", "player")
        rejectedCallback()
        advanceTicker(env, 0)
        assert(test.profileRuntimeState().activeSpecID == 64 and runtime.scheduledToken ~= nil,
            "an abandoned callback cannot consume the fresh request")
        env.__flushTimers(0)
        assert(test.profileRuntimeState().activeSpecID == 63 and not runtime.pendingResolution,
            "the next ordinary event resolves specialization without combat or reload")
    end

    do
        local identity, env, runtime, test = profileFixture()
        local restoreTimer = rejectArm(env, 0)
        identity.spec = 63
        env.__fireEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
        local rejectedCallback = restoreTimer()
        rejectedCallback()
        advanceTicker(env, 0)
        local state = test.profileRuntimeState()
        assert(state.activeSpecID == 63 and not runtime.pendingResolution and runtime.contextTickRetry == nil,
            "the next regular tick resolves a warm profile after the native arm was rejected")
        advanceTicker(env, 0.5)
        assert(test.profileRuntimeState().applyCount == state.applyCount,
            "the ticker fallback only applies the new profile once")
    end

    do
        local identity, env, runtime, test = profileFixture()
        local restoreTimer = rejectArm(env, 0)
        identity.spec, identity.combat = 63, true
        env.__fireEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
        restoreTimer()
        advanceTicker(env, 0.5)
        advanceTicker(env, 0.5)
        assert(test.profileRuntimeState().activeSpecID == 64 and runtime.pendingResolution
            and runtime.contextTickRetry == nil,
            "a rejected warm request spends its one fallback attempt and keeps combat lockdown")
        identity.combat = false
        env.__fireEvent("PLAYER_REGEN_ENABLED")
        assert(test.profileRuntimeState().activeSpecID == 63 and not runtime.pendingResolution,
            "the ordinary combat-end request recovers the profile")
    end

    do
        local identity, env, runtime, test = profileFixture()
        identity.index = nil
        local restoreTimer = rejectArm(env, 0.1)
        env.__fireEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
        env.__flushTimers(0)
        local rejectedCallback = restoreTimer()
        rejectedCallback()
        advanceTicker(env, 0.05)
        assert(test.profileRuntimeState().activeSpecID == 64 and runtime.pendingResolution,
            "warm no-spec fallback preserves the normal settlement delay")
        advanceTicker(env, 0.05)
        assert(test.profileRuntimeState().activeSpecID == nil and not runtime.pendingResolution
            and runtime.contextTickRetry == nil,
            "warm no-spec fallback settles without an unrelated event")
    end

    do
        local identity, env, runtime, test = profileFixture()
        identity.spec = nil
        local restoreTimer = rejectArm(env, 0.25)
        assert(not runtime.ResolveCurrent(false))
        local rejectedCallback = restoreTimer()
        assert(runtime.contextRetryToken == nil and runtime.contextRetryCount == 1,
            "rejected context retry spends one attempt without blocking another")
        assert(not runtime.ResolveCurrent(false) and runtime.contextRetryToken ~= nil
            and runtime.contextRetryCount == 2)
        rejectedCallback()
        identity.spec = 63
        env.__flushTimers(0.5)
        assert(test.profileRuntimeState().activeSpecID == 63 and not runtime.pendingResolution)
    end

    do
        local identity, env, runtime, test = profileFixture()
        identity.index = nil
        local restoreTimer = rejectArm(env, 0.1)
        assert(not runtime.ResolveCurrent(false))
        local rejectedCallback = restoreTimer()
        assert(runtime.noSpecRetryToken == nil)
        assert(not runtime.ResolveCurrent(false) and runtime.noSpecRetryToken ~= nil)
        rejectedCallback()
        assert(test.profileRuntimeState().activeSpecID == 64 and runtime.noSpecRetryToken ~= nil,
            "a replacement no-spec retry owns a different token in the same request generation")
        env.__flushTimers(0.1)
        assert(test.profileRuntimeState().activeSpecID == nil and not runtime.pendingResolution,
            "the accepted timer still settles the terminal no-spec fallback")
    end

    do
        local _, env, runtime, test = profileFixture()
        local restoreTimer = rejectArm(env, 0.25)
        local apply = runtime.applyActiveSettings
        runtime.applyActiveSettings = function() error("injected runtime apply failure") end
        runtime.forceReapply = true
        assert(not runtime.ResolveCurrent(false))
        local rejectedCallback = restoreTimer()
        assert(runtime.forceReapplyRetryToken == nil and runtime.forceReapplyRetryCount == 1)
        assert(not runtime.ResolveCurrent(false) and runtime.forceReapplyRetryToken ~= nil)
        rejectedCallback()
        advanceTicker(env, 0.25)
        assert(runtime.forceReapplyRetryCount == 2 and runtime.forceReapplyRetryToken ~= nil,
            "an accepted force retry supersedes the ticker attempt")
        runtime.applyActiveSettings = apply
        env.__flushTimers(0.5)
        assert(test.profileRuntimeState().activeSpecID == 64 and not runtime.forceReapply
            and not runtime.pendingResolution, "a rejected apply retry leaves the original profile recoverable")
    end
    do
        local _, env, runtime, test = profileFixture()
        local restoreTimer = rejectArm(env, 0.25)
        local apply = runtime.applyActiveSettings
        local attempts = 0
        runtime.applyActiveSettings = function()
            attempts = attempts + 1
            error("injected runtime apply failure")
        end
        runtime.forceReapply = true
        assert(not runtime.ResolveCurrent(false))
        local rejectedCallback = restoreTimer()
        rejectedCallback()
        advanceTicker(env, 0.125)
        assert(attempts == 1)
        runtime.applyActiveSettings = apply
        advanceTicker(env, 0.125)
        assert(test.profileRuntimeState().activeSpecID == 64 and not runtime.forceReapply
            and not runtime.pendingResolution and runtime.contextTickRetry == nil,
            "a regular tick recovers a rejected force retry on its original deadline")
    end
    do
        local _, env, runtime = profileFixture()
        local timer = env.C_Timer.After
        env.C_Timer.After = function() error("persistent arm failure") end
        runtime.forceReapply = true
        local attempts = 0
        runtime.applyActiveSettings = function()
            attempts = attempts + 1
            error("persistent runtime apply failure")
        end
        assert(not runtime.ResolveCurrent(false))
        for _, delay in ipairs({ 0.25, 0.5, 0.75, 1 }) do advanceTicker(env, delay) end
        env.C_Timer.After = timer
        assert(attempts == 4 and runtime.forceReapply and runtime.contextTickRetry == nil,
            "force retry remains bounded to three retries after the initial failure")
    end
    do
        local _, env, runtime, test = profileFixture()
        local state = test.profileState()
        local nextID = state.account.defaultProfileID
        assert(state.profileID ~= nextID)
        local applyCount = test.profileRuntimeState().applyCount
        state.characters[runtime.activeGUID].specProfiles[64] = nextID
        local restoreTimer = rejectArm(env, 0)
        test.profileViewModel()
        local rejectedCallback = restoreTimer()
        assert(runtime.bindingReconciliationPending and runtime.bindingReconciliationToken == nil
            and test.profileRuntimeState().applyCount == applyCount,
            "a rejected binding reconciliation retains the old applied payload")
        rejectedCallback()
        advanceTicker(env, 0)
        assert(test.profileState().profileID == nextID and not runtime.bindingReconciliationPending
            and test.profileRuntimeState().applyCount == applyCount + 1,
            "the ticker reconciles an externally changed assignment exactly once without another model read")
    end
    do
        local env, addon = loadStatsPro("enUS", { statsProDB = { dbVersion = 11, account = {} } })
        env.__fireEvent("PLAYER_ENTERING_WORLD")
        local root, runtime = env.StatsProDB, addon.profileRuntime
        assert(addon.dbRuntime.mode == "corrupt")
        runtime.forceReapply, runtime.pendingResolution = true, true
        runtime.corruptRollbackRoot = root
        local generation = runtime.requestGeneration
        local restoreTimer = rejectArm(env, 0.25)
        env.__fireEvent("PLAYER_REGEN_ENABLED")
        local rejectedCallback = restoreTimer()
        assert(runtime.corruptRollbackRetryToken == nil and runtime.corruptRollbackRetryCount == 0
            and runtime.corruptRollbackTickRetry and runtime.requestGeneration ~= generation,
            "the corrupt retry survives the ordinary combat-end context reset")
        rejectedCallback()
        advanceTicker(env, 0.125)
        assert(runtime.forceReapply)
        advanceTicker(env, 0.125)
        assert(not runtime.forceReapply and runtime.corruptRollbackRetryToken == nil
            and addon.dbRuntime.mode == "corrupt" and env.StatsProDB == root,
            "successful reapply keeps the original corrupt SavedVariables intact and read-only")
    end
    do
        local env, addon = loadStatsPro("enUS", { statsProDB = { dbVersion = 11, account = {} } })
        env.__fireEvent("PLAYER_ENTERING_WORLD")
        local root, runtime = env.StatsProDB, addon.profileRuntime
        runtime.forceReapply, runtime.pendingResolution = true, true
        local timer = env.C_Timer.After
        env.C_Timer.After = function() error("persistent arm failure") end
        local attempts = 0
        runtime.applyActiveSettings = function()
            attempts = attempts + 1
            error("persistent corrupt rollback apply failure")
        end
        assert(not runtime.ScheduleCorruptRollbackApply(root))
        for _, delay in ipairs({ 0.25, 0.5, 0.75, 1 }) do advanceTicker(env, delay) end
        env.C_Timer.After = timer
        assert(attempts == 3 and runtime.corruptRollbackRetryCount == 3
            and runtime.forceReapply and runtime.corruptRollbackTickRetry == nil and env.StatsProDB == root,
            "corrupt rollback remains bounded to the original three apply attempts")
    end
else
    local classReady, guidReady = false, true
    local env, addon, test = loadStatsPro("enUS", {
        unitGUID = function() if guidReady then return "Player-DeferredStarterArm" end end,
        foreverAPIs = { UnitClass = function()
            if classReady then return "Mage", "MAGE", 8 end
        end },
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    local before = test.profileState()
    local nextProfileID = before.root.account.nextProfileID
    addon:OpenConfigMenu()
    classReady = true
    env.__fireEvent("UNIT_NAME_UPDATE", "player")
    env.__flushTimers(0)
    local runtime = addon.profileRuntime
    local pending = assert(runtime.foreverPendingStarter)
    assert(pending.deferred and not before.settings.showSpellCrit)
    guidReady = false
    env.__fireEvent("UNIT_NAME_UPDATE", "player")
    env.__flushTimers(1)
    assert(runtime.pendingResolution and runtime.contextRetryCount == 3
        and not runtime.contextRetryToken and not runtime.contextTickRetry,
        "an exhausted context retains pending state without an in-flight callback")
    guidReady = true
    local restoreTimer = rejectArm(env, 0)
    env.StatsProConfigFrame:Hide()
    assert(pending.resumeScheduled and runtime.foreverStarterTickRetry)
    advanceTicker(env, 0)
    local rejectedCallback = restoreTimer()
    rejectedCallback()
    assert(not pending.resumeScheduled and not runtime.foreverStarterTickRetry
        and test.profileState().settings == before.settings,
        "the rejected close callback is inert after the single fallback dispatch")
    advanceTicker(env, 0)
    local updated = test.profileState()
    assert(updated.profileID == before.profileID and updated.settings.showSpellCrit
        and updated.root.account.nextProfileID == nextProfileID,
        "the deferred starter wakes on Settings close without allocating a duplicate profile")
end
print(flavor .. " rejected profile timer arm regressions passed")

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

    settings.showRating, rating = false, 250
    test.cacheSettings()
    local hiddenRating = expectRows(4, 2)
    for index = 1, 3 do
        assert(hiddenRating.targetRows[index].current == 250, "Archon reads a new clean rating while it is hidden")
    end
    settings.showRating, settings.showPercentage, rating = true, false, -1234
    test.cacheSettings()
    expectRows(4, 0)

    settings.showRating, settings.showPercentage, rating = false, true, 0
    test.cacheSettings()
    expectRows(4, 2)
    settings.showRating, settings.showPercentage, rating = true, false, -1234
    test.cacheSettings()
    expectRows(0, 0)

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
        local expected = entry.nameText and addon.sharedFonts.baseline.path or "Fonts\\ARIALN.TTF"
        assert(entry.actualFont == expected, "every Settings region gets its assigned font despite local override")
    end
    assert(test.applyConfigFont("Fonts\\2002.ttf", true), "subsequent Korean switch also updates direct regions")
    for _, entry in ipairs(test.configFontState().entries) do
        local expected = entry.nameText and addon.sharedFonts.baseline.path or "Fonts\\2002.ttf"
        assert(entry.actualFont == expected, "every Settings region gets its assigned font after switching to Korean")
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
            local expected = entry.nameText and addon.sharedFonts.baseline.path or path
            assert(entry.actualFont == expected, "all Settings regions receive their assigned font")
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

    local readyFormatter = env.AbbreviateNumbers
    local function replaceFormatter(formatter)
        env.AbbreviateNumbers = formatter
    end
    local blankCalibration, blankProbes = true, 0
    replaceFormatter(function(value, ...)
        if type(value) == "number" and blankCalibration then
            blankProbes = blankProbes + 1
            return ""
        end
        return readyFormatter(value, ...)
    end)
    assert(read(first) == fallbackFirst and blankProbes > 0,
        kind .. ": blank calibration safely uses the raw-unit fallback")
    local priorProbeCalls = probeCalls
    blankCalibration = false
    assert(read(second) == fallbackSecond and probeCalls == priorProbeCalls,
        kind .. ": recovered calibration waits until a normal retry event")
    cycleCombat()
    assert(read(second) == nativeSecond and probeCalls > priorProbeCalls,
        kind .. ": blank calibration does not permanently reject the same native formatter")

    local incompatibleProbes, unexpectedProtectedCalls = 0, 0
    local compatible = false
    replaceFormatter(function(value)
        if type(value) ~= "number" then
            unexpectedProtectedCalls = unexpectedProtectedCalls + 1
            return nativeFirst
        end
        incompatibleProbes = incompatibleProbes + 1
        if not compatible then return "1.0" end
        if kind == "Movement" then return value == 7 and "100%" or "150%" end
        return "10.25"
    end)
    assert(read(first) == fallbackFirst and incompatibleProbes > 0, kind .. ": clean mismatch fails closed")
    local provenMismatch = incompatibleProbes
    compatible = true
    cycleCombat()
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    assert(read(second) == fallbackSecond and incompatibleProbes == provenMismatch and unexpectedProtectedCalls == 0,
        kind .. ": a proven mismatch remains cached across recovery events")
    print(flavor .. " " .. kind .. " protected formatter recovery regressions passed")
end

-- Native formatting failure must preserve each row's unknown-value unit.
do
    local secretSpeed, speed, combat = {}, 7, false
    local function getUnitSpeed() return 0, speed, 0, 0 end
    local function getParryChance() return combat and secretSpeed or 5 end
    local env, _, test = loadStatsPro("enUS", {
        inCombatLockdown = function() return combat end,
        issecretvalue = function(value) return rawequal(value, secretSpeed) end,
        getUnitSpeed = getUnitSpeed,
        getParryChance = getParryChance,
        foreverAPIs = { GetUnitSpeed = getUnitSpeed, GetParryChance = getParryChance },
        abbreviateNumbers = function() error("abbreviation rejected") end,
        setFormattedText = function() error("native format rejected") end,
        roundToNearestString = function() error("native rounding rejected") end,
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    local settings = test.profileState().settings
    settings.showTertiary, settings.showPercentage, settings.showRating = true, true, false
    settings.showSpeed, settings.showMovementSpeed, settings.hideZeroTertiary = true, true, true
    settings.showDefensive, settings.showParry, settings.hideZeroDefensive = true, true, true
    test.cacheSettings()
    local function displayedStat(section, name)
        for _, block in ipairs(test.buildRenderBlocks()) do
            if block.splitKey == section then
                for index, label in ipairs(block.labels) do
                    if label:find(name, 1, true) then return block.ratings[index] .. block.values[index] end
                end
            end
        end
        return ""
    end
    assert(displayedStat("splitTertiary", "Movement"):find(forever and "100%" or "100.0%", 1, true),
        "movement has a clean percentage before combat")
    assert(displayedStat("splitDefensive", "Parry"):find(forever and "5.00%" or "5.0%", 1, true),
        "parry has a clean percentage before combat")
    speed, combat = secretSpeed, true
    env.__fireEvent("PLAYER_REGEN_DISABLED")
    assert(displayedStat("splitTertiary", "Movement"):find("?%", 1, true),
        flavor .. ": protected movement formatting failure preserves the percentage placeholder")
    assert(displayedStat("splitDefensive", "Parry"):find("?%", 1, true),
        flavor .. ": protected parry formatting failure preserves the percentage placeholder")
end

-- A failed hidden FontString stays retired. The next combat gets one fresh
-- holder, and repeated native failures stay bounded for the session.
do
    local combat, reject = false, false
    local secretA, secretB = {}, {}
    local parry = 5
    local holderCalls = {}
    local function getParryChance() return parry end
    local env, addon, test = loadStatsPro("enUS", {
        inCombatLockdown = function() return combat end,
        issecretvalue = function(value) return rawequal(value, secretA) or rawequal(value, secretB) end,
        getParryChance = getParryChance,
        foreverAPIs = { GetParryChance = getParryChance },
        setFormattedText = function(holder, _, value)
            holderCalls[#holderCalls + 1] = holder
            if reject then error("native formatter rejected") end
            return rawequal(value, secretA) and "17.2%" or "23.9%"
        end,
        roundToNearestString = function(value) return rawequal(value, secretA) and "17" or "24" end,
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    local settings = test.profileState().settings
    settings.showDefensive, settings.showParry, settings.hideZeroDefensive = true, true, true
    test.cacheSettings()
    local function parryText()
        for _, block in ipairs(test.buildRenderBlocks()) do
            if block.splitKey == "splitDefensive" then
                for index, label in ipairs(block.labels) do
                    if label:find("Parry", 1, true) then return block.ratings[index] .. block.values[index] end
                end
            end
        end
        return ""
    end
    local function enter(value)
        combat, parry = true, value
        env.__fireEvent("PLAYER_REGEN_DISABLED")
    end
    local function leave()
        combat, parry = false, 5
        env.__fireEvent("PLAYER_REGEN_ENABLED")
    end
    assert(parryText():find("5.", 1, true), "clean Parry first seeds Hide Zero")
    reject = true
    enter(secretA)
    assert(parryText():find("17%", 1, true) and #holderCalls == 1, "native failure uses integer fallback")
    leave()
    reject = false
    enter(secretB)
    assert(parryText():find("23.9%", 1, true) and #holderCalls == 2 and holderCalls[1] ~= holderCalls[2],
        "next combat restores precision on a fresh native formatter")
    reject = true
    assert(parryText():find("24%", 1, true) and #holderCalls == 3, "failed replacement also falls back")
    leave()
    reject = false
    enter(secretA)
    assert(parryText():find("17%", 1, true) and #holderCalls == 3,
        "later combat cannot allocate unbounded replacement holders")
    assert(addon:RunUpdateStatsSafe(), "failed native formatters cannot abort the HUD update")
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

do
    local path = "Interface\\AddOns\\SharedMedia_MyMedia\\fonts\\SavedFontTimerFixture.ttf"
    local ready = false
    local function canApply(_, font) return font ~= path or ready end
    local env, addon, test = loadStatsPro("enUS", {
        statsProDB = { font = path },
        lsmFonts = { { name = "Saved font timer fixture", path = path } },
        setFontResult = canApply,
        fontObjectSetFontResult = canApply,
    })
    local restoreTimer = rejectArm(env, 0.2)
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    local lateCallback = restoreTimer()
    assert(addon.sharedFonts.noticeInitialized and test.fontRuntimeState().pendingRetryScheduled,
        "rejecting a saved-font timer must not abort bootstrap")
    advanceTicker(env, 0.1)
    assert(test.fontRuntimeState().pendingRetryAttempt == 1)
    advanceTicker(env, 0.1)
    assert(test.fontRuntimeState().pendingRetryAttempt == 2,
        "the ticker consumes the rejected attempt and schedules the next retry")
    ready = true
    lateCallback()
    assert(test.currentRuntimeFontPath() ~= path, "a late duplicate cannot apply the font ahead of the next timer")
    env.__flushTimers(1)
    assert(test.currentRuntimeFontPath() == path and test.profileState().settings.font == path
        and not test.fontRuntimeState().pendingRetryScheduled,
        "the pending preference recovers with no saved selection changes")
end

do
    local ready = false
    local function canApply(_, path, size)
        return ready or size ~= 12 or not path:find("AntraktUISans.ttf", 1, true)
    end
    local env, addon = loadStatsPro("enUS", {
        lsmFonts = {},
        unitGUID = function() return "Player-1-COLD-NAME-RETRY" end,
        unitFullName = function() return "Охотник", "Сервер" end,
        getSpecialization = function() return 1 end,
        specID = 73,
        setFontResult = canApply,
        fontObjectSetFontResult = canApply,
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    addon:OpenConfigMenu()
    local header = env.StatsProActiveProfileButton.statsProText
    local fallback, text = header:GetFont(), header:GetText()
    local baseline = addon.sharedFonts.baseline.path
    assert(fallback ~= baseline and addon:RunUpdateStatsSafe())
    env.__flushTimers(0)
    local restoreTimer = rejectArm(env, 0.2)
    assert(addon:RunUpdateStatsSafe(), "rejecting a name-font timer must not abort the HUD")
    local lateCallback = restoreTimer()
    ready = true
    advanceTicker(env, 0.1)
    assert(header:GetFont() == fallback)
    advanceTicker(env, 0.1)
    assert(addon:RunUpdateStatsSafe() and header:GetFont() == baseline and header:GetText() == text,
        "the rejected retry restores the original name with the bundled glyphs")
    lateCallback()
    assert(not addon.fontRuntime.catalogLocaleDirty, "a late duplicate cannot reopen reconciliation")
end

do
    local env, addon, test = loadStatsPro("enUS", {
        statsProDB = {},
        testWelcomeEnabled = true,
        unitGUID = function() return "Player-1-WELCOME-RETRY" end,
        getSpecialization = function() return 1 end,
        specID = 73,
    })
    local restoreTimer = rejectArm(env, 0.5)
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    local lateCallback = restoreTimer()
    assert(addon.sharedFonts.noticeInitialized and not test.hudPresets.state().welcomeShown,
        "rejecting the welcome timer must not abort the next bootstrap step")
    advanceTicker(env, 0.25)
    assert(not test.hudPresets.state().welcomeShown)
    advanceTicker(env, 0.25)
    assert(test.hudPresets.state().welcomeShown, "the welcome remains deferred until the first safe attempt")
    env.StatsProQuickSetupWelcome:Hide()
    lateCallback()
    assert(not test.hudPresets.state().welcomeShown, "the retired welcome callback is harmless")
end
print(flavor .. " rejected font and welcome timers recover through the HUD ticker")

do
    local env, addon = loadStatsPro("enUS", {})
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    assert(addon:OpenConfigMenu() ~= false)
    local picker = addon.settingsUI.fontPicker
    picker.Show(addon)
    local function countSettingsFrames()
        local count = 0
        for _, frame in ipairs(env.UISpecialFrames) do
            if frame == "StatsProConfigFrame" then count = count + 1 end
        end
        return count
    end
    local restoreTimer = rejectArm(env, 0)
    picker.Hide(addon)
    local lateCallback = restoreTimer()
    assert(env.StatsProConfigFrame:IsShown() and countSettingsFrames() == 0,
        "closing the picker during Escape must not synchronously register its parent")
    advanceTicker(env, 0)
    assert(countSettingsFrames() == 1, "a rejected timer still allows Escape to close Settings on the next frame")
    picker.Show(addon)
    lateCallback()
    assert(picker.frame:IsShown() and countSettingsFrames() == 0,
        "the retired callback does not claim Escape from a reopened picker")
    restoreTimer = rejectArm(env, 0)
    picker.Hide(addon)
    restoreTimer()
    picker.Show(addon)
    advanceTicker(env, 0)
    assert(countSettingsFrames() == 0, "a deferred restore cannot supersede a reopened child")
end
print(flavor .. " rejected Escape handoff timer recovery passed")

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
    local ticker
    for _, frame in ipairs(env.__frames) do
        if frame.scripts and frame.scripts.OnUpdate then
            ticker = frame
            break
        end
    end
    assert(ticker, "expected the normal HUD OnUpdate ticker")
    env.__flushTimers(0)
    ticker.scripts.OnUpdate(ticker, 0.11)
    value, state = addon.GetBestCritChance()
    assert(value == -9 and state == "liveProxy", "a late same-spec confirmation resumes the old fallback")

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
    env.__flushTimers(0)
    assert(addon:RunUpdateStatsSafe())
    value, state = addon.GetBestCritChance()
    assert(value == nil and state == "restricted",
        "a former ID after an unreadable event sample must wait for confirmation")
    ticker.scripts.OnUpdate(ticker, 0.11)
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

    env.__flushTimers(0)
    restricted = false
    ratingReady = true
    assert(addon:RunUpdateStatsSafe() and test.versatilityState().total == 12)
    -- The event can precede the specialization API's update. An immediate
    -- read still reports the old clean ID, while deferred profile resolution
    -- sees the new ID once the client state settles.
    env.__fireEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
    spec = 63
    restricted = true
    ratingReady = false
    assert(addon:RunUpdateStatsSafe())
    value, state = addon.GetBestCritChance()
    assert(value == nil and state == "restricted" and #test.buildRenderBlocks()[2].labels == 0,
        "a same-ID event sample cannot authorize old fallbacks before the deferred check")
    env.__flushTimers(0)
    assert(test.profileRuntimeState().activeSpecID == 63 and addon:RunUpdateStatsSafe())
    value, state = addon.GetBestCritChance()
    assert(value == nil and state == "restricted" and test.versatilityState().total == nil,
        "the deferred read clears old fallback samples when the client publishes a new ID")

    restricted = false
    ratingReady = true
    assert(addon:RunUpdateStatsSafe() and test.versatilityState().total == 11)
    env.__fireEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
    assert(env.__flushTimers(0) == 1, "the event uses the existing zero-delay profile timer only")
    assert(test.profileRuntimeState().activeSpecID == 63, "profile resolution can still observe the old ID")
    ticker.scripts.OnUpdate(ticker, 0.05)
    spec = 62
    restricted = true
    ratingReady = false
    assert(addon:RunUpdateStatsSafe())
    value, state = addon.GetBestCritChance()
    assert(value == nil and state == "restricted", "the old fallback is held while the late confirmation is pending")
    ticker.scripts.OnUpdate(ticker, 0.06)
    assert(addon:RunUpdateStatsSafe())
    value, state = addon.GetBestCritChance()
    assert(value == nil and state == "restricted" and test.versatilityState().total == nil,
        "a spec change after the zero-delay queue still invalidates the old stat caches")
    env.__flushTimers(0)
    assert(test.profileRuntimeState().activeSpecID == 62,
        "the same late confirmation refreshes the active profile context")

    restricted, ratingReady = false, true
    assert(addon:RunUpdateStatsSafe() and test.versatilityState().total == 12)
    env.__fireEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(0)
    specReady = false
    ticker.scripts.OnUpdate(ticker, 0.11)
    assert(test.profileRuntimeState().activeSpecID == 62)
    spec, specReady, restricted, ratingReady = 63, true, true, false
    assert(addon:RunUpdateStatsSafe())
    env.__flushTimers(0)
    assert(test.profileRuntimeState().activeSpecID == 63 and test.versatilityState().total == nil,
        "a render that first sees the new ID updates the profile after an unreadable recheck")

    specReady = false
    env.__fireEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__flushTimers(1)
    local exhausted = test.profileRuntimeState()
    assert(exhausted.pendingResolution and exhausted.contextRetryCount == 3
        and not exhausted.contextRetryScheduled, "the unreadable context exhausts its bounded retries")
    spec, specReady = 62, true
    ticker.scripts.OnUpdate(ticker, 0.11)
    env.__flushTimers(0)
    assert(test.profileRuntimeState().activeSpecID == 62 and not test.profileRuntimeState().pendingResolution,
        "a newly readable identity resumes exhausted profile resolution")
    print("Retail spec-scoped restricted stat recovery regressions passed")
end

if not forever then
    for _, case in ipairs({
        { "enUS", "full", 1, "Melee Crit:", "19.0%" },
        { "ruRU", "full", 2, "Крит дальнего боя:", "19.0%" },
        { "enUS", "full", 3, "Spell Crit:", "19.0%" },
        { "enUS", "short", 3, "C:", "[19.0%]" },
        { "enUS", "hidden", 3, "", "[19.0%]" },
    }) do
        local restricted, livePercent = false, 19
        local function crit(index)
            return restricted and -71 or (case[3] == index and 31 or 9)
        end
        local env, addon, test = loadStatsPro(case[1], {
            unitClassToken = "MAGE", specIndex = 1, specID = 64,
            statsProDB = {
                labelStyle = case[2], showOffensive = true, showCrit = true, showHaste = false,
                showMastery = false, showVersatility = false, showRating = true,
                showPercentage = true, hideZeroOffensive = true,
                showMainStat = false, showStamina = false, showDefensive = false,
                showTertiary = false, showDurability = false, showRepairCost = false, showItemLevel = false,
            },
            getCritChance = function() return crit(1) end,
            getRangedCritChance = function() return crit(2) end,
            getSpellCritChance = function() return crit(3) end,
            getCombatRating = function() return 420 end,
            issecretvalue = function(value) return value == -71 end,
            setFormattedText = function(_, _, value)
                assert(value == -71)
                return string.format("%.1f%%", livePercent)
            end,
        })
        env.__fireEvent("PLAYER_ENTERING_WORLD")
        local clean = test.buildRenderBlocks()[2]
        assert(#clean.labels == 1 and clean.values[1]:find("31.0%", 1, true))
        local cleanGeometry = test.panelVisualState()
        restricted = true
        for _, probe in ipairs({ { 19, case[5] }, { 33, case[5]:gsub("19", "33") } }) do
            livePercent = probe[1]
            assert(addon:RunUpdateStatsSafe())
            local geometry = test.panelVisualState()
            local current = test.buildRenderBlocks()[2]
            local label = current.labels[1]:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
            assert(#current.labels == 1 and label == case[4], "the same Crit row exposes the active source")
            assert(current.ratings[1] == clean.ratings[1] and current.values[1]:find(probe[2], 1, true),
                "the sourced percentage stays live and in its own column")
            assert(geometry.mainFrameHeight == cleanGeometry.mainFrameHeight
                and geometry.mainLastLineH == cleanGeometry.mainLastLineH
                and geometry.mainValuePoints[1][5] == cleanGeometry.mainValuePoints[1][5],
                "source notation does not move the value vertically or allocate a row")
            if case[2] == "hidden" then
                assert(geometry.mainRenderedLabelW == 0, "hidden labels allocate no width for the Crit source")
            end
        end
        if case[3] == 1 then
            env.__fireEvent("PLAYER_EQUIPMENT_CHANGED")
            local swapped = test.buildRenderBlocks()[2]
            assert(swapped.labels[1]:find("Crit:", 1, true)
                and not swapped.labels[1]:find("Melee Crit:", 1, true)
                and not swapped.values[1]:find("33.0%", 1, true),
                "an equipment change retires the previous winning Crit source")
        end
    end
    print("Retail localized Crit source rendering regressions passed")
end

if not forever then
    local spec, rating, haste = 64, 1200, 13
    local armor, combat = 2500, false
    local versMode = "clean"
    local armorReads = 0
    local env, addon, test = loadStatsPro("enUS", {
        unitClassToken = "MAGE", specIndex = 1,
        getSpecializationInfo = function() if spec then return spec, "Mage", nil, nil, "DAMAGER", 4 end end,
        statsProArchonTargets = archonTargetsFixture(),
        statsProDB = {
            showCrit = false, showVersatility = true, showHaste = true, showMastery = false,
            showOffensive = true, showRating = true, showPercentage = true, hideZeroOffensive = true,
            showDefensive = true, showArmor = true, showDodge = false, showParry = false,
            showBlock = false, showStagger = false, hideZeroDefensive = true,
        },
        getCombatRating = function() return rating end,
        getHaste = function() return haste end,
        getCombatRatingBonus = function()
            if versMode == "nil" then return end
            if versMode == "failed" then error("the rating bonus is not ready") end
            return versMode == "clean" and 10 or -9
        end,
        getVersatilityBonus = function()
            if versMode == "nil" then return end
            return versMode == "live" and 0 or 2
        end,
        unitArmor = function()
            armorReads = armorReads + 1
            return 0, armor
        end,
        unitEffectiveLevel = function() return 80 end,
        paperDollFrameGetArmorReduction = function(effectiveArmor) return effectiveArmor / 100 end,
        inCombatLockdown = function() return combat end,
        issecretvalue = function(value) return value == -9 end,
        setFormattedText = function(_, _, value)
            assert(value == -9)
            return "18.0%"
        end,
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    assert(test.profileOps.enableAccountWide(test.profileState().profileID))
    assert(addon:RunUpdateStatsSafe())
    local blocks = test.buildRenderBlocks()
    local priorMeta = blocks[2].targetRows[1]
    assert(priorMeta and priorMeta.comparisonState == "exact")
    assert(addon.archonTargets.ShowTooltip(env.UIParent, priorMeta))
    assert(blocks[4].values[1]:find("25.0%", 1, true) and not blocks[4].values[1]:find("(", 1, true))
    versMode, rating, combat = "partial", nil, true
    local priorArmorReads = armorReads
    armor = 1100
    assert(addon:RunUpdateStatsSafe())
    blocks = test.buildRenderBlocks()
    assert(blocks[2].ratings[2]:find("(1200)", 1, true) and blocks[2].values[2]:find("(12.0%)", 1, true),
        "each reused Versatility cell carries last-known provenance")
    assert(blocks[4].values[1]:find("(25.0%)", 1, true) and armorReads == priorArmorReads,
        "combat does not read Armor and makes its held amount explicit")
    assert(blocks[2].targetRows[1].comparisonState == "lastKnown")

    local settings = test.profileState().settings
    settings.showPercentage = false
    test.cacheSettings()
    local ratingOnly = test.buildRenderBlocks()[2]
    assert(#ratingOnly.labels == 1 and ratingOnly.ratings[1]:find("(1200)", 1, true),
        "rating-only Hide Zero retains a previous nonzero Versatility read for the same gear")
    env.__fireEvent("PLAYER_EQUIPMENT_CHANGED")
    assert(#test.buildRenderBlocks()[2].labels == 0, "rating-only fallback cannot cross an equipment change")
    assert(not test.getArchonTooltip():IsShown() and not addon.archonTargets.ShowTooltip(env.UIParent, priorMeta),
        "gear swaps close and retire a previously rendered comparison")
    settings.showPercentage = true
    test.cacheSettings()
    assert(test.buildRenderBlocks()[2].targetRows[1].comparisonState == "targetOnly",
        "an unavailable post-swap rating does not reuse a comparison from previous gear")
    versMode = "clean"
    assert(test.buildRenderBlocks()[2].values[2]:find("12.0%", 1, true))
    versMode = "live"
    assert(test.buildRenderBlocks()[2].values[2]:find("18.0%", 1, true)
        and not test.buildRenderBlocks()[2].values[2]:find("(", 1, true),
        "a restricted Versatility component is still live when the other component is exact zero")

    settings.showRating, settings.showHaste, settings.hideZeroOffensive = false, false, false
    test.cacheSettings()
    versMode = "nil"
    local unavailable = test.buildRenderBlocks()[2]
    assert(#unavailable.labels == 1 and unavailable.ratings[1]:find("(12.0%)", 1, true),
        "temporarily unavailable Versatility retains the last confirmed percentage for the same gear")
    env.__fireEvent("PLAYER_EQUIPMENT_CHANGED")
    for _, outcome in ipairs({ "nil", "failed", "partial" }) do
        versMode = outcome
        unavailable = test.buildRenderBlocks()[2]
        assert(#unavailable.labels == 1 and unavailable.ratings[1]:find("?%", 1, true),
            outcome .. " Versatility keeps its enabled percentage row with no confirmed sample")
    end
    settings.hideZeroOffensive = true
    test.cacheSettings()
    assert(#test.buildRenderBlocks()[2].labels == 0,
        "cold unknown Versatility is hidden when Hide Zero is enabled")
    settings.showRating, settings.showHaste, versMode = true, true, "live"
    test.cacheSettings()

    rating = 100
    test.buildRenderBlocks()
    settings.showRating, rating = false, 0
    test.cacheSettings()
    test.buildRenderBlocks()
    settings.showRating, settings.showPercentage, rating = true, false, nil
    test.cacheSettings()
    assert(#test.buildRenderBlocks()[2].labels == 0,
        "a newer zero sample received while the rating column is hidden supersedes its old nonzero decision")
    settings.showRating, settings.showPercentage, rating = false, true, 670
    test.cacheSettings()
    test.buildRenderBlocks()
    settings.showRating, settings.showPercentage, rating = true, false, nil
    test.cacheSettings()
    local newlyVisible = test.buildRenderBlocks()[2]
    assert(#newlyVisible.labels == 1 and newlyVisible.ratings[1]:find("(670)", 1, true),
        "a recent nonzero rating sample stays eligible when its column becomes visible")
    settings.showPercentage = true
    test.cacheSettings()

    combat, armor = false, nil
    assert(addon:RunUpdateStatsSafe())
    assert(test.buildRenderBlocks()[4].values[1]:find("(25.0%)", 1, true),
        "leaving combat does not imply that an inaccessible Armor sample is fresh")
    armor = 1100
    assert(addon:RunUpdateStatsSafe())
    local currentArmor = test.buildRenderBlocks()[4].values[1]
    assert(currentArmor:find("11.0%", 1, true) and not currentArmor:find("(", 1, true))
    armor = 0
    assert(addon:RunUpdateStatsSafe() and #test.buildRenderBlocks()[4].labels == 0)
    combat = true
    assert(addon:RunUpdateStatsSafe() and #test.buildRenderBlocks()[4].labels == 0,
        "an explicitly stale zero continues to obey defensive Hide Zero")
    settings.hideZeroDefensive = false
    test.cacheSettings()
    assert(test.buildRenderBlocks()[4].values[1]:find("(0.0%)", 1, true),
        "the retained zero is visible as stale when defensive Hide Zero is disabled")
    combat, settings.hideZeroDefensive = false, true
    test.cacheSettings()

    spec, haste = nil, -9
    env.__fireEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    env.__fireEvent("PLAYER_EQUIPMENT_CHANGED")
    assert(addon:RunUpdateStatsSafe() and #test.buildRenderBlocks()[2].labels == 0,
        "pending identity does not borrow a Haste or Versatility Hide Zero decision")
    spec = 63
    env.__flushTimers(0)
    for _, frame in ipairs(env.__frames) do
        if frame.scripts and frame.scripts.OnUpdate then
            frame.scripts.OnUpdate(frame, 0.11)
            break
        end
    end
    assert(addon.critRuntime.specID == 63 and not addon.critRuntime.specIdentityDirty)
    assert(addon:RunUpdateStatsSafe() and #test.buildRenderBlocks()[2].labels == 0,
        "newly confirmed spec cannot reuse the old Haste decision")
    haste = 22
    test.buildRenderBlocks()
    haste = -9
    local resumed = test.buildRenderBlocks()[2]
    assert(#resumed.labels == 1 and resumed.values[1]:find("18.0%", 1, true),
        "new context resumes direct protected Haste after a fresh Hide Zero decision")
    print("Retail provenance, context and gear comparison regressions passed")
end

if not forever then
    local spec, armor = 64, 2500
    local env, addon, test = loadStatsPro("enUS", {
        unitClassToken = "MAGE", specIndex = 1,
        getSpecializationInfo = function() if spec then return spec, "Mage", nil, nil, "DAMAGER", 4 end end,
        statsProDB = {
            showDefensive = true, showArmor = true, showDodge = false, showParry = false,
            showBlock = false, showStagger = false, hideZeroDefensive = true,
        },
        unitArmor = function() return 0, armor end,
        unitEffectiveLevel = function() return 80 end,
        paperDollFrameGetArmorReduction = function(effectiveArmor) return effectiveArmor / 100 end,
    })
    local function armorValue()
        assert(addon:RunUpdateStatsSafe())
        return test.buildRenderBlocks()[4].values[1]
    end
    local function settleSpec(specID)
        spec = specID
        env.__flushTimers(0)
        for _, frame in ipairs(env.__frames) do
            if frame.scripts and frame.scripts.OnUpdate then
                frame.scripts.OnUpdate(frame, 0.11)
                break
            end
        end
        assert(addon.critRuntime.specID == specID and not addon.critRuntime.specIdentityDirty)
    end
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    assert(test.profileOps.enableAccountWide(test.profileState().profileID))
    assert(armorValue():find("25.0%", 1, true))

    spec, armor = nil, 7700
    env.__fireEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
    assert(addon.critRuntime.specIdentityDirty)
    local pending = armorValue()
    assert(pending:find("77.0%", 1, true) and not pending:find("(", 1, true),
        "Armor still displays a current reading while specialization is pending")
    armor = nil
    assert(armorValue() == nil, "an unresolved specialization cannot display stored Armor")
    settleSpec(64)
    assert(armorValue():find("(25.0%)", 1, true),
        "resolving the original spec preserves its own last clean reading instead of the pending sample")

    spec, armor = nil, 8800
    env.__fireEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
    assert(armorValue():find("88.0%", 1, true))
    armor = nil
    settleSpec(63)
    assert(armorValue() == nil, "the new specialization cannot reuse either old or pending Armor")
    armor = 3400
    assert(armorValue():find("34.0%", 1, true))
    armor = nil
    assert(armorValue():find("(34.0%)", 1, true), "the confirmed new spec stores its own clean reading")
    print("Retail Armor fallback isolates unresolved specialization readings")
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
    local phase = "clean"
    local protectedCoefficient, protectedEffect = {}, {}
    local env, addon, test = loadStatsPro("enUS", {
        unitClassToken = "MAGE", specIndex = 1, specID = 64,
        statsProArchonTargets = archonTargetsFixture(),
        statsProDB = {
            showOffensive = true, showCrit = false, showHaste = false,
            showMastery = true, showVersatility = false, matchValueColorToStat = false,
        },
        getCombatRating = function()
            if phase == "clean" then return 800 end
            if phase == "mixed" then return 850 end
            if phase == "restricted" then return 875 end
        end,
        getMasteryEffect = function()
            if phase == "clean" then return 26, 2 end
            if phase == "restricted" then return protectedEffect, protectedCoefficient end
            return 41, protectedCoefficient
        end,
        getCombatRatingBonusForCombatRatingValue = function(_, value) return value / 100 end,
        issecretvalue = function(value) return rawequal(value, protectedCoefficient) or rawequal(value, protectedEffect) end,
        setFormattedText = function(_, _, value)
            assert(rawequal(value, protectedEffect), "only the protected effect reaches the client formatter")
            return "55.0%"
        end,
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    local function tooltipRows()
        local meta = test.buildRenderBlocks()[2].targetRows[1]
        assert(addon.archonTargets.ShowTooltip(env.UIParent, meta))
        local rows = {}
        for _, row in ipairs(test.getArchonTooltip().lines) do rows[row.left] = row.right end
        return rows, meta
    end
    local cleanRows = tooltipRows()
    assert(cleanRows["Target:"] == "1000 (~30.0%)")

    phase = "mixed"
    local mixedRows, mixed = tooltipRows()
    assert(mixed.comparisonState == "exact" and mixedRows["Current:"] == "850 (~41.0%)"
        and mixedRows["Target:"] == "1000" and mixedRows["Missing:"] == "150",
        "an exact live rating cannot mix its clean percentage with an older Mastery target")

    phase = "restricted"
    local restrictedRows, restricted = tooltipRows()
    assert(restricted.comparisonState == "exact" and restrictedRows["Current:"] == "875 (~55.0%)"
        and restrictedRows["Target:"] == "1000 (~30.0%)" and restrictedRows["Missing:"] == "125",
        "a restricted effect remains live while only its clean rating participates in the comparison")

    phase = "unavailable"
    local cachedRows, lastKnown = tooltipRows()
    assert(lastKnown.comparisonState == "lastKnown"
        and cachedRows["Target:"] == "1000 (~30.0%)" and cachedRows["Current:"] == "800 (~26.0%)"
        and cachedRows["Missing:"] == "200 (~+4.0%)",
        "a partial Mastery sample does not overwrite the coherent last-known comparison")
    print("Retail Archon mixed Mastery percentage regressions passed")
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

do
    local secret = {}
    local unavailable, durability, overall, equipped = true, 20, 115, 90
    local function readAverageItemLevel()
        if unavailable then return overall, secret end
        return overall, equipped
    end
    local env, addon, test = loadStatsPro("enUS", {
        statsProDB = {
            showMainStat = false, showStamina = false, showOffensive = false,
            showDefensive = false, showTertiary = false, showRepairCost = false,
            showItemLevel = true, showDurability = true, useAutoColorDurability = true,
            showRating = true, showPercentage = true,
        },
        getInventoryItemDurability = function(slot)
            if slot ~= 1 then return end
            if unavailable then return secret, secret end
            return durability, 100
        end,
        getAverageItemLevel = readAverageItemLevel,
        foreverAPIs = { GetAverageItemLevel = readAverageItemLevel },
        issecretvalue = function(value) return rawequal(value, secret) end,
    })
    local function getRow(key)
        for _, block in ipairs(test.buildRenderBlocks()) do
            if block.splitKey == key then
                return block.ratings[1], block.values[1]
            end
        end
        error("missing render block " .. key)
    end
    local function plain(text)
        return (text:gsub("|cff%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("||", "|"))
    end
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    assert(getRow("splitItemLevel") == nil, "cold partial item level cannot seed a pair")
    local coldRating, coldValue = getRow("splitDurability")
    assert(coldRating == "" and coldValue == "—", "cold unreadable durability shows a neutral dash")
    unavailable = false
    env.__fireEvent("PLAYER_EQUIPMENT_CHANGED", 1, true)
    assert(addon:RunUpdateStatsSafe())
    local rating, value = getRow("splitItemLevel")
    local equippedCell = forever and value or rating
    assert(equippedCell:find("|cffff3333", 1, true)
        and plain(value) == (forever and "90|115" or "115"),
        "a current item-level gap triggers the warning")
    _, value = getRow("splitDurability")
    assert(plain(value) == "20.0%", "current durability renders without a stale marker")
    local lastGoodDurability = value

    unavailable = true
    env.__fireEvent("AUCTION_HOUSE_SHOW")
    env.__fireEvent("PLAYER_EQUIPMENT_CHANGED", 1, true)
    assert(addon:RunUpdateStatsSafe())
    rating, value = getRow("splitItemLevel")
    equippedCell = forever and value or rating
    assert(not equippedCell:find("|cffff3333", 1, true)
        and plain(equippedCell):find(forever and "90|" or "(90)", 1, true)
        and plain(value) == (forever and "90|115" or "(115)"),
        "an incomplete item-level read keeps both previous values without an alert")
    _, value = getRow("splitDurability")
    assert(forever and value == lastGoodDurability or not forever and plain(value) == "(20.0%)",
        "an incomplete scan keeps the previous durability number and Forever color")

    local settings = test.profileState().settings
    settings.labelStyle, settings.showRating = "hidden", false
    test.cacheSettings()
    rating, value = getRow("splitItemLevel")
    assert(plain(rating) == (forever and "90|115" or "(90)|(115)") and value == "",
        "a stale item-level pair stays intact with hidden labels and a single column")

    durability, overall, equipped, unavailable = 65, 112, 110, false
    env.__fireEvent("AUCTION_HOUSE_CLOSED")
    env.__fireEvent("UPDATE_INVENTORY_DURABILITY")
    assert(addon:RunUpdateStatsSafe())
    local recoveredRating, recoveredValue = getRow("splitItemLevel")
    assert(plain(recoveredRating) == "110|112" and recoveredValue == "",
        "item level removes the stale marker after a complete read")
    rating = getRow("splitDurability")
    assert(plain(rating) == "65.0%", "durability removes the stale marker after a complete scan")
    print(flavor .. " gear HUD freshness regressions passed")
end
