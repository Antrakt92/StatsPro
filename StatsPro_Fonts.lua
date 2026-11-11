-- Collection metadata is separate from each consumer's profile state.
local _, addon = ...
local snapshot = assert(addon.AntraktFontCatalog)
local shared = { status = 'provider-unavailable', snapshot = snapshot }
addon.sharedFonts = shared
shared.baseline = {}
for key, value in pairs(snapshot.baseline) do shared.baseline[key] = value end
shared.baseline.path = 'Interface\\AddOns\\StatsPro\\fonts\\' .. shared.baseline.file
local glyphs = { 'latin', 'cyrillic', 'hans', 'hant', 'hangul', 'japanese' }
local function clean(value, kind)
    local ok, result = pcall(function()
        return type(value) == kind and (type(_G.issecretvalue) ~= 'function' or not _G.issecretvalue(value))
    end)
    return ok and result == true
end
function shared.Key(value)
    if not clean(value, 'string') or #value > 1024 then return nil end
    return (value:gsub('/', '\\'):gsub('[A-Z]', string.lower))
end
local function plain(value)
    return clean(value, 'table') and getmetatable(value) == nil
end
local function text(value, limit)
    return clean(value, 'string') and #value > 0 and #value <= limit and not value:find('%c')
end
local function method(name)
    local api, value = rawget(_G, 'C_AddOns')
    if not clean(api, 'nil') and not plain(api) then return false, true end
    if plain(api) then value = rawget(api, name) end
    if not clean(value, 'nil') then return clean(value, 'function') and value or false, true end
    value = rawget(_G, name)
    if clean(value, 'nil') then return nil, false end
    return clean(value, 'function') and value or false, false
end
local function query(callback, ...)
    if not clean(callback, 'function') then return false end
    return pcall(callback, ...)
end
function shared.InstallationStatus()
    local existsMethod = method('DoesAddOnExist')
    local ok, exists = query(existsMethod, 'AntraktFonts')
    if existsMethod == nil then
        -- Indexed discovery avoids treating an echoed missing name as installation.
        local countMethod, infoMethod = method('GetNumAddOns'), method('GetAddOnInfo')
        local counted, count = query(countMethod)
        if counted and clean(count, 'number') and count >= 0 and count <= 1024 and count % 1 == 0 then
            ok, exists = true, false
            for index = 1, count do
                local found, name = query(infoMethod, index)
                if not found or not text(name, 256) then ok = false; break end
                if name == 'AntraktFonts' then exists = true; break end
            end
        end
    end
    if not ok or not clean(exists, 'boolean') then return 'provider-not-loaded' end
    if not exists then return 'provider-unavailable' end
    local loadedMethod = method('IsAddOnLoaded')
    local loadedOK, _, loaded = query(loadedMethod, 'AntraktFonts')
    if loadedOK and clean(loaded, 'boolean') and loaded then return 'provider-incompatible' end
    -- Default enable state covers all characters. Never infer current-character
    -- disablement without a clean, ephemeral character identifier.
    local guidOK, guid = query(rawget(_G, 'UnitGUID'), 'player')
    if not guidOK or not text(guid, 128) then return 'provider-not-loaded' end
    local enableMethod, modern = method('GetAddOnEnableState')
    local enabledOK, enabled
    if modern then enabledOK, enabled = query(enableMethod, 'AntraktFonts', guid)
    else enabledOK, enabled = query(enableMethod, guid, 'AntraktFonts') end
    if enabledOK and clean(enabled, 'number') and enabled == 0 then return 'provider-disabled' end
    return 'provider-not-loaded'
end
function shared.RefreshPackageState()
    if clean(shared.provider, 'nil') then shared.status = shared.InstallationStatus() end
end
local function currentEnableState()
    local guidOK, guid = query(rawget(_G, 'UnitGUID'), 'player')
    if not guidOK or not text(guid, 128) then return nil end
    local callback, modern = method('GetAddOnEnableState')
    local ok, state
    if modern then ok, state = query(callback, 'AntraktFonts', guid)
    else ok, state = query(callback, guid, 'AntraktFonts') end
    if ok and clean(state, 'number') and (state == 0 or state == 1 or state == 2) then return state, guid end
