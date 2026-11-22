local forever = arg[1] == "forever"
local fixtures = assert(loadfile("scripts/smoke.lua"))("fixtures")
local hiddenDimension, secretA, secretB = {}, {}, {}
local env, _, test = fixtures.loadStatsPro("enUS", {
    forever = forever,
    statsProDB = { showRating = true, showPercentage = true },
    issecretvalue = function(value)
        return value == hiddenDimension or value == secretA or value == secretB
    end,
})
env.__fireEvent("PLAYER_ENTERING_WORLD")

local function setMeasure(column, width, height)
    return test.setPanelMeasurementOverride("main", column, width, height or 14)
end
local label = setMeasure("label", 32)
local rating = setMeasure("rating", 30)
local value = setMeasure("value", 35)
local coin = setMeasure("repair", 140)
local repairLabel = setMeasure("repairLabel", 48)
local frame = env.StatsProFrame
local calls, errors = {}, {}

local function watch(object, region, methods)
    for _, name in ipairs(methods) do
        local original = object[name]
        object[name] = function(self, ...)
            local key = region .. "." .. name
            calls[key] = (calls[key] or 0) + 1
            return original(self, ...)
        end
    end
end

watch(frame, "frame", { "SetWidth", "SetHeight", "Show", "Hide" })
for key, region in pairs({ label = label, rating = rating, value = value, coin = coin, repairLabel = repairLabel }) do
    watch(region, key, { "ClearAllPoints", "SetPoint", "SetWidth", "Show", "Hide", "SetText", "GetStringWidth", "GetStringHeight" })
end
watch(repairLabel, "repairLabel", { "GetUnboundedStringWidth" })

