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

local function band(left, right)
    local result, weight = 0, 1
    while left > 0 and right > 0 do
        if left % 2 == 1 and right % 2 == 1 then result = result + weight end
        left, right, weight = math.floor(left / 2), math.floor(right / 2), weight * 2
    end
    return result
end

local function loadIn(env, path, addon)
    local chunk = assert(loadfile(path))
    setfenv(chunk, env)
    return chunk("StatsPro", addon)
end

local function library(locale, missing)
    local env = setmetatable({}, { __index = _G })
    env._G = env
    -- LSM deliberately reads getfenv(0), so keep it inside this client's sandbox.
    env.getfenv = function(level) if level == 0 then return env end; return getfenv(level) end
    env.GetLocale = function() return locale end
    env.strmatch = string.match
    env.bit = { band = band }
    env.securecallfunction = function(callback, ...) return callback(...) end
    env.C_UIFileAsset = { IsKnownFile = function(path) return not missing and exists(path) end }
    loadIn(env, "libs/LibStub/LibStub.lua")
    loadIn(env, "libs/CallbackHandler-1.0/CallbackHandler-1.0.lua")
    loadIn(env, "libs/LibSharedMedia-3.0/LibSharedMedia-3.0.lua")
    return env, env.LibStub("LibSharedMedia-3.0")
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

local manifest
local locales = { "enUS", "deDE", "esES", "esMX", "frFR", "itIT", "ptBR", "ruRU", "koKR", "zhCN", "zhTW" }
for _, locale in ipairs(locales) do
    local env, media = library(locale)
    local default, global = media:GetDefault("font"), media:GetGlobal("font")
    local addon = {}
    loadIn(env, "StatsPro_Fonts.lua", addon)
    local fonts = addon.bundledFonts
    check(type(fonts) == "table" and #fonts == 46, locale .. ": complete bundled font collection")
    manifest = fonts
    local names, paths = {}, {}
    for _, font in ipairs(fonts) do
        check(not names[font.name] and not paths[font.path], "unique bundled name and path")
        names[font.name], paths[font.path] = true, true
        local file = assert(io.open(sourcePath(font.path), "rb"))
        local header = file:read(4)
        file:close()
        check(header == "\0\1\0\0" or header == "OTTO", "bundled font has a standalone TTF or OTF signature")
        check(inspectFont(font.path).cyrillic == font.cyrillic,
            "binary Russian alphabet matches declared coverage: " .. font.name)
        local supported = supportsLocale(font, locale)
        check((media:HashTable("font")[font.name] == font.path) == supported,
            locale .. ": exact registration for " .. font.name)
    end
    check(media:GetDefault("font") == default, locale .. ": bundled fonts preserve library default")
    check(media:GetGlobal("font") == global, locale .. ": bundled fonts preserve global override")
    local registered = #media:List("font")
    loadIn(env, "StatsPro_Fonts.lua", addon)
    check(#media:List("font") == registered, locale .. ": repeat load is idempotent")
end

do
    local env, media = library("enUS")
    local first = manifest[1]
    local externalPath = manifest[2].path
    -- An earlier external registration owns its name even when its path differs.
    check(media:Register("font", first.name, externalPath, media.LOCALE_BIT_western), "external font registered")
    media:SetGlobal("font", first.name)
    local default = media:GetDefault("font")
    loadIn(env, "StatsPro_Fonts.lua", {})
    check(media:HashTable("font")[first.name] == externalPath, "external same-name font remains unchanged")
    check(media:GetGlobal("font") == first.name, "existing global override remains unchanged")
    check(media:GetDefault("font") == default, "external default remains unchanged")
end

do
    local env, media = library("enUS", true)
    loadIn(env, "StatsPro_Fonts.lua", {})
    for _, font in ipairs(manifest) do
        check(media:HashTable("font")[font.name] == nil, "missing asset is not advertised: " .. font.name)
    end
end

local fixtures = assert(loadfile("scripts/smoke.lua"))("fixtures")
local _, _, coverageTest = fixtures.loadStatsPro("enUS")
local required = { latin = {}, hans = {}, hant = {}, hangul = {}, japanese = {} }
local westernLocales = { enUS = {}, deDE = {}, esES = {}, esMX = {}, frFR = {}, itIT = {}, ptBR = {} }
local function collect(locale, value)
    if type(value) == "table" then for _, child in pairs(value) do collect(locale, child) end
    elseif type(value) == "string" then
        local index = 1
        while index <= #value do
            local code = value:byte(index)
            local count = code < 128 and 1 or code < 224 and 2 or code < 240 and 3 or 4
            if count > 1 then
                code = code % (2 ^ (7 - count))
                for offset = 1, count - 1 do code = code * 64 + value:byte(index + offset) % 64 end
            end
            if locale == "zhCN" and code >= 0x3400 and code <= 0x9FFF then required.hans[code] = true
            elseif locale == "zhTW" and code >= 0x3400 and code <= 0x9FFF then required.hant[code] = true
            elseif locale == "koKR" and code >= 0xAC00 and code <= 0xD7A3 then required.hangul[code] = true
            elseif locale ~= "ruRU" and locale ~= "zhCN" and locale ~= "zhTW" and locale ~= "koKR"
                and code >= 0xC0 and code <= 0x24F and code ~= 0xD7 and code ~= 0xF7 then
                required.latin[code] = true
                if westernLocales[locale] then westernLocales[locale][code] = true end
            end
            index = index + count
        end
    end
end
for locale, labels in pairs(coverageTest.registrySnapshot().labelsByLocale) do collect(locale, labels) end
for code = 32, 126 do required.latin[code] = true end
for code = 0x3041, 0x3093 do required.japanese[code] = true end
for code = 0x30A1, 0x30F6 do required.japanese[code] = true end
for _, font in ipairs(manifest) do
    if font.latinLocales then
        for locale, codes in pairs(westernLocales) do
            local supported = true
            for code in pairs(codes) do
                if not inspectFont(font.path).hasGlyph(code) then supported = false; break end
            end
            check(supported == (font.latinLocales[locale] == true), "partial western coverage matches actual translated accents: " .. font.name .. "/" .. locale)
        end
    end
    for field, codes in pairs(required) do
        local supported = true
        for code in pairs(codes) do
            if not inspectFont(font.path).hasGlyph(code) then supported = false; break end
        end
        local declared = field == "latin" and font.latin ~= false or font[field] == true
        check(supported == declared, "actual translated characters match declared " .. field .. ": " .. font.name)
    end
end
for _, forever in ipairs({ false, true }) do
    for _, locale in ipairs({ "enUS", "ruRU", "zhCN", "zhTW", "koKR" }) do
        local env, addon, test = fixtures.loadStatsPro(locale, {
            forever = forever, bundledFonts = true, isKnownFontFile = exists,
            unitGUID = function() return "Player-BundledFontFixture" end,
            getSpecialization = function() return 1 end, specID = 73,
            specName = "Protection", specRole = "TANK", primaryStat = 1,
        })
        env.__fireEvent("PLAYER_ENTERING_WORLD")
        addon:OpenConfigMenu()
        local before = test.profileState()
        local catalog = {}
        for _, entry in ipairs(addon.settingsUI.fontPicker.BuildFontsList(addon, true)) do
            catalog[entry.name] = entry.path
        end
        local selected
        for _, font in ipairs(addon.bundledFonts) do
            for requirement, field in pairs({ Hangul = "hangul", Hans = "hans", Hant = "hant", Cyrillic = "cyrillic" }) do
                check(test.fontSupports(font.path, requirement) == (font[field] == true),
                    "runtime honors verified script coverage: " .. font.name .. "/" .. requirement)
            end
            check(test.fontSupports(font.path, "Latin") == (font.latin ~= false), "verified western accent coverage")
            check((env.LibStub("LibSharedMedia-3.0"):HashTable("font")[font.name] == font.path) == supportsLocale(font, locale),
                "shared registry honors client language mask: " .. font.name)
            if visibleLocale(font, locale) then
                check(catalog[font.name] == font.path, "font appears in the picker: " .. font.name)
                check(addon.settingsUI.fontPicker.Pick(addon, font), "font selection succeeds: " .. font.name)
                check(test.panelFontState().mainAppliedFont == font.path, "HUD uses selected bundled font")
                check(test.profileState().settings.font == font.path, "profile saves selected bundled font")
                selected = font.path
            end
        end
        local after = test.profileState()
        check(before.root == after.root and before.settings == after.settings and before.profileID == after.profileID,
            "font selection preserves profile identities")
        local reloadEnv, _, reloadTest = fixtures.loadStatsPro(locale, {
            forever = forever, bundledFonts = true, isKnownFontFile = exists,
            unitGUID = function() return "Player-BundledFontFixture" end, statsProDB = env.StatsProDB,
            getSpecialization = function() return 1 end, specID = 73,
            specName = "Protection", specRole = "TANK", primaryStat = 1,
        })
        reloadEnv.__fireEvent("PLAYER_ENTERING_WORLD")
        check(reloadTest.profileState().settings.font == selected, "selected bundled font survives reload")
        check(reloadTest.panelFontState().mainAppliedFont == selected, "reloaded HUD reapplies bundled font")
    end
end
-- Filter by the committed output language, independently of the client locale.
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
