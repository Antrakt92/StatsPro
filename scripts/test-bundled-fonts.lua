-- Validate bundled registration through the actual shared-media library, then
-- exercise selection and profile persistence through each client flavor.
local checks = 0
local function check(ok, message)
    checks = checks + 1
    assert(ok, message)
end

local function sourcePath(path)
    return (path:gsub("^Interface\\AddOns\\StatsPro\\", ""):gsub("\\", "/"))
end

local function exists(path)
    local file = io.open(sourcePath(path), "rb")
    if file then file:close(); return true end
    return false
end

-- Inspect the actual binary tables so catalog flags cannot promise missing glyphs.
local inspected = {}
local function inspectFont(path)
    if inspected[path] then return inspected[path] end
    local file = assert(io.open(sourcePath(path), "rb"))
    local data = file:read("*a")
    file:close()
    local function uint(offset, size)
        assert(offset >= 0 and offset + size <= #data, "font table stays within the file")
        local value = 0
        for index = offset + 1, offset + size do value = value * 256 + data:byte(index) end
        return value
    end
    local tables = {}
    for offset = 12, 12 + 16 * uint(4, 2) - 1, 16 do
        tables[data:sub(offset + 1, offset + 4)] = uint(offset + 8, 4)
    end
    check(not tables.fvar, "bundled fonts use static faces: " .. path)
    local cmap = assert(tables.cmap, "font includes a Unicode character map")
    local subtables = {}
    for offset = cmap + 4, cmap + 4 + 8 * uint(cmap + 2, 2) - 1, 8 do
        local platform, encoding = uint(offset, 2), uint(offset + 2, 2)
        if platform == 0 or (platform == 3 and (encoding == 1 or encoding == 10)) then
            subtables[cmap + uint(offset + 4, 4)] = true
        end
    end
    local function hasGlyph(codepoint)
        for base in pairs(subtables) do
            local format = uint(base, 2)
            if format == 4 and codepoint < 65536 then
                local count = uint(base + 6, 2) / 2
                local ends = base + 14
                local starts = ends + count * 2 + 2
                local deltas, ranges = starts + count * 2, starts + count * 4
                local low, high = 0, count - 1
                while low <= high do
                    local index = math.floor((low + high) / 2)
                    local first, last = uint(starts + index * 2, 2), uint(ends + index * 2, 2)
                    if codepoint < first then high = index - 1
                    elseif codepoint > last then low = index + 1
                    else
                        local delta, range = uint(deltas + index * 2, 2), uint(ranges + index * 2, 2)
                        local glyph = codepoint
                        if range ~= 0 then
                            glyph = uint(ranges + index * 2 + range + (codepoint - first) * 2, 2)
                            if glyph == 0 then break end
                        end
                        if (glyph + delta) % 65536 ~= 0 then return true end
                        break
                    end
                end
            elseif format == 12 then
                local low, high = 0, uint(base + 12, 4) - 1
                while low <= high do
                    local index = math.floor((low + high) / 2)
                    local offset = base + 16 + index * 12
                    local first, last = uint(offset, 4), uint(offset + 4, 4)
                    if codepoint < first then high = index - 1
                    elseif codepoint > last then low = index + 1
                    else
                        if uint(offset + 8, 4) + codepoint - first ~= 0 then return true end
                        break
                    end
                end
            end
        end
        return false
    end
    for codepoint = 32, 126 do check(hasGlyph(codepoint), "ASCII glyph coverage: " .. path) end
    local cyrillic = hasGlyph(0x401) and hasGlyph(0x451)
    for codepoint = 0x410, 0x44F do cyrillic = hasGlyph(codepoint) and cyrillic end
    inspected[path] = { cyrillic = cyrillic, hasGlyph = hasGlyph }
    return inspected[path]
end

local function supportsLocale(font, locale)
    local field = ({ ruRU = "cyrillic", zhCN = "hans", zhTW = "hant", koKR = "hangul" })[locale]
    if field then return font[field] == true end
    return font.latin ~= false
end

local function visibleLocale(font, locale)
    local supported = supportsLocale(font, locale)
    if font.latinLocales and locale ~= "ruRU" and locale ~= "zhCN" and locale ~= "zhTW" and locale ~= "koKR" then
        supported = font.latinLocales[locale] == true
    end
    if font.region then
        if locale == "zhCN" or locale == "zhTW" then supported = supported and font.region == locale
        elseif font.region == "zhTW" then supported = false end
    end
    return supported
end

local fixtures = assert(loadfile("scripts/smoke.lua"))("fixtures")
local snapshot = assert(loadfile("AntraktFontCatalog.lua"))()
local baseline = "Interface\\AddOns\\StatsPro\\fonts\\" .. snapshot.baseline.file
local codes = {}
local function collect(value)
    if type(value) == "table" then for _, child in pairs(value) do collect(child) end
    elseif type(value) == "string" then
        local index = 1
        while index <= #value do
            local code = value:byte(index)
            local count = code < 128 and 1 or code < 224 and 2 or code < 240 and 3 or 4
            if count > 1 then
                code = code % (2 ^ (7 - count))
                for offset = 1, count - 1 do code = code * 64 + value:byte(index + offset) % 64 end
            end
            if code >= 32 then codes[code] = true end
            index = index + count
        end
    end
end
for _, forever in ipairs({false, true}) do
    local _, _, test = fixtures.loadStatsPro("enUS", {forever=forever})
    collect(test.registrySnapshot().labelsByLocale)
end
collect(snapshot.messages)
for _, path in ipairs({"StatsPro.lua", "StatsPro_Forever.lua", "StatsPro_Fonts.lua", "StatsPro_FontsUI.lua", "AntraktFontCatalog.lua", "AntraktFontNotice.lua"}) do
    local file = assert(io.open(path, "rb"))
    collect(file:read("*a"))
    file:close()
end
for code in pairs(codes) do check(inspectFont(baseline).hasGlyph(code), "baseline covers actual UI codepoint " .. code) end
for code = 0xAC00, 0xD7A3 do check(inspectFont(baseline).hasGlyph(code), "baseline supports complete modern Hangul") end
check(inspectFont(baseline).cyrillic, "baseline supports the Russian alphabet")
local function selectLanguage(env, locale)
    local dropdown = env.StatsProLanguageDropdown
    dropdown.dropdownInit()
    for _, row in ipairs(dropdown.dropdownEntries) do
        if row.value == locale then row.func(); return end
    end
    error("missing language choice: " .. locale)
end
for _, forever in ipairs({ false, true }) do
    local env, addon, test = fixtures.loadStatsPro("enUS", {
        forever = forever, bundledFonts = true, isKnownFontFile = function() return true end,
        lsmFonts = { { name = "Unknown coverage", path = "Interface\\AddOns\\Media\\Opaque.ttf" } },
    })
    env.__fireEvent("PLAYER_ENTERING_WORLD")
    addon:OpenConfigMenu()
    local picker = addon.settingsUI.fontPicker
    local english = picker.BuildFontsList(addon)
    addon.settingsUI.localization.Preview(addon, "ruRU")
    check(picker.BuildFontsList(addon) == english, "hover does not change committed font choices")
    addon.settingsUI.localization.CancelPreview(addon)
    picker.Show(addon)
    for _, locale in ipairs({ "ruRU", "enUS", "deDE", "frFR", "esES", "esMX", "ptBR", "itIT", "koKR", "zhCN", "zhTW", "auto" }) do
        selectLanguage(env, locale)
        local active = locale == "auto" and "enUS" or locale
        local requirement = test.registrySnapshot().localeGlyphReq[active]
        local list = picker.BuildFontsList(addon)
        check(#list > 0, "a compatible font remains available: " .. locale)
        local names = {}
        for _, font in ipairs(list) do
            check(test.fontSupports(font.path, requirement, active), "only compatible fonts: " .. locale .. "/" .. font.name)
            check(not names[font.name], "no duplicate font names")
            names[font.name] = true
        end
        check(names["Unknown coverage"] == (requirement == "Latin" and true or nil),
            "unknown external coverage is conservative for non-Latin output")
        for _, font in ipairs(addon.bundledFonts) do
            local expected = visibleLocale(font, active)
            check((names[font.name] == true) == expected, "bundled language filtering: " .. locale .. "/" .. font.name)
        end
        for _, button in ipairs(picker.buttons) do
            if button:IsShown() then
                check(test.fontSupports(button.fontPath, requirement, active), "open picker refreshes after language commit")
            end
        end
    end
    selectLanguage(env, "ruRU")
    env.__registerLSMFont("Late Latin", "Fonts\\MORPHEUS.TTF")
    env.__registerLSMFont("Late Cyrillic", "Fonts\\ARIALN.TTF")
    env.__registerLSMFont("Bangers", "Fonts\\ARIALN.TTF")
    env.__flushTimers(0)
    local late = {}
    for _, font in ipairs(picker.BuildFontsList(addon)) do late[font.name] = font.path end
    check(not late["Late Latin"] and late["Late Cyrillic"] == "Fonts\\ARIALN.TTF",
        "late SharedMedia registrations retain output-language filtering")
    check(late.Bangers == "Fonts\\ARIALN.TTF", "external same-name face retains ownership")
    picker.Hide(addon)

    local russianEnv, russianAddon = fixtures.loadStatsPro("ruRU", {
        forever = forever, bundledFonts = true, statsProDB = { forceLocale = "enUS" },
        isKnownFontFile = function() return true end,
    })
    russianEnv.__fireEvent("PLAYER_ENTERING_WORLD")
    russianAddon:OpenConfigMenu()
    local function visible(name)
        for _, font in ipairs(russianAddon.settingsUI.fontPicker.BuildFontsList(russianAddon)) do
            if font.name == name then return true end
        end
        return false
    end
    check(visible("Bangers"), "English on a Russian client includes bundled Latin faces")
    selectLanguage(russianEnv, "auto")
    check(not visible("Bangers") and visible("PT Sans"), "Auto follows Russian client glyph requirements")
end
print("StatsPro bundled fonts: PASS (" .. checks .. " checks)")