end
local function actionSafe()
    if addon.profileRuntime.ReadCombatState() ~= false then return false end
    local list = rawget(_G, 'AddonList')
    if clean(list, 'nil') then return true end
    local ok, shown = pcall(function() return list:IsShown() end)
    return ok and clean(shown, 'boolean') and not shown
end
local function requestReload()
    shared.Refresh()
    if shared.status ~= 'provider-not-loaded' then return false end
    local state = currentEnableState()
    if state ~= 1 and state ~= 2 then return false end
    local reload = rawget(_G, 'ReloadUI')
    if not clean(reload, 'function') or not actionSafe() then return false end
    return query(reload)
end
function shared.EnableProvider()
    if not actionSafe() then return 'blocked' end
    shared.Refresh()
    if shared.status ~= 'provider-disabled' then return 'blocked' end
    local save = method('SaveAddOns')
    if not clean(save, 'function') or not clean(rawget(_G, 'ReloadUI'), 'function') then return 'blocked' end
    local state, guid = currentEnableState()
    if state ~= 0 or not actionSafe() then return 'blocked' end
    local enabled = query(method('EnableAddOn'), 'AntraktFonts', guid)
    local after = currentEnableState()
    shared.Refresh()
    if not enabled or (after ~= 1 and after ~= 2) then
        shared.actionResult = 'failed'
        return 'failed'
    end
    if not actionSafe() or not query(save) then shared.actionResult = nil; return 'failed' end
    -- This explicit enable click also activates the ordinary addon by reloading.
    after = currentEnableState()
    shared.actionResult = (after == 1 or after == 2) and 'reload-required' or 'failed'
    if shared.actionResult == 'reload-required' and requestReload() then return 'reload-requested' end
    return shared.actionResult
end
function shared.ReloadProvider()
    if shared.actionResult ~= 'reload-required' or not actionSafe() then return false end
    shared.Refresh()
    if shared.status ~= 'provider-not-loaded' then return false end
    local state = currentEnableState()
    if state ~= 1 and state ~= 2 then return false end
    local reload = rawget(_G, 'ReloadUI')
    local save = method('SaveAddOns')
    if not clean(reload, 'function') or not actionSafe() or not query(save) then return false end
    return requestReload()
end
function shared.Refresh()
    local provider = rawget(_G, 'AntraktFonts')
    shared.provider, shared.revision = provider, nil
    shared.status = clean(provider, 'nil') and shared.InstallationStatus() or 'provider-unavailable'
    local active = {}
    local readOK = pcall(function()
    if provider ~= nil then
        shared.status = 'provider-incompatible'
        local ok, catalog = pcall(function()
            if not plain(provider) or type(rawget(provider, 'GetCatalog')) ~= 'function' then return nil end
            return provider.GetCatalog()
        end)
        if ok and catalog ~= nil and plain(catalog) and rawget(catalog, 'formatMajor') == 1
            and text(rawget(catalog, 'catalogRevision'), 64)
            and catalog.catalogRevision:match('^[a-f0-9]+$') and #catalog.catalogRevision == 64
            and plain(rawget(catalog, 'fonts')) then
            local fonts = assert(catalog.fonts)
            local valid = true
            local ids, files = { [shared.baseline.id] = true }, { [shared.baseline.file:lower()] = true }
            for index = 1, 257 do
                local record = rawget(fonts, index)
                if record == nil then break end
                if index > 256 or not plain(record) or not text(rawget(record, 'id'), 64)
                    or not record.id:match('^[a-z0-9][a-z0-9%-]*$') or ids[record.id]
                    or not text(rawget(record, 'file'), 128)
                    or not record.file:match('^[A-Za-z0-9_.%-]+%.[to][tt]f$')
                    or files[record.file:lower()] or not text(rawget(record, 'name'), 128)
                    or not text(rawget(record, 'sha256'), 64) or #record.sha256 ~= 64
                    or not record.sha256:match('^[a-f0-9]+$')
                    or rawget(record, 'path') ~= 'Interface\\AddOns\\AntraktFonts\\fonts\\' .. record.file then
                    valid = false; break
                end
                for _, field in ipairs(glyphs) do
                    if not clean(rawget(record, field), 'boolean') then valid = false end
                end
                if rawget(record, 'region') ~= nil and record.region ~= 'zhCN' and record.region ~= 'zhTW' then valid = false end
                if rawget(record, 'latinLocales') ~= nil then
                    if not plain(record.latinLocales) then valid = false
                    else
                        local count = 0
                        for locale, value in pairs(record.latinLocales) do
                            count = count + 1
                            if count > 7 or not clean(locale, 'string') or value ~= true
                                or not ({ enUS=true, deDE=true, esES=true, esMX=true, frFR=true, itIT=true, ptBR=true })[locale] then valid = false; break end
                        end
                    end
                end
                if not valid then break end
                ids[record.id], files[record.file:lower()] = true, true
                active[#active + 1] = record
            end
            local count = 0
            for key in pairs(fonts) do
                count = count + 1
                if count > 256 or not clean(key, 'number') or key % 1 ~= 0
                    or key < 1 or key > #active then valid = false; break end
            end
            if valid and #active > 0 then shared.status, shared.revision = 'available', catalog.catalogRevision
            else active = {} end
        end
    end
    end)
    if not readOK then shared.status = "provider-incompatible"; active = {} end
    shared.byPath, shared.byID = {}, {}
    for _, record in ipairs(snapshot.fonts) do
        shared.byID[record.id] = record
        shared.byPath[shared.Key(record.path)] = record
        for _, alias in ipairs(record.aliases) do shared.byPath[shared.Key(alias)] = record end
    end
    shared.activeByID = {}
    addon.bundledFonts = { shared.baseline }
    for _, record in ipairs(active) do
        shared.activeByID[record.id] = record
        shared.byID[record.id] = record
        shared.byPath[shared.Key(record.path)] = record
        addon.bundledFonts[#addon.bundledFonts + 1] = record
    end
    for path, record in pairs(shared.byPath) do
        shared.byPath[path] = shared.activeByID[record.id] or record
    end
    shared.byPath[shared.Key(shared.baseline.path)] = shared.baseline
    return shared.status
end
function shared.IsReference(path)
    local key = shared.Key(path)
    if not key or key:find("%c") or key:find("\\%.%.\\") then return false end
    return (key:sub(1, 6) == "fonts\\" or key:sub(1, 17) == "interface\\addons\\")
        and key:match("%.[to]tf$") ~= nil
end
function shared.Lookup(path)
    local key = shared.Key(path)
    return key and shared.byPath[key] or nil
end
function shared.Identity(path)
    local record = shared.Lookup(path)
    return record and ('owned:' .. record.id) or shared.Key(path)
end
function shared.Resolve(path)
    local record = shared.Lookup(path)
    if not record then return nil end
    if record == shared.baseline then return shared.baseline.path, record.name end
    local available = shared.activeByID[record.id]
    if available then return available.path, available.name end
    local legacy = path
    local key = shared.Key(path)
    if not key then return nil, record.name end
    for _, owner in ipairs({'StatsPro', 'DoYouNeedIt'}) do
        local prefix = 'Interface\\AddOns\\' .. owner .. '\\fonts\\'
        if key:sub(1, #prefix) == shared.Key(prefix) then legacy = prefix .. record.file; break end
    end
    local ok, known = pcall(function() return C_UIFileAsset.IsKnownFile(legacy) end)
    if ok and clean(known, 'boolean') and known == true then return legacy, record.name end
    return nil, record.name, shared.status == "available" and "asset-unavailable" or shared.status
end
function shared.Message(locale, key, value)
    local messages = snapshot.messages[locale] or snapshot.messages.enUS
    local message = messages[key] or snapshot.messages.enUS[key] or key
    if value ~= nil and clean(value, 'string') then return string.format(message, value) end
    return message
end
shared.Refresh()
