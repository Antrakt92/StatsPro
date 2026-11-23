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

    -- The last clean measurement may be narrower than the visible combat text.
    -- Compute the gap from the actual glyph width, rather than the cached width.
    local function visibleGap(region, measuredGlyphWidth)
        local edge, _, _, offset = region:GetPoint()
        local left = edge == "TOPLEFT" and offset or frame:GetWidth() + offset - measuredGlyphWidth
        return left - test.panelVisualState().mainRenderedLabelW
    end
    local settings = test.profileState().settings
    for _, showRating in ipairs({ true, false }) do
        settings.showRating = showRating
        test.cacheSettings()
        local column = showRating and "value" or "rating"
        local region = showRating and value or rating
        local function renderHaste(text)
            render("Ranged Haste:", showRating and "" or text, showRating and text or "", 1, "coin", "Repair:")
        end
        setMeasure("label", 174)
        setMeasure(column, 44)
        renderHaste("25.00%")
        equal(column .. " clean value leaves the full label gap", visibleGap(region, 44), 6)
        local cleanWidth = frame:GetWidth()

        setMeasure(column, hiddenDimension)
        renderHaste("(25.00%)")
        equal(column .. " wider combat text leaves the full label gap", visibleGap(region, 58), 6)
        equal(column .. " protected measurement keeps the HUD width", frame:GetWidth(), cleanWidth)

        setMeasure(column, 0)
        renderHaste("(25.00%)")
        equal(column .. " zero-width combat reading preserves the HUD width", frame:GetWidth(), cleanWidth)
        equal(column .. " zero-width combat reading leaves the full label gap", visibleGap(region, 58), 6)

        setMeasure(column, 44)
        renderHaste("25.00%")
        equal(column .. " leaving combat restores the clean value", region:GetText(), "25.00%")
        equal(column .. " leaving combat leaves the full label gap", visibleGap(region, 44), 6)
    end
    settings.showRating = true
    test.cacheSettings()
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

if forever then
    local protectedLevel = {}
    local readable = true
    local function readItemLevel()
        if readable then return 115, 90 end
        return 115, protectedLevel
    end
    local gearEnv, gearAddon, gearTest = fixtures.loadStatsPro("enUS", {
        forever = true,
        foreverAPIs = { GetAverageItemLevel = readItemLevel },
        issecretvalue = function(value) return rawequal(value, protectedLevel) end,
    })
    gearEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    local settings = gearTest.profileState().settings
    for _, rows in pairs(gearAddon.forever.rows) do
        for _, row in ipairs(rows) do settings[row.showKey] = false end
    end
    settings.showOffensive, settings.showDefensive, settings.showTertiary = false, false, false
    settings.showDurability, settings.showRepairCost, settings.showItemLevel = false, false, true
    settings.labelStyle, settings.splitItemLevel, settings.showPercentage = "full", true, true
    local function plain(text)
        return (text:gsub("|cff%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("||", "|"))
    end
    local function currentColumns(mode)
        local state = gearTest.panelVisualState()
        if mode == "split" then return state.sideRatingText, state.sideValueText end
        return state.mainRatingText, state.mainValueText
    end
    for _, mode in ipairs({ "flat", "sectioned", "split" }) do
        for _, showRating in ipairs({ true, false }) do
            settings.displayMode, settings.showRating = mode, showRating
            gearTest.cacheSettings()
            readable = true
            gearEnv.__fireEvent("PLAYER_EQUIPMENT_CHANGED", 1, true)
            equal(mode .. " readable item level updates", gearAddon:RunUpdateStatsSafe(), true)
            local rating, value = currentColumns(mode)
            local populated, empty = value, rating
            if not showRating then populated, empty = rating, value end
            equal(mode .. " item-level pair reaches the actual HUD", plain(populated):find("90|115", 1, true) ~= nil, true)
            equal(mode .. " equipped item-level alert stays visible", populated:find("|cffff333390|r", 1, true) ~= nil, true)
            equal(mode .. " item levels share one value column", empty, "")
            local panelName = mode == "split" and "side" or "main"
            for index, target in ipairs(gearTest.panelTooltipState(panelName).lastTargetRows) do
                if type(target) == "table" and target.key == "ItemLevel" then
                    gearTest.firePanelTooltipOverlayForSmoke(panelName, index, "OnEnter")
                    break
                end
            end
            local tooltip = gearEnv.StatsProTargetTooltip
            equal(mode .. " item-level tooltip header shows both live readings", tooltip.lines[1].right, "90 / 115")

            readable = false
            gearEnv.__fireEvent("PLAYER_EQUIPMENT_CHANGED", 1, true)
            equal(mode .. " restricted item level updates", gearAddon:RunUpdateStatsSafe(), true)
            rating, value = currentColumns(mode)
            populated = showRating and value or rating
            equal(mode .. " both stale item levels stay visible", plain(populated):find("(90)|(115)", 1, true) ~= nil, true)
            equal(mode .. " stale item levels have no warning", populated:find("|cffff3333", 1, true), nil)
            equal(mode .. " the open tooltip header marks both stale readings", tooltip.lines[1].right, "(90) / (115)")
            equal(mode .. " stale tooltip status remains visible", tooltip.lines[2].left, "Last reliable reading")
        end
    end
end

if forever then
    local hoverEnv, hoverAddon, hoverTest = fixtures.loadStatsPro("enUS", {
        forever = true,
        foreverAPIs = { UnitStat = function() return 0, 130, 0, 0 end },
    })
    hoverEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    local settings = hoverTest.profileState().settings
    for _, rows in pairs(hoverAddon.forever.rows) do
        for _, row in ipairs(rows) do settings[row.showKey] = false end
    end
    settings.showStrength, settings.showAgility = true, true
    settings.showItemLevel, settings.showDurability, settings.showRepairCost = false, false, false
    settings.displayMode = "flat"
    settings.isLocked = false
    hoverTest.cacheSettings()
    hoverAddon.forever.BuildStatTooltip = function(_, add) add("Audit detail", "1") end
    equal("both edge-anchor fixture rows render", hoverAddon:RunUpdateStatsSafe(), true)
    local right = 995
    hoverEnv.StatsProFrame.GetRight = function() return right end
    hoverEnv.StatsProFrame.GetEffectiveScale = function() return 1 end
    hoverEnv.UIParent.GetEffectiveScale = function() return 1 end
    hoverEnv.UIParent:SetWidth(1000)
    hoverTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    local tooltip = hoverEnv.StatsProTargetTooltip
    equal("first row opens toward the viewport interior", tooltip:GetPoint(), "TOPRIGHT")
    hoverTest.fireMainPanelTooltipOverlayForSmoke(1, "OnLeave")

    right = nil
    hoverTest.fireMainPanelTooltipOverlayForSmoke(2, "OnEnter")
    equal("unavailable geometry uses the default anchor", tooltip:GetPoint(), "TOPLEFT")
    hoverTest.fireMainPanelTooltipOverlayForSmoke(2, "OnLeave")

    right = 995
    hoverTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    equal("returning to the first row reapplies its inward anchor", tooltip:GetPoint(), "TOPRIGHT")

    local after = hoverEnv.C_Timer.After
    local failedRelease
    hoverEnv.C_Timer.After = function(_, callback)
        failedRelease = callback
        error("drag guard timer unavailable")
    end
    hoverTest.fireMainPanelTooltipOverlayForSmoke(1, "OnDragStart")
    equal("starting the drag guards hover", hoverTest.panelTooltipState("main").wasDragging, true)
    equal("timer rejection is contained by drag stop",
        pcall(hoverTest.fireMainPanelTooltipOverlayForSmoke, 1, "OnDragStop"), true)
    hoverEnv.C_Timer.After = after
    equal("timer rejection cannot keep hover guarded", hoverTest.panelTooltipState("main").wasDragging, false)
    hoverTest.fireMainPanelTooltipOverlayForSmoke(1, "OnEnter")
    equal("hover reopens after guard timer rejection", tooltip:IsShown(), true)

    hoverTest.fireMainPanelTooltipOverlayForSmoke(1, "OnDragStart")
    failedRelease()
    equal("obsolete partial timer cannot release a newer drag", hoverTest.panelTooltipState("main").wasDragging, true)
    hoverTest.fireMainPanelTooltipOverlayForSmoke(1, "OnDragStop")
    hoverEnv.__flushTimers()
    equal("normal drag stop releases the live guard", hoverTest.panelTooltipState("main").wasDragging, false)
end

if forever then
    local fontEnv, fontAddon, fontTest = fixtures.loadStatsPro("enUS", {
        forever = true,
        statsProDB = { dbVersion = 9, forceLocale = "ruRU" },
    })
    fontEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    local detailCount = 1
    fontAddon.forever.BuildStatTooltip = function(_, add)
        for index = 1, detailCount do add("Extra tooltip line " .. index) end
    end
    local tooltip = fontAddon.archonTargets.GetTooltip()
    local originalSetFont = tooltip.headerProbe.SetFont
    originalSetFont(tooltip.headerProbe, "WrongLatin.ttf", 12, "")
    local attempts = 0
    local function hover()
        for index, meta in ipairs(fontTest.mainPanelTooltipState().lastTargetRows) do
            if type(meta) == "table" then
                return fontTest.fireMainPanelTooltipOverlayForSmoke(index, "OnEnter")
            end
        end
        error("expected a visible Forever tooltip row")
    end

    local setHeaderFont = function(self, ...)
        attempts = attempts + 1
        if attempts == 1 then return false end
        return originalSetFont(self, ...)
    end
    tooltip.headerProbe.SetFont = function(self, ...) return setHeaderFont(self, ...) end
    hover()
    equal("partial tooltip font application leaves locale unconfirmed", tooltip.statLocale, nil)
    equal("the initially unavailable tooltip header font retains its previous path",
        tooltip.headerProbe:GetFont(), "WrongLatin.ttf")
    hover()
    equal("immediate hover does not repeat the failed native font call", attempts, 1)
    fontEnv.__flushTimers()
    hover()
    equal("tooltip font recovers on a later attempt", attempts, 2)
    equal("only a confirmed font settles the tooltip locale", tooltip.statLocale, "ruRU")
    equal("the recovered header uses the measured tooltip font", tooltip.headerProbe:GetFont(), tooltip.statFont)

    local originalCreate = tooltip.CreateFontString
    local nextRegion
    tooltip.CreateFontString = function(self, ...)
        local region = originalCreate(self, ...)
        if not nextRegion then
            nextRegion = region
            local setFont = region.SetFont
            setFont(region, "WrongLatin.ttf", 12, "")
            region.SetFont = function(frame, ...)
                region.SetFont = setFont
                error("late tooltip font unavailable")
            end
        end
        return region
    end
    detailCount = 12
    equal("a new tooltip FontString failure does not escape the hover handler", pcall(hover), true)
    equal("a new unconfirmed region reopens font application", tooltip.statLocale, nil)
    hover()
    equal("later layout reconciles the new region", tooltip.statLocale, "ruRU")
    equal("new tooltip region uses the confirmed font", nextRegion:GetFont(), tooltip.statFont)

    tooltip.statLocale = nil
    attempts = 0
    setHeaderFont = function()
        attempts = attempts + 1
        error("persistent tooltip header failure")
    end
    originalSetFont(tooltip.headerProbe, "WrongLatin.ttf", 12, "")
    for _ = 1, 12 do
        equal("persistent font failure never escapes hover", pcall(hover), true)
        fontEnv.__flushTimers()
    end
    equal("persistent tooltip font failures exhaust bounded attempts",
        attempts, #fontAddon.fontRuntime.pendingRetryDelays + 1)
    equal("an unresolved tooltip font does not confirm a locale", tooltip.statLocale, nil)
    setHeaderFont = originalSetFont
    hover()
    equal("ordinary hover cannot reopen exhausted font attempts", tooltip.statLocale, nil)
    fontEnv.__fireEvent("ADDON_LOADED", "AntraktFonts")
    equal("provider arrival reconciles on the regular update", fontAddon:RunUpdateStatsSafe(), true)
    hover()
    equal("catalog reconciliation reopens the same-locale font", tooltip.statLocale, "ruRU")
    equal("catalog recovery applies the expected header font", tooltip.headerProbe:GetFont(), tooltip.statFont)

    tooltip.statLocale = nil
    originalSetFont(tooltip.headerProbe, "WrongLatin.ttf", 12, "")
    setHeaderFont = function() return false end
    for _ = 1, 12 do
        hover()
        fontEnv.__flushTimers()
    end
    equal("the same locale may exhaust again under a new failure", tooltip.statLocale, nil)
    setHeaderFont = originalSetFont
    fontEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    hover()
    equal("entering world reopens a late tooltip font recovery", tooltip.statLocale, "ruRU")
    equal("world recovery applies the expected header font", tooltip.headerProbe:GetFont(), tooltip.statFont)
end

do
    local price = 12345
    local function loadSplitRepair()
        return fixtures.loadStatsPro("enUS", {
            forever = forever,
            statsProDB = {
                dbVersion = 9, displayMode = "split", showDurability = true,
                showRepairCost = true, splitRepairCost = true, fontSize = 14,
            },
            getInventoryItemDurability = function(slot)
                if slot == 1 then return 75, 100 end
            end,
            getTooltipInventoryItem = function() return { repairCost = price } end,
        })
    end

    local gearEnv, gearAddon, gearTest = loadSplitRepair()
    local mainLabel = gearTest.setPanelMeasurementOverride("main", "label", 500, 48)
    local sideRepair = gearTest.panelFontState().sideFontRegions[4]
    gearEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    equal("valid label width is cached", gearTest.panelVisualState().mainCachedLabelW, 500)
    equal("split repair starts with the original price", sideRepair:GetText(), "coin:12345:14")
    local originalWidth, originalHeight = mainLabel.GetStringWidth, mainLabel.GetStringHeight
    for index, failure in ipairs({
        { "throwing", function() error("native measurement unavailable") end },
        { "NaN", function() return 0 / 0 end },
        { "infinite", function() return math.huge end },
        { "incorrect type", function() return "500" end },
        { "negative", function() return -1 end },
    }) do
        local name, measure = unpack(failure)
        mainLabel.GetStringWidth, mainLabel.GetStringHeight = measure, measure
        price = 23456 + index
        gearEnv.__fireEvent("UPDATE_INVENTORY_DURABILITY")
        equal(name .. " measurement does not abort either panel", gearAddon:RunUpdateStatsSafe(), true)
        local state = gearTest.panelVisualState()
        equal(name .. " measurement keeps the last clean width", state.mainCachedLabelW, 500)
        equal(name .. " measurement uses the last clean width", state.mainRenderedLabelW, 500)
        equal(name .. " measurement keeps the last clean height", state.mainCachedLabelH, 48)
        equal(name .. " measurement still renders current split repair", sideRepair:GetText(), "coin:" .. price .. ":14")
    end
    mainLabel.GetStringWidth, mainLabel.GetStringHeight = originalWidth, originalHeight
    gearTest.setPanelMeasurementOverride("main", "label", 240, 31)
    equal("valid measurement still succeeds after repeated failures", gearAddon:RunUpdateStatsSafe(), true)
    equal("a later clean width replaces the previous cache", gearTest.panelVisualState().mainCachedLabelW, 240)

    local coldEnv, coldAddon, coldTest = loadSplitRepair()
    local coldLabel = coldTest.setPanelMeasurementOverride("main", "label", nil, nil)
    coldLabel.GetStringWidth = function() error("cold native width unavailable") end
    coldLabel.GetStringHeight = function() return math.huge end
    coldEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    equal("cold measurement failure still renders", coldAddon:RunUpdateStatsSafe(), true)
    local cold = coldTest.panelVisualState()
    equal("cold unavailable width uses the conservative font-size fallback", cold.mainRenderedLabelW, 14 * 8)
    equal("cold width estimate does not masquerade as a clean cache", cold.mainCachedLabelW, nil)
    equal("cold height estimate does not masquerade as a clean cache", cold.mainCachedLabelH, nil)
    equal("cold fallback does not stop the split repair row",
        coldTest.panelFontState().sideFontRegions[4]:GetText(), "coin:" .. price .. ":14")
end

if #errors > 0 then error(table.concat(errors, "\n"), 0) end
print((forever and "Forever" or "Retail") .. " HUD clean/restricted geometry and visibility passed")