local function equal(message, actual, expected)
    if actual ~= expected then
        errors[#errors + 1] = message .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual)
    end
end
local function count(key) return calls[key] or 0 end
local function noAnchorWrites(prefix)
    for _, key in ipairs({ "rating", "value", "coin", "repairLabel" }) do
        equal(prefix .. " " .. key .. " ClearAllPoints", count(key .. ".ClearAllPoints"), 0)
        equal(prefix .. " " .. key .. " SetPoint", count(key .. ".SetPoint"), 0)
    end
end
local function stable(prefix)
    noAnchorWrites(prefix)
    for _, key in ipairs({ "frame.SetWidth", "frame.SetHeight", "frame.Show", "frame.Hide",
        "repairLabel.SetWidth", "repairLabel.Show", "repairLabel.Hide", "coin.Show", "coin.Hide" }) do
        equal(prefix .. " " .. key, count(key), 0)
    end
end
local render = test.renderMainPanelForSmoke
local function renderStats(ratingText, valueText, repairCaption)
    render("Crit:", ratingText, valueText, 1, "coin", repairCaption)
end

local function labelToRatingGap()
    local state = test.panelVisualState()
    return state.mainFrameWidth + state.mainRatingPoints[1][4]
        - state.mainRenderedRatingW - state.mainRenderedLabelW
end

renderStats("700", "12%", "Repair:")
equal("wide repair row preserves label gap", labelToRatingGap(), 6)
calls = {}
renderStats("701", "13%", "Repair:")
stable("steady clean repair layout")
equal("steady clean text still reaches rating", rating:GetText(), "701")
equal("steady clean text measured", count("rating.GetStringWidth"), 1)

equal("ordinary repair frame height", frame:GetHeight(), 29)
setMeasure("repair", 140, 24)
calls = {}
renderStats("701", "13%", "Repair:")
equal("taller coin fits within clamped frame", frame:GetHeight(), 39)
equal("taller coin resizes frame once", count("frame.SetHeight"), 1)
noAnchorWrites("taller coin retains the top of its row")
calls = {}
renderStats("701", "13%", "Repair:")
stable("steady tall coin")
setMeasure("repair", 140, hiddenDimension)
calls = {}
renderStats("701", "13%", "Repair:")
equal("restricted coin measurement reuses clean height", frame:GetHeight(), 39)
stable("steady restricted tall coin")
setMeasure("repair", 140)
setMeasure("repairLabel", 48, 26)
renderStats("701", "13%", "Repair:")
equal("taller caption fits within clamped frame", frame:GetHeight(), 41)
setMeasure("repairLabel", 48)
renderStats("701", "13%", "Repair:")
equal("repair height shrinks with content", frame:GetHeight(), 29)

setMeasure("rating", hiddenDimension, hiddenDimension)
setMeasure("value", hiddenDimension, hiddenDimension)
renderStats(secretA, secretA, "Repair:")
calls = {}
renderStats(secretB, secretB, "Repair:")
stable("steady restricted repair layout")
equal("restricted geometry preserves label gap", labelToRatingGap(), 6)
equal("new restricted rating delivered live", rating:GetText(), secretB)
equal("new restricted value delivered live", value:GetText(), secretB)
equal("new restricted rating passed through setter", count("rating.SetText"), 1)
equal("new restricted rating still measured", count("rating.GetStringWidth"), 1)
equal("last clean width retained", test.panelVisualState().mainCachedRatingW, 30)
setMeasure("rating", 30)
setMeasure("value", 35)

calls = {}
renderStats("701", "13%", "")
equal("hidden repair caption width", repairLabel:GetWidth(), 0)
equal("hide caption once", count("repairLabel.Hide"), 1)
equal("resize hidden caption once", count("repairLabel.SetWidth"), 1)
equal("already shown coin not shown again", count("coin.Show"), 0)
calls = {}
renderStats("701", "13%", "")
stable("steady hidden repair caption")

calls = {}
render("Crit:", "701", "13%", 1)
equal("disabling repair hides coin once", count("coin.Hide"), 1)
equal("already hidden caption not hidden again", count("repairLabel.Hide"), 0)
equal("normal stats frame width", frame:GetWidth(), 105)
equal("normal stats keep a visible label gap", labelToRatingGap(), 6)
calls = {}
render("Crit:", "702", "14%", 1)
stable("steady without repair")

calls = {}
render("", "", "", 0, "coin", "Repair:")
equal("repair-only coin anchors at top", select(5, coin:GetPoint()), 0)
equal("repair-only caption anchors at top", select(5, repairLabel:GetPoint()), 0)
equal("repair-only preserves separate width", frame:GetWidth(), 190)
equal("repair-only shows coin", count("coin.Show"), 1)
equal("repair-only shows caption", count("repairLabel.Show"), 1)
calls = {}
render("", "", "", 0, "coin", "Repair:")
stable("steady repair-only")

calls = {}
render(nil, nil, nil, 0)
equal("hidden content frame transitions once", count("frame.Hide"), 1)
equal("hide clears repair region intent", coin:IsShown(), false)
equal("hide preserves last clean rating measurement", test.panelVisualState().mainCachedRatingW, 30)
calls = {}
render(nil, nil, nil, 0)
stable("already hidden")
calls = {}
render("", "", "", 0, "coin", "Repair:")
equal("reopening shows frame", count("frame.Show"), 1)
equal("reopening shows coin", count("coin.Show"), 1)
equal("reopening shows label", count("repairLabel.Show"), 1)
equal("reopening refreshes height", count("frame.SetHeight"), 1)
equal("reopening restores coin text", coin:GetText(), "coin")
equal("reopening restores label text", repairLabel:GetText(), "Repair:")
noAnchorWrites("same repair-only anchors after reopening")
equal("reopening keeps existing frame width", count("frame.SetWidth"), 0)

local oldRatingOffset = select(4, rating:GetPoint())
local originalSetPoint = rating.SetPoint
rating.SetPoint = function() error("fixture native anchor failure") end
setMeasure("repair", 180)
local rendered = pcall(render, "", "", "", 0, "coin", "Repair:")
rating.SetPoint = originalSetPoint
equal("changed geometry exercises native failure", rendered, false)
setMeasure("repair", 140)
render("", "", "", 0, "coin", "Repair:")
equal("partial anchor failure can recover prior geometry", select(4, rating:GetPoint()), oldRatingOffset)
if forever then
    setMeasure("label", 174, 102)
    setMeasure("rating", 0, 102)
    setMeasure("value", 32, 102)
    setMeasure("repairLabel", 54, 17)
    setMeasure("repair", 42, 17)
    render("Intellect:", "", "129.25", 6, "coin", "Repair:")
    local clean = test.panelVisualState()
    setMeasure("rating", hiddenDimension, hiddenDimension)
    setMeasure("value", hiddenDimension, hiddenDimension)
    calls = {}
    render("Intellect:", "", secretA, 6, "coin", "Repair:")
    local restricted = test.panelVisualState()
    equal("restricted empty rating column claims no width", restricted.mainRenderedRatingW, 0)
    equal("protected value keeps its known clean width", restricted.mainRenderedValueW, 32)
    equal("protected values keep HUD width", restricted.mainFrameWidth, clean.mainFrameWidth)
    equal("protected values keep HUD height", restricted.mainFrameHeight, clean.mainFrameHeight)
    stable("clean to protected update")
    equal("protected text still reaches the live column", value:GetText(), secretA)
    setMeasure("rating", 0, 102)
    setMeasure("value", 30, 102)
    render("Intellect:", "", "71.13", 6, "coin", "Repair:")
    equal("next clean reading can resize the value column", test.panelVisualState().mainRenderedValueW, 30)
end

do
    setMeasure("label", 22)
    setMeasure("rating", 22)
    setMeasure("value", 8)
    setMeasure("repairLabel", 38)
    for _, anchor in ipairs({ "TOPLEFT", "TOP", "TOPRIGHT" }) do
        frame:ClearAllPoints()
        frame:SetPoint(anchor, env.UIParent, anchor, 30, -18)
        render("Crit:", "1", "2%", 1)
        equal(anchor .. " short stats have the minimum panel width", frame:GetWidth(), 80)
        local statGap = labelToRatingGap()
        for _, case in ipairs({
            { "unavailable", "—", 30, 80 },
            { "plain", "1 Gold 23 Silver 45 Copper", 100, 140 },
            { "texture", "coin", 80, 120 },
            { "hidden", "", 0, 80 },
        }) do
            local name, repair, repairWidth, frameWidth = unpack(case)
            local label = repair ~= "" and "Repair:" or nil
            local prefix = anchor .. " " .. name
            setMeasure("repair", repairWidth)
            render("Crit:", "1", "2%", 1, repair, label)
            equal(prefix .. " keeps the stat column gap", labelToRatingGap(), statGap)
            equal(prefix .. " uses the visible repair width only", frame:GetWidth(), frameWidth)
            equal(prefix .. " keeps the configured frame anchor", frame:GetPoint(), anchor)
            equal(prefix .. " keeps the saved horizontal offset", select(4, frame:GetPoint()), 30)
            equal(prefix .. " repair region visibility follows payload", coin:IsShown(), repair ~= "")
        end
    end
end

do
    local reads, formattedAmount
    reads = 0
    local sizeEnv, sizeAddon, sizeTest = fixtures.loadStatsPro("enUS", {
        forever = forever,
        statsProDB = { showDurability = true, showRepairCost = true, fontSize = 14 },
        getInventoryItemDurability = function(slot)
            reads = reads + 1
            if slot == 1 then return 75, 100 end
        end,
        getTooltipInventoryItem = function() return { repairCost = 12345 } end,
    })
    sizeEnv.GetCoinTextureString = nil
    sizeEnv.C_CurrencyInfo = { GetCoinText = function(amount)
        formattedAmount = amount
        return "1 Gold 23 Silver 45 Copper"
    end }
    sizeEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    sizeAddon:OpenConfigMenu()
    local repair = sizeTest.panelFontState().mainFontRegions[4]
    local initialReads = reads
    for _, size in ipairs({ 32, 8 }) do
        sizeEnv.StatsProFontSlider:SetValue(size)
        equal("reflow applies actual repair font size", select(2, repair:GetFont()), size)
        equal("reflow preserves exact plain repair text", repair:GetText(), "1 Gold 23 Silver 45 Copper")
        equal("reflow reuses the confirmed amount", formattedAmount, 12345)
        equal("reflow does not rescan inventory", reads, initialReads)
    end
end

for _, mode in ipairs({ "flat", "split" }) do
    local available, equippedID, amount = true, 6001, 12345
    local inventoryReads, tooltipReads = 0, 0
    local refreshEnv, refreshAddon, refreshTest = fixtures.loadStatsPro("enUS", {
        forever = forever,
        statsProDB = {
            showDurability = true, showRepairCost = true, fontSize = 14,
            displayMode = mode, splitRepairCost = mode == "split",
        },
        getInventoryItemDurability = function(slot)
            inventoryReads = inventoryReads + 1
            if slot == 1 and available then return 75, 100 end
        end,
        getTooltipInventoryItem = function()
            tooltipReads = tooltipReads + 1
            if amount then return { repairCost = amount } end
        end,
    })
    refreshEnv.GetInventoryItemID = function(_, slot) return slot == 1 and equippedID or nil end
    refreshEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    refreshAddon:OpenConfigMenu()
    local fonts = refreshTest.panelFontState()
    local repair = (mode == "split" and fonts.sideFontRegions or fonts.mainFontRegions)[4]
    local otherRepair = (mode == "split" and fonts.mainFontRegions or fonts.sideFontRegions)[4]
    local function reflow(size, message, shown, text)
        local beforeInventory, beforeTooltip = inventoryReads, tooltipReads
        refreshEnv.StatsProFontSlider:SetValue(size)
        local prefix = mode .. " " .. message
        equal(prefix .. " repair visibility", repair:IsShown(), shown)
        if text then equal(prefix .. " repair text", repair:GetText(), text) end
        equal(prefix .. " other panel has no repair", otherRepair:IsShown(), false)
        equal(prefix .. " reflow reads no inventory", inventoryReads, beforeInventory)
        equal(prefix .. " reflow reads no tooltip", tooltipReads, beforeTooltip)
    end

    equal(mode .. " initially shows the confirmed price", repair:GetText(), "coin:12345:14")
    equippedID, available = 6002, false
    refreshEnv.__fireEvent("PLAYER_EQUIPMENT_CHANGED", 1, true)
    reflow(18, "dirty equipment", true, "—")
    refreshEnv.__fireEvent("AUCTION_HOUSE_SHOW")
    reflow(21, "dirty equipment at auction", false)
    available, amount = true, 23456
    refreshEnv.__fireEvent("AUCTION_HOUSE_CLOSED")
    reflow(22, "closing auction defers read and reveal", false)
    equal(mode .. " coalesced update succeeds", refreshAddon:RunUpdateStatsSafe(), true)
    equal(mode .. " coalesced update reveals repair", repair:IsShown(), true)
    equal(mode .. " coalesced update reveals current exact price", repair:GetText(), "coin:23456:22")

    amount = nil
    refreshEnv.__fireEvent("UPDATE_INVENTORY_DURABILITY")
    reflow(24, "dirty durability", true, "—")
    amount = 34567
    equal(mode .. " later durability update succeeds", refreshAddon:RunUpdateStatsSafe(), true)
    equal(mode .. " later durability update shows current price", repair:GetText(), "coin:34567:24")
end

do
    local available = true
    local auctionEnv, _, auctionTest = fixtures.loadStatsPro("enUS", {
        forever = forever,
        statsProDB = {
            displayMode = "sectioned", showRepairCost = true,
            showDurability = false, showItemLevel = false,
        },
        getInventoryItemDurability = function(slot)
            if slot == 1 and available then return 75, 100 end
        end,
        getTooltipInventoryItem = function() return { repairCost = 12345 } end,
    })
    auctionEnv.GetInventoryItemID = function(_, slot) return slot == 1 and 6001 or nil end
    auctionEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    local settings = auctionTest.profileState().settings
    settings.showRepairCost, settings.showDurability = true, false
    auctionTest.cacheSettings()
    local ticker
    for _, frame in ipairs(auctionEnv.__frames) do
        if frame.scripts and frame.scripts.OnUpdate then
            ticker = frame
            break
        end
    end
    assert(ticker, "expected the HUD update ticker")
    ticker.scripts.OnUpdate(ticker, 1)
    local regions = auctionTest.panelFontState().mainFontRegions
    equal("sectioned repair starts with the Gear heading", regions[1]:GetText():find("Gear", 1, true) ~= nil, true)
    available = false
    auctionEnv.__fireEvent("PLAYER_EQUIPMENT_CHANGED", 1)
    auctionEnv.__fireEvent("AUCTION_HOUSE_SHOW")
    ticker.scripts.OnUpdate(ticker, 0.001)
    equal("the first auction frame hides pending repair", regions[4]:IsShown(), false)
    local visibleLabel = auctionEnv.StatsProFrame:IsShown() and regions[1]:GetText() or ""
    equal("the first auction frame removes the empty Gear heading", visibleLabel:find("Gear", 1, true), nil)
end

for _, mode in ipairs({ "recovered", "superseded", "exhausted" }) do
    local guid, guidReads, rejected = nil, 0, 0
    local profileEnv, _, profileTest = fixtures.loadStatsPro("enUS", {
        forever = forever,
        specIndex = 1, specID = 73, specRole = "TANK",
        unitGUID = function()
            guidReads = guidReads + 1
            return guid
        end,
    })
    local after = profileEnv.C_Timer.After
    profileEnv.C_Timer.After = function(delay, callback)
        if delay == 0.25 or delay == 0.5 or delay == 0.75 then
            rejected = rejected + 1
            -- Simulate native registration that accepts a callback before throwing.
            if mode ~= "exhausted" then after(delay, callback) end
            error("context timer is temporarily unavailable")
        end
        return after(delay, callback)
    end
    local ticker
    for _, candidate in ipairs(profileEnv.__frames) do
        if candidate.scripts and type(candidate.scripts.OnUpdate) == "function" then
            ticker = candidate
            break
        end
    end
    assert(ticker, "expected the persistent StatsPro ticker")
    local function tick(elapsed)
        ticker.scripts.OnUpdate(ticker, elapsed)
    end
    profileEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    local profile = profileTest.profileRuntimeState()
    equal(mode .. " starts with a rejected native context timer", rejected, 1)
    equal(mode .. " bootstrap waits while player context is unresolved", profile.pendingResolution, true)
    equal(mode .. " the failed native callback no longer owns the retry", profile.contextRetryScheduled, false)
    equal(mode .. " bootstrap HUD remains hidden initially", profileEnv.StatsProFrame:IsShown(), false)
    local reads = guidReads
    if mode ~= "exhausted" then guid = "Player-Timer-Recovery" end
    profileEnv.__flushTimers()
    equal(mode .. " a partially registered callback cannot resolve its stale request", guidReads, reads)
    tick(0.1)
    tick(0.1)
    equal(mode .. " fallback never rereads context before its normal delay", guidReads, reads)
    if mode == "superseded" then
        profileEnv.__fireEvent("UNIT_NAME_UPDATE", "player")
        profileEnv.__flushTimers()
        equal("new native request resolves bootstrap before the stale fallback", profileEnv.StatsProFrame:IsShown(), true)
        reads = guidReads
        tick(0.1)
        equal("superseded fallback cannot reread the new context", guidReads, reads)
    elseif mode == "recovered" then
        tick(0.1)
        equal("one transient timer failure recovers without a new event", profileEnv.StatsProFrame:IsShown(), true)
        equal("fallback completes profile resolution", profileTest.profileRuntimeState().pendingResolution, false)
    else
        for _ = 1, 30 do tick(0.1) end
        equal("persistent timer failure retains the original bounded retry count", rejected, 3)
        equal("persistent failure keeps the unresolved HUD hidden", profileEnv.StatsProFrame:IsShown(), false)
        reads = guidReads
        tick(10)
        equal("exhausted fallback performs no additional reads", guidReads, reads)
    end
end

if #errors > 0 then error(table.concat(errors, "\n"), 0) end
print((forever and "Forever" or "Retail") .. " HUD clean/restricted geometry and visibility passed")
