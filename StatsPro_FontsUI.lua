-- Consumer-owned UI and persistence; the shared coordinator never writes this DB.
local _, addon = ...
local shared = addon.sharedFonts
local function locale()
    local account = addon.dbRuntime.GetAccount()
    local chosen = account and account.forceLocale
    return shared.snapshot.messages[chosen] and chosen or GetLocale()
end
local function message(key, value) return shared.Message(locale(), key, value) end
local function packageKey(body)
    if shared.status == 'available' then return 'ready' end
    if shared.status == 'provider-disabled' then return shared.actionResult == 'failed' and 'enableFailed' or 'disabled' end
    if shared.status == 'provider-not-loaded' then return shared.actionResult == 'reload-required' and 'reloadRequired' or 'notLoaded' end
    if shared.status == 'provider-incompatible' then return 'incompatible' end
    return body and 'missing' or 'settingsMissing'
end
local function visible(frame)
    if not frame then return false end
    local method = frame.IsVisible or frame.IsShown
    local ok, shown = pcall(method, frame)
    return ok and shown == true
end
function shared.Guidance()
    local guidance = shared.status ~= 'available' and message(packageKey()) or nil
    local preferred = addon.fontRuntime.preferredPath()
    local record = shared.Lookup(preferred)
    if record and record ~= shared.baseline then
        local usable = addon.fontRuntime.usablePath(preferred)
        if not usable then
            if shared.status == 'available' then return message('assetUnavailable') .. ' ' .. record.name, true end
            return guidance .. '\n' .. message('selectedMissing', record.name), true
        end
    end
    if guidance then return guidance, shared.status == 'provider-incompatible' end
    return nil, false
end
function shared.UpdateGuidance()
    local marker = shared.marker
    if not marker then return end
    local text, warning = shared.Guidance()
    marker.statsProSharedFontText = text
    if text then
        marker:SetText(warning and '!' or 'i')
        marker:Show()
    else marker:Hide() end
end
function shared.CopyLink(confirm)
    if shared.status == 'provider-disabled' or shared.status == 'provider-not-loaded' then return false end
    local links = shared.snapshot.links
    local url = links.curseforge or links.wago or links.github
    if type(url) ~= 'string' or addon.profileRuntime.ReadCombatState() ~= false then return false end
    addon.developerLinks.sharedFonts = { label = message('copyTitle'), url = url, key = 'sharedFonts' }
    local shown, dialog = addon.developerLinks.Show('sharedFonts')
    local function failedCopy()
        pcall(_G.StaticPopup_Hide, addon.developerLinks.popupKey)
        return false
    end
    if not shown or not visible(dialog) then return failedCopy() end
    local ok, editBox = pcall(dialog.GetEditBox, dialog)
    if not ok or not editBox or not visible(editBox) then return failedCopy() end
    if confirm then confirm() end
    shared.HideNotice()
    return true
end
function shared.HideNotice()
    if shared.notice then shared.notice:Hide() end
end
function shared.UpdateNoticeAction()
    local frame = shared.notice
    if not frame or not frame.sharedFontsReady then return end
    frame.body:SetText(message(packageKey(true)))
    local links = shared.snapshot.links
    local hasLink = links.curseforge or links.wago or links.github
    frame.action = nil
    if shared.status == 'provider-disabled' then
        frame.action = 'enable'
    elseif shared.status == 'provider-not-loaded' and shared.actionResult == 'reload-required' then
        frame.action = 'reload'
    end
    if frame.action then
        frame.copy:SetText(message(frame.action))
        frame.copy:Show()
        frame.copy:Enable()
    elseif shared.status == 'provider-not-loaded' then
        frame.copy:Hide()
        frame.copy:Disable()
    else
        frame.action = 'copy'
        frame.copy:SetText(message(hasLink and 'copyLink' or 'linkUnavailable'))
        frame.copy:Show()
        if hasLink then frame.copy:Enable() else frame.copy:Disable() end
    end
end
function shared.ShowNotice(confirm, suspend)
    local frame = shared.notice
    if frame and not frame.sharedFontsReady then frame:Hide(); shared.notice = nil; frame = nil end
    if not frame then
        frame = CreateFrame('Frame', 'StatsProSharedFontsNotice', UIParent, 'BackdropTemplate')
        shared.notice = frame
        frame:Hide()
        frame:SetSize(480, 280)
        frame:SetPoint('CENTER')
        frame:SetFrameStrata('DIALOG')
        frame:EnableMouse(true)
        frame:SetClampedToScreen(true)
        addon.settingsDesign.ApplySurface(frame, 'window')
        local title = frame:CreateFontString(nil, 'OVERLAY')
        addon.settingsDesign.ApplyTextRole(title, 'title')
        title:SetPoint('TOPLEFT', 22, -20)
        title:SetPoint('TOPRIGHT', -22, -20)
        title:SetJustifyH('LEFT')
        frame.title = title
        local body = frame:CreateFontString(nil, 'OVERLAY')
        addon.settingsDesign.ApplyTextRole(body, 'body')
        body:SetPoint('TOPLEFT', 22, -58)
        body:SetSize(436, 150)
        body:SetJustifyH('LEFT')
        body:SetJustifyV('TOP')
        body:SetWordWrap(true)
        frame.body = body
        local close = addon.settingsDesign.CreateShellButton(frame, nil, 'primary')
        close:SetPoint('BOTTOMRIGHT', -22, 20)
        close:SetSize(120, 28)
        close:SetScript('OnClick', function()
            if frame.confirm then frame.confirm() end
            frame:Hide()
        end)
        frame.close = close
        local x = CreateFrame('Button', nil, frame, 'UIPanelCloseButton')
        x:SetPoint('TOPRIGHT', -12, -12)
        addon.settingsDesign.StyleCloseButton(x)
        x:SetScript('OnClick', function()
            if frame.confirm then frame.confirm() end
            frame:Hide()
        end)
        frame.x = x
        local copy = addon.settingsDesign.CreateShellButton(frame, nil, 'field')
        copy:SetPoint('BOTTOMLEFT', 22, 20)
        copy:SetSize(240, 28)
        copy:SetScript('OnClick', function()
            if not visible(frame) or not visible(copy) then return end
            local action = frame.action
            if action == 'enable' then
                local result = shared.EnableProvider()
                shared.UpdateGuidance()
                if result == 'available' then shared.HideNotice()
                else shared.UpdateNoticeAction() end
            elseif action == 'reload' then
                shared.ReloadProvider()
                shared.UpdateGuidance()
                shared.UpdateNoticeAction()
            elseif action == 'copy' then shared.CopyLink(frame.confirm) end
        end)
        frame.copy = copy
        frame:SetScript('OnHide', function()
            _G.AntraktWindowLayers.Unregister(frame)
            if frame.suspend then frame.suspend() end
        end)
        frame:SetScript('OnMouseDown', function() _G.AntraktWindowLayers.Focus(frame) end)
        frame:SetPropagateKeyboardInput(true)
        frame:EnableKeyboard(true)
        frame:SetScript('OnKeyDown', function(_, key)
            if key == 'ESCAPE' and addon.profileRuntime.ReadCombatState() == false then
                frame:SetPropagateKeyboardInput(false)
                if frame.confirm then frame.confirm() end
                frame:Hide()
            else frame:SetPropagateKeyboardInput(true) end
        end)
    end
    frame.sharedFontsReady = true
    frame.confirm, frame.suspend = confirm, suspend
    frame.title:SetText(message('title'))
    frame.body:SetText(message(packageKey(true)))
    frame.close:SetText(message('gotIt'))
    shared.UpdateNoticeAction()
    frame:SetPropagateKeyboardInput(true)
    _G.AntraktWindowLayers.Register(frame)
    frame:Show()
    _G.AntraktWindowLayers.Focus(frame)
    return visible(frame)
