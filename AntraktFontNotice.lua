-- Event-driven coordination; each participant owns its window and saved data.
-- Register(owner, {state, canShow, show, acknowledge, dismiss}) never opens UI.
-- show receives explicit-ack and suspension callbacks and returns actual visibility.
-- Visible hosts must supply programmatic dismiss/hide/cleanup; it must not ack.
-- Absent/throwing dismiss fails closed: ownership stays busy until host suspension.
-- RequestShow returns (shownOrBusy, owner), or false when deferred/acknowledged.
-- RequestInfo(owner) explicitly opens the registered host regardless of saved campaign state.
-- Host OnHide may suspend ownership; only explicit actions may acknowledge.
local _, namespace = ...
local module = { formatMajor = 1, campaign = "shared-fonts-move-v1" }
local isolated

local function cleanTrue(value)
    if type(value) ~= "boolean" then return false end
    local ok, result = pcall(function()
        if type(_G.issecretvalue) == "function" and _G.issecretvalue(value) then return false end
        return value == true
    end)
    return ok and result == true
end

local function callTrue(callback, ...)
    local ok, result = pcall(callback, ...)
    return ok and cleanTrue(result)
end

local function createCoordinator()
    local coordinator = { formatMajor = 1, campaign = module.campaign }
    local participants = {}
    local acknowledged = false
    local manualAcknowledged = {}
    local active
    local generation = 0
    local dispatching = false
    local acknowledging = false
    local dismissing = false

    local function owners()
        local result = {}
        for owner in pairs(participants) do result[#result + 1] = owner end
        table.sort(result)
        return result
    end

    local function release(token)
        if active ~= token then return false end
        active = nil
        generation = generation + 1
        return true
    end

    local function dismissPresentation()
        local token = active
        if not token then return end
        -- Invalidate callbacks before hiding: OnHide can synchronously reenter.
        release(token)
        dismissing = true
        local ok = false
        if token.entry.dismiss then ok = pcall(token.entry.dismiss) end
        dismissing = false
        -- A host that could not close stays busy until it releases its window.
        if not ok and not active then active = token end
    end

    local function persistAcknowledgement()
        if not acknowledged or acknowledging then return end
        acknowledging = true
        for _, owner in ipairs(owners()) do
            local entry = participants[owner]
            if (entry.state == nil or (entry.state == "fresh" and manualAcknowledged[owner]))
                and callTrue(entry.acknowledge) then
                -- A replaced registration must confirm its own current data.
                if participants[owner] == entry then entry.state = "acknowledged" end
            end
        end
        acknowledging = false
    end

    local function confirm(token)
        if active ~= token or token.generation ~= generation then return false end
        local entry = participants[token.owner]
        if entry ~= token.entry or (not token.manual and entry.state ~= nil) then return false end
        if token.opening then
            token.confirmPending = true
            return true
        end
        if token.manual and entry.state == "fresh" then manualAcknowledged[token.owner] = true end
        acknowledged = true
        release(token)
        persistAcknowledgement()
        return true
    end

    function coordinator:Register(owner, callbacks)
        if type(owner) ~= "string" or owner == "" or #owner > 128
            or type(callbacks) ~= "table" then return false end
        local state = rawget(callbacks, "state")
        if state ~= nil and state ~= "fresh" and state ~= "acknowledged" then return false end
        if type(rawget(callbacks, "canShow")) ~= "function"
            or type(rawget(callbacks, "show")) ~= "function"
            or type(rawget(callbacks, "acknowledge")) ~= "function"
            or (rawget(callbacks, "dismiss") ~= nil
                and type(rawget(callbacks, "dismiss")) ~= "function") then return false end
        participants[owner] = {
            state = state, canShow = callbacks.canShow,
            show = callbacks.show, acknowledge = callbacks.acknowledge,
            dismiss = callbacks.dismiss,
        }
        if state == "acknowledged" then acknowledged = true end
        if active and (active.owner == owner or state == "acknowledged") then dismissPresentation() end
        persistAcknowledgement()
        return true
    end

    local function present(owner, entry, manual)
        generation = generation + 1
        local token = { owner = owner, entry = entry, generation = generation, opening = true, manual = manual }
        active = token
        local shown = callTrue(entry.show,
            function() return confirm(token) end,
            function() return release(token) end)
        if active == token then
            token.opening = false
            if shown then
                if token.confirmPending then confirm(token) end
                return true, owner
            end
            dismissPresentation()
            if active then return true, active.owner end
        end
        return false
    end

    function coordinator:RequestInfo(owner)
        if type(owner) ~= "string" or owner == "" or #owner > 128 or not participants[owner] then return false end
        if dispatching or acknowledging or dismissing then return false end
        if active then return true, active.owner end
        local entry = participants[owner]
        dispatching = true
        local shown, host = false, nil
        if callTrue(entry.canShow) then shown, host = present(owner, entry, true) end
        dispatching = false
        return shown, host
    end

    function coordinator:RequestShow()
        if dispatching or acknowledging or dismissing then return false end
        dispatching = true
        persistAcknowledgement()
        if active then dispatching = false; return true, active.owner end
        if acknowledged then dispatching = false; return false end
        for _, owner in ipairs(owners()) do
            local entry = participants[owner]
            if entry.state == nil and callTrue(entry.canShow) then
                local shown, host = present(owner, entry, false)
                if shown then dispatching = false; return true, host end
                -- A real acknowledgement can arrive through a late registration.
                if acknowledged then dispatching = false; return false end
            end
        end
        dispatching = false
        return false
    end

    return coordinator
end

function module.GetCoordinator()
    local shared = rawget(_G, "AntraktFontNoticeCoordinator")
    if shared == nil then
        shared = createCoordinator()
        _G.AntraktFontNoticeCoordinator = shared
        return shared
    end
    local ok, compatible = pcall(function()
        return type(shared) == "table" and rawget(shared, "formatMajor") == 1
            and rawget(shared, "campaign") == module.campaign
            and type(rawget(shared, "Register")) == "function"
            and type(rawget(shared, "RequestShow")) == "function"
            and type(rawget(shared, "RequestInfo")) == "function"
    end)
    if ok and cleanTrue(compatible) then return shared end
    if not isolated then isolated = createCoordinator() end
    return isolated
end

if type(namespace) == "table" then namespace.AntraktFontNotice = module end
return module
