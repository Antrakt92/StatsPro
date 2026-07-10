---@meta

-- Minimal definitions for WoW globals that StatsPro intentionally reads through
-- _G before the client or a named frame guarantees their runtime presence.

---@class (exact) StatsProFontPickerFrame
---@field IsShown fun(self: StatsProFontPickerFrame): boolean
---@field Hide fun(self: StatsProFontPickerFrame)

---@class (exact) StatsProStaticPopupDefinition
---@field text string
---@field button1 string
---@field button2 string
---@field OnAccept fun()
---@field OnCancel fun()
---@field timeout number
---@field whileDead boolean
---@field hideOnEscape boolean
---@field exclusive boolean
---@field preferredIndex number

---@type string
CANCEL = ""

---@type table<string, StatsProStaticPopupDefinition>
StaticPopupDialogs = {}

---@param which string
---@return table?
function StaticPopup_Show(which, ...) end

function ReloadUI() end

---@param target any
---@param method string
---@param hook function
function hooksecurefunc(target, method, hook) end

---@param value any
---@return boolean
function issecrettable(value) return false end

---@param value any
---@return boolean
function issecretvalue(value) return false end

---@type StatsProFontPickerFrame?
StatsProFontPicker = nil

---@type table?
SwiftStatsDB = nil

---@type table?
SwiftStatsLocalDB = nil