end
function shared.RefreshNoticeState()
    if not shared.noticeCallbacks then return end
    local account = addon.dbRuntime.GetAccount()
    local state = account and account.sharedFontsNotice
    if state == nil and shared.status == 'available'
        and addon.profileRuntime.ReadCombatState() == false then
        local root = addon.dbRuntime.GetWritableRoot(false)
        if root then root.account.sharedFontsNotice = 'satisfied'; state = 'satisfied' end
    end
    -- Ready is a per-consumer resolution, never acknowledgement of another host.
    local runtimeState = state == 'satisfied' and 'fresh' or state
    if runtimeState == nil and shared.status == 'available' then runtimeState = 'fresh' end
    if not shared.noticeRegistered or shared.registeredNoticeState ~= runtimeState then
        shared.noticeCallbacks.state = runtimeState
        if shared.coordinator:Register('StatsPro', shared.noticeCallbacks) then
            shared.noticeRegistered = true
            shared.registeredNoticeState = runtimeState
        end
    end
end
function shared.RequestNotice()
    if not shared.noticeInitialized or (addon.__statsproSmoke and not addon.__testSharedFontsNoticeEnabled) then return end
    shared.RefreshNoticeState()
    shared.coordinator:RequestShow()
end
function shared.PersistAcknowledgement()
    local root = addon.dbRuntime.GetWritableRoot(false)
    if not root or addon.profileRuntime.ReadCombatState() ~= false then return false end
    root.account.sharedFontsNotice = "acknowledged"
    return true
end
function shared.InitializeNotice()
    shared.noticeInitialized = true
    shared.coordinator = addon.AntraktFontNotice.GetCoordinator()
    shared.noticeRegistered = false
    shared.noticeCallbacks = {
        canShow = function()
            if addon.profileRuntime.ReadCombatState() ~= false then return false end
            if not shared.manualRequest and (shared.status == 'available'
                or not addon.dbRuntime.GetWritableRoot(false)) then return false end
            shared.noticeHooks = shared.noticeHooks or {}
            local surfaces = { welcome=addon.hudPresets.welcome,
                settings=not shared.manualRequest and addon.settingsUI.frame or nil,
                manager=addon.profileUI.manager, operation=addon.profileUI.operationDialog }
            for index = 1, 4 do surfaces['popup' .. index] = rawget(_G, 'StaticPopup' .. index) end
            for _, surface in pairs(surfaces) do
                if not shared.noticeHooks[surface] then
                    shared.noticeHooks[surface] = true
                    surface:HookScript('OnHide', function() C_Timer.After(0, shared.RequestNotice) end)
                end
                if visible(surface) then return false end
            end
            if addon.profileRuntime.transitioning then return false end
            return true
        end,
        show = shared.ShowNotice,
        acknowledge = shared.PersistAcknowledgement,
        dismiss = shared.HideNotice,
    }
    shared.RefreshNoticeState()
    if not addon.__statsproSmoke or addon.__testSharedFontsNoticeEnabled then
        C_Timer.After(0.6, function() shared.RequestNotice() end)
    end
end
function shared.AttachGuidance(dropdown)
    local marker = addon.settingsDesign.CreateShellButton(dropdown, nil, 'field')
    marker:SetPoint('LEFT', dropdown, 'RIGHT', 4, 0)
    marker:SetSize(24, 24)
    marker:SetScript('OnClick', function()
        if addon.profileRuntime.ReadCombatState() ~= false then return end
        if not shared.coordinator or type(shared.coordinator.RequestInfo) ~= 'function' then return end
        local previous = shared.manualRequest
        shared.manualRequest = true
        pcall(shared.coordinator.RequestInfo, shared.coordinator, 'StatsPro')
        shared.manualRequest = previous
    end)
    marker.statsProTooltipProvider = function(control) return control.statsProSharedFontText end
    addon.settingsDesign.AttachTooltip(marker, marker.statsProTooltipProvider)
    shared.marker = marker
    shared.UpdateGuidance()
    dropdown:HookScript('OnHide', function() shared.RequestNotice() end)
end
