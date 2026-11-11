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

renderStats("700", "12%", "Repair:")
calls = {}
renderStats("701", "13%", "Repair:")
stable("steady clean repair layout")
equal("steady clean text still reaches rating", rating:GetText(), "701")
equal("steady clean text measured", count("rating.GetStringWidth"), 1)

setMeasure("rating", hiddenDimension, hiddenDimension)
setMeasure("value", hiddenDimension, hiddenDimension)
renderStats(secretA, secretA, "Repair:")
calls = {}
renderStats(secretB, secretB, "Repair:")
stable("steady restricted repair layout")
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
equal("normal stats frame width", frame:GetWidth(), 101)
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
if #errors > 0 then error(table.concat(errors, "\n"), 0) end
print((forever and "Forever" or "Retail") .. " HUD clean/restricted geometry and visibility passed")