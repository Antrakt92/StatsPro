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

local manifest
local locales = { "enUS", "deDE", "esES", "esMX", "frFR", "itIT", "ptBR", "ruRU", "koKR", "zhCN", "zhTW" }
for _, locale in ipairs(locales) do
    local env, media = library(locale)
    local default, global = media:GetDefault("font"), media:GetGlobal("font")
    local addon = {}
    loadIn(env, "StatsPro_Fonts.lua", addon)
    local fonts = addon.bundledFonts
    check(type(fonts) == "table" and #fonts == 12, locale .. ": complete bundled font collection")
    manifest = fonts
    local names, paths = {}, {}
    for _, font in ipairs(fonts) do
        check(not names[font.name] and not paths[font.path], "unique bundled name and path")
        names[font.name], paths[font.path] = true, true
        local file = assert(io.open(sourcePath(font.path), "rb"))
        local header = file:read(4)
        file:close()
        check(header == "\0\1\0\0" or header == "OTTO", "bundled font has a standalone TTF or OTF signature")
        local supported = locale ~= "koKR" and locale ~= "zhCN" and locale ~= "zhTW"
            and (locale ~= "ruRU" or font.cyrillic == true)
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
for _, forever in ipairs({ false, true }) do
    for _, locale in ipairs({ "enUS", "ruRU" }) do
        local env, addon, test = fixtures.loadStatsPro(locale, {
            forever = forever, bundledFonts = true, isKnownFontFile = exists,
            unitGUID = function() return "Player-BundledFontFixture" end,
            getSpecialization = function() return 1 end, specID = 73,
            specName = "Protection", specRole = "TANK", primaryStat = 1,
        })
        env.__fireEvent("PLAYER_ENTERING_WORLD")
        addon:OpenConfigMenu()
        local before = test.profileState()
        local selected
        for _, font in ipairs(addon.bundledFonts) do
            check(not test.fontSupports(font.path, "Hangul") and not test.fontSupports(font.path, "Hans")
                and not test.fontSupports(font.path, "Hant"), "bundled western fonts do not claim CJK coverage")
            check(test.fontSupports(font.path, "Cyrillic") == font.cyrillic,
                "runtime honors verified Cyrillic coverage: " .. font.name)
            if locale ~= "ruRU" or font.cyrillic then
                check(env.LibStub("LibSharedMedia-3.0"):HashTable("font")[font.name] == font.path,
                    "bundled font is available to shared runtime: " .. font.name)
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
print("StatsPro bundled fonts: PASS (" .. checks .. " checks)")
