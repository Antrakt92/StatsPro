local args = { ... }

local DEFAULT_PATH = "StatsPro_ArchonTargets.lua"
local REQUIRED_STATS = { "crit", "haste", "mastery", "versatility" }

local SPECS = {
    { classToken = "DEATHKNIGHT", classSlug = "death-knight", specKey = "blood", specSlug = "blood" },
    { classToken = "DEATHKNIGHT", classSlug = "death-knight", specKey = "frost", specSlug = "frost" },
    { classToken = "DEATHKNIGHT", classSlug = "death-knight", specKey = "unholy", specSlug = "unholy" },
    { classToken = "DEMONHUNTER", classSlug = "demon-hunter", specKey = "havoc", specSlug = "havoc" },
    { classToken = "DEMONHUNTER", classSlug = "demon-hunter", specKey = "devourer", specSlug = "devourer" },
    { classToken = "DEMONHUNTER", classSlug = "demon-hunter", specKey = "vengeance", specSlug = "vengeance" },
    { classToken = "DRUID", classSlug = "druid", specKey = "balance", specSlug = "balance" },
    { classToken = "DRUID", classSlug = "druid", specKey = "feral", specSlug = "feral" },
    { classToken = "DRUID", classSlug = "druid", specKey = "guardian", specSlug = "guardian" },
    { classToken = "DRUID", classSlug = "druid", specKey = "restoration", specSlug = "restoration" },
    { classToken = "EVOKER", classSlug = "evoker", specKey = "augmentation", specSlug = "augmentation" },
    { classToken = "EVOKER", classSlug = "evoker", specKey = "devastation", specSlug = "devastation" },
    { classToken = "EVOKER", classSlug = "evoker", specKey = "preservation", specSlug = "preservation" },
    { classToken = "HUNTER", classSlug = "hunter", specKey = "beast-mastery", specSlug = "beast-mastery" },
    { classToken = "HUNTER", classSlug = "hunter", specKey = "marksmanship", specSlug = "marksmanship" },
    { classToken = "HUNTER", classSlug = "hunter", specKey = "survival", specSlug = "survival" },
    { classToken = "MAGE", classSlug = "mage", specKey = "arcane", specSlug = "arcane" },
    { classToken = "MAGE", classSlug = "mage", specKey = "fire", specSlug = "fire" },
    { classToken = "MAGE", classSlug = "mage", specKey = "frost", specSlug = "frost" },
    { classToken = "MONK", classSlug = "monk", specKey = "brewmaster", specSlug = "brewmaster" },
    { classToken = "MONK", classSlug = "monk", specKey = "mistweaver", specSlug = "mistweaver" },
    { classToken = "MONK", classSlug = "monk", specKey = "windwalker", specSlug = "windwalker" },
    { classToken = "PALADIN", classSlug = "paladin", specKey = "holy", specSlug = "holy" },
    { classToken = "PALADIN", classSlug = "paladin", specKey = "protection", specSlug = "protection" },
    { classToken = "PALADIN", classSlug = "paladin", specKey = "retribution", specSlug = "retribution" },
    { classToken = "PRIEST", classSlug = "priest", specKey = "discipline", specSlug = "discipline" },
    { classToken = "PRIEST", classSlug = "priest", specKey = "holy", specSlug = "holy" },
    { classToken = "PRIEST", classSlug = "priest", specKey = "shadow", specSlug = "shadow" },
    { classToken = "ROGUE", classSlug = "rogue", specKey = "assassination", specSlug = "assassination" },
    { classToken = "ROGUE", classSlug = "rogue", specKey = "outlaw", specSlug = "outlaw" },
    { classToken = "ROGUE", classSlug = "rogue", specKey = "subtlety", specSlug = "subtlety" },
    { classToken = "SHAMAN", classSlug = "shaman", specKey = "elemental", specSlug = "elemental" },
    { classToken = "SHAMAN", classSlug = "shaman", specKey = "enhancement", specSlug = "enhancement" },
    { classToken = "SHAMAN", classSlug = "shaman", specKey = "restoration", specSlug = "restoration" },
    { classToken = "WARLOCK", classSlug = "warlock", specKey = "affliction", specSlug = "affliction" },
    { classToken = "WARLOCK", classSlug = "warlock", specKey = "demonology", specSlug = "demonology" },
    { classToken = "WARLOCK", classSlug = "warlock", specKey = "destruction", specSlug = "destruction" },
    { classToken = "WARRIOR", classSlug = "warrior", specKey = "arms", specSlug = "arms" },
    { classToken = "WARRIOR", classSlug = "warrior", specKey = "fury", specSlug = "fury" },
    { classToken = "WARRIOR", classSlug = "warrior", specKey = "protection", specSlug = "protection" },
}

local PROFILES = {
    mythicPlus = {
        label = "M+ High Keys",
        title = "M+ Target",
        activity = "mythic-plus",
        bracket = "high-keys",
        dungeon = "all-dungeons",
        window = "this-week",
    },
    raid = {
        label = "Raid Mythic All Bosses",
        title = "Raid Target",
        activity = "raid",
        difficulty = "mythic",
        boss = "all-bosses",
        window = "last-14-days",
    },
}

local PROFILE_ORDER = { "mythicPlus", "raid" }

local function fail(message)
    error(message, 0)
end

local function read_file(path)
    local file, err = io.open(path, "rb")
    if not file then
        fail("cannot read " .. path .. ": " .. tostring(err))
    end
    local text = file:read("*a")
    file:close()
    return text
end

local function count_keys(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

local function expect_type(value, expected, context)
    if type(value) ~= expected then
        fail(context .. " must be " .. expected .. ", got " .. type(value))
    end
end

local function expect_equal(actual, expected, context)
    if actual ~= expected then
        fail(context .. " must be " .. tostring(expected) .. ", got " .. tostring(actual))
    end
end

local function is_finite_positive_number(value)
    return type(value) == "number" and value == value and value > 0 and value < math.huge
end

local function expected_url(spec, profileKey)
    if profileKey == "mythicPlus" then
        return "https://www.archon.gg/wow/builds/" .. spec.specSlug .. "/" .. spec.classSlug .. "/mythic-plus/overview/high-keys/all-dungeons/this-week"
    end
    return "https://www.archon.gg/wow/builds/" .. spec.specSlug .. "/" .. spec.classSlug .. "/raid/overview/mythic/all-bosses"
end

local function days_in_month(year, month)
    local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if month == 2 and ((year % 400 == 0) or (year % 4 == 0 and year % 100 ~= 0)) then
        return 29
    end
    return days[month]
end

local function parse_date(value, context)
    expect_type(value, "string", context)
    local y, m, d = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then
        fail(context .. " must use YYYY-MM-DD, got " .. value)
    end
    local year, month, day = tonumber(y), tonumber(m), tonumber(d)
    if month < 1 or month > 12 then
        fail(context .. " has invalid month: " .. value)
    end
    local maxDay = days_in_month(year, month)
    if day < 1 or day > maxDay then
        fail(context .. " has invalid day: " .. value)
    end
    return { year = year, month = month, day = day, value = value }
end

local function date_to_time(date)
    return os.time({ year = date.year, month = date.month, day = date.day, hour = 12, min = 0, sec = 0 })
end

local function validate_date(value, context, options)
    local parsed = parse_date(value, context)
    local today = options.today and parse_date(options.today, "today") or nil
    local todayTime = today and date_to_time(today) or os.time()
    local valueTime = date_to_time(parsed)
    if valueTime > todayTime + 86400 then
        fail(context .. " is in the future: " .. value)
    end
    if options.maxAgeDays and not options.allowStale then
        local ageDays = math.floor((todayTime - valueTime) / 86400)
        if ageDays > options.maxAgeDays then
            fail(context .. " is stale: " .. value .. " is " .. tostring(ageDays) .. " day(s) old, max " .. tostring(options.maxAgeDays))
        end
    end
end

local function contains_exactly_required_stats(tbl, context)
    expect_type(tbl, "table", context)
    expect_equal(count_keys(tbl), #REQUIRED_STATS, context .. " key count")
    for _, key in ipairs(REQUIRED_STATS) do
        if not is_finite_positive_number(tbl[key]) then
            fail(context .. "." .. key .. " must be a positive finite number")
        end
    end
end

local function validate_order(order, context)
    expect_type(order, "table", context)
    expect_equal(#order, #REQUIRED_STATS, context .. " length")
    local seen = {}
    for _, key in ipairs(order) do
        if type(key) ~= "string" then
            fail(context .. " entries must be strings")
        end
        seen[key] = (seen[key] or 0) + 1
    end
    for _, key in ipairs(REQUIRED_STATS) do
        if seen[key] ~= 1 then
            fail(context .. " must contain " .. key .. " exactly once")
        end
    end
    expect_equal(count_keys(seen), #REQUIRED_STATS, context .. " unique key count")
end

local function count_plain_occurrences(text, needle)
    if not text or not needle or needle == "" then
        return nil
    end
    local count = 0
    local index = 1
    while true do
        local startIndex, endIndex = string.find(text, needle, index, true)
        if not startIndex then
            break
        end
        count = count + 1
        index = endIndex + 1
    end
    return count
end

local function count_pattern_occurrences(text, pattern)
    local count = 0
    for _ in string.gmatch(text or "", pattern) do
        count = count + 1
    end
    return count
end

local function count_target_lines(text)
    local count = 0
    for line in string.gmatch((text or "") .. "\n", "([^\n]*)\n") do
        local stat = string.match(line, "^%s+([%a]+)%s*=%s*%d+%s*,")
        if stat then
            local required = false
            for _, key in ipairs(REQUIRED_STATS) do
                if stat == key then
                    required = true
                    break
                end
            end
            if required then
                count = count + 1
            end
        end
    end
    return count
end

local function count_line_pattern_occurrences(text, pattern)
    local count = 0
    for line in string.gmatch((text or "") .. "\n", "([^\n]*)\n") do
        if string.match(line, pattern) then
            count = count + 1
        end
    end
    return count
end

local function validate_raw_text_shape(text)
    if not text then
        return
    end
    local sourceUrlCount = count_pattern_occurrences(text, 'sourceUrl%s*=%s*"https://www%.archon%.gg/wow/builds/')
    if sourceUrlCount ~= (#SPECS * #PROFILE_ORDER) then
        fail("generated file must contain exactly " .. tostring(#SPECS * #PROFILE_ORDER) .. " Archon sourceUrl entries, got " .. tostring(sourceUrlCount))
    end

    local targetCount = count_target_lines(text)
    if targetCount ~= (#SPECS * #PROFILE_ORDER * #REQUIRED_STATS) then
        fail("generated file must contain exactly " .. tostring(#SPECS * #PROFILE_ORDER * #REQUIRED_STATS) .. " secondary-stat target entries, got " .. tostring(targetCount))
    end

    local capturedAtCount = count_pattern_occurrences(text, 'capturedAt%s*=%s*"%d%d%d%d%-%d%d%-%d%d"')
    if capturedAtCount ~= #PROFILE_ORDER then
        fail("generated file must contain exactly " .. tostring(#PROFILE_ORDER) .. " capturedAt entries, got " .. tostring(capturedAtCount))
    end
end

local function validate_snapshot(root, text, options)
    validate_raw_text_shape(text)
    expect_type(root, "table", "StatsProArchonTargets")
    expect_equal(root.schemaVersion, 2, "schemaVersion")
    expect_equal(root.source, "archon", "source")
    expect_type(root.snapshots, "table", "snapshots")
    expect_equal(count_keys(root.snapshots), #PROFILE_ORDER, "snapshots profile count")

    for _, profileKey in ipairs(PROFILE_ORDER) do
        local profile = root.snapshots[profileKey]
        local expectedProfile = PROFILES[profileKey]
        local profileContext = "snapshots." .. profileKey
        expect_type(profile, "table", profileContext)
        for key, value in pairs(expectedProfile) do
            expect_equal(profile[key], value, profileContext .. "." .. key)
        end
        validate_date(profile.capturedAt, profileContext .. ".capturedAt", options)
        expect_type(profile.specs, "table", profileContext .. ".specs")

        local expectedClasses = {}
        for _, spec in ipairs(SPECS) do
            expectedClasses[spec.classToken] = true
        end
        expect_equal(count_keys(profile.specs), count_keys(expectedClasses), profileContext .. ".specs class count")
        for classToken in pairs(profile.specs) do
            if not expectedClasses[classToken] then
                fail(profileContext .. ".specs has unexpected class " .. tostring(classToken))
            end
        end

        local expectedSpecCounts = {}
        for _, spec in ipairs(SPECS) do
            expectedSpecCounts[spec.classToken] = (expectedSpecCounts[spec.classToken] or 0) + 1
        end
        for classToken, count in pairs(expectedSpecCounts) do
            expect_type(profile.specs[classToken], "table", profileContext .. ".specs." .. classToken)
            expect_equal(count_keys(profile.specs[classToken]), count, profileContext .. ".specs." .. classToken .. " spec count")
        end

        for _, spec in ipairs(SPECS) do
            local specContext = profileContext .. ".specs." .. spec.classToken .. "." .. spec.specKey
            local specData = profile.specs[spec.classToken] and profile.specs[spec.classToken][spec.specKey]
            expect_type(specData, "table", specContext)
            local url = expected_url(spec, profileKey)
            expect_equal(specData.sourceUrl, url, specContext .. ".sourceUrl")
            local occurrenceCount = count_plain_occurrences(text, url)
            if occurrenceCount and occurrenceCount ~= 1 then
                fail(specContext .. ".sourceUrl must appear exactly once in file text, got " .. tostring(occurrenceCount))
            end
            contains_exactly_required_stats(specData.targets, specContext .. ".targets")
            validate_order(specData.order, specContext .. ".order")
        end
    end
end

local function join_order(order)
    local values = {}
    for index, value in ipairs(order or {}) do
        values[index] = value
    end
    return table.concat(values, ",")
end

local function build_semantic_lines(root)
    local lines = {}
    for _, profileKey in ipairs(PROFILE_ORDER) do
        local profile = root.snapshots[profileKey]
        lines[#lines + 1] = table.concat({
            "profile",
            profileKey,
            profile.label or "",
            profile.title or "",
            profile.activity or "",
            profile.bracket or "",
            profile.dungeon or "",
            profile.difficulty or "",
            profile.boss or "",
            profile.window or "",
        }, "\t")

        for _, spec in ipairs(SPECS) do
            local specData = root.snapshots[profileKey].specs[spec.classToken][spec.specKey]
            lines[#lines + 1] = table.concat({
                "spec",
                profileKey,
                spec.classToken,
                spec.specKey,
                specData.sourceUrl,
                tostring(specData.targets.crit),
                tostring(specData.targets.haste),
                tostring(specData.targets.mastery),
                tostring(specData.targets.versatility),
                join_order(specData.order),
            }, "\t")
        end
    end
    return lines
end

local function load_generated_file(path)
    local env = {}
    local chunk, err = loadfile(path)
    if not chunk then
        fail("cannot load " .. path .. ": " .. tostring(err))
    end
    setfenv(chunk, env)
    local ok, runErr = pcall(chunk)
    if not ok then
        fail("cannot evaluate " .. path .. ": " .. tostring(runErr))
    end
    return env.StatsProArchonTargets
end

local function make_valid_fixture(capturedAt)
    local specsByClass = {}
    for _, spec in ipairs(SPECS) do
        specsByClass[spec.classToken] = specsByClass[spec.classToken] or {}
        specsByClass[spec.classToken][spec.specKey] = spec
    end

    local snapshots = {}
    for _, profileKey in ipairs(PROFILE_ORDER) do
        local profile = {}
        for key, value in pairs(PROFILES[profileKey]) do
            profile[key] = value
        end
        profile.capturedAt = capturedAt or os.date("%Y-%m-%d")
        profile.specs = {}
        for classToken, classSpecs in pairs(specsByClass) do
            profile.specs[classToken] = {}
            for specKey, spec in pairs(classSpecs) do
                profile.specs[classToken][specKey] = {
                    sourceUrl = expected_url(spec, profileKey),
                    targets = { crit = 100, haste = 200, mastery = 300, versatility = 400 },
                    order = { "crit", "haste", "mastery", "versatility" },
                }
            end
        end
        snapshots[profileKey] = profile
    end
    return { schemaVersion = 2, source = "archon", snapshots = snapshots }
end

local function clone(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for k, v in pairs(value) do
        out[k] = clone(v)
    end
    return out
end

local function assert_throws(name, fn, pattern)
    local ok, err = pcall(fn)
    if ok then
        fail(name .. " should fail")
    end
    if pattern and not string.find(tostring(err), pattern, 1, true) then
        fail(name .. " failed with wrong error: " .. tostring(err))
    end
end

local function run_self_test()
    local options = { today = "2026-05-16", maxAgeDays = 14 }
    validate_snapshot(make_valid_fixture("2026-05-16"), nil, options)

    local rawLines = {}
    for _, profileKey in ipairs(PROFILE_ORDER) do
        rawLines[#rawLines + 1] = 'capturedAt = "2026-05-16",'
        for _, spec in ipairs(SPECS) do
            rawLines[#rawLines + 1] = 'sourceUrl = "' .. expected_url(spec, profileKey) .. '",'
            rawLines[#rawLines + 1] = "    crit = 100,"
            rawLines[#rawLines + 1] = "    haste = 200,"
            rawLines[#rawLines + 1] = "    mastery = 300,"
            rawLines[#rawLines + 1] = "    versatility = 400,"
        end
    end
    validate_raw_text_shape(table.concat(rawLines, "\n"))

    local missingSpec = clone(make_valid_fixture("2026-05-16"))
    missingSpec.snapshots.mythicPlus.specs.DEMONHUNTER.devourer = nil
    assert_throws("missing Devourer", function()
        validate_snapshot(missingSpec, nil, options)
    end, "DEMONHUNTER spec count")

    local badTarget = clone(make_valid_fixture("2026-05-16"))
    badTarget.snapshots.raid.specs.MAGE.frost.targets.mastery = 0
    assert_throws("zero target", function()
        validate_snapshot(badTarget, nil, options)
    end, "positive finite number")

    local badOrder = clone(make_valid_fixture("2026-05-16"))
    badOrder.snapshots.raid.specs.MAGE.frost.order = { "crit", "crit", "haste", "mastery" }
    assert_throws("duplicate order key", function()
        validate_snapshot(badOrder, nil, options)
    end, "crit exactly once")

    local badDate = clone(make_valid_fixture("2026-02-29"))
    assert_throws("invalid capturedAt date", function()
        validate_snapshot(badDate, nil, options)
    end, "invalid day")

    local futureDate = clone(make_valid_fixture("2026-05-18"))
    assert_throws("future capturedAt date", function()
        validate_snapshot(futureDate, nil, options)
    end, "future")

    local staleDate = clone(make_valid_fixture("2026-04-01"))
    assert_throws("stale capturedAt date", function()
        validate_snapshot(staleDate, nil, options)
    end, "stale")

    assert_throws("raw duplicate sourceUrl entries", function()
        validate_raw_text_shape('sourceUrl = "https://www.archon.gg/wow/builds/a"\nsourceUrl = "https://www.archon.gg/wow/builds/b"\n')
    end, "sourceUrl entries")

    local badMetadata = clone(make_valid_fixture("2026-05-16"))
    badMetadata.snapshots.mythicPlus.window = "last-14-days"
    assert_throws("bad profile metadata", function()
        validate_snapshot(badMetadata, nil, options)
    end, "this-week")

    io.write("Archon target validator self-test passed.\n")
end

local function parse_args(argv)
    local options = { path = DEFAULT_PATH }
    local index = 1
    while index <= #argv do
        local arg = argv[index]
        if arg == "--self-test" then
            options.selfTest = true
        elseif arg == "--semantic-lines" then
            options.semanticLines = true
        elseif arg == "--allow-stale" then
            options.allowStale = true
        elseif arg == "--max-age-days" then
            index = index + 1
            options.maxAgeDays = tonumber(argv[index])
            if not options.maxAgeDays then
                fail("--max-age-days requires a number")
            end
            if options.maxAgeDays < 0 or math.floor(options.maxAgeDays) ~= options.maxAgeDays then
                fail("--max-age-days must be a non-negative integer")
            end
        elseif arg == "--today" then
            index = index + 1
            options.today = argv[index]
            if not options.today then
                fail("--today requires YYYY-MM-DD")
            end
        elseif arg == "--path" then
            index = index + 1
            options.path = argv[index]
            if not options.path then
                fail("--path requires a path")
            end
        elseif string.sub(arg, 1, 2) == "--" then
            fail("unknown option: " .. arg)
        else
            options.path = arg
        end
        index = index + 1
    end
    return options
end

local options = parse_args(args)
if options.selfTest then
    run_self_test()
    return
end

local root = load_generated_file(options.path)
local text = read_file(options.path)
validate_snapshot(root, text, options)
if options.semanticLines then
    for _, line in ipairs(build_semantic_lines(root)) do
        io.write(line .. "\n")
    end
    return
end
io.write("Archon target snapshot check passed: " .. options.path .. "\n")
