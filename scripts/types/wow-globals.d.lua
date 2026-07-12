---@meta

-- Minimal definitions for WoW globals that StatsPro intentionally reads through
-- _G before the client or a named frame guarantees their runtime presence.

---@class (exact) StatsProFontPickerFrame
---@field IsShown fun(self: StatsProFontPickerFrame): boolean
---@field Hide fun(self: StatsProFontPickerFrame)

---@class (exact) StatsProDropdownFrame
---@field GetName fun(self: StatsProDropdownFrame): string?

---@class (exact) StatsProTargetSnapshotDropdownOption
---@field value "mythicPlus"|"raid"
---@field label string

---@class (exact) StatsProStaticPopupEditBox
---@field SetText fun(self: StatsProStaticPopupEditBox, text: string)
---@field GetText fun(self: StatsProStaticPopupEditBox): string
---@field HighlightText fun(self: StatsProStaticPopupEditBox)
---@field SetFocus fun(self: StatsProStaticPopupEditBox)
---@field GetParent fun(self: StatsProStaticPopupEditBox): StatsProStaticPopupDialog

---@class (exact) StatsProStaticPopupDialog
---@field Hide fun(self: StatsProStaticPopupDialog)
---@field GetEditBox fun(self: StatsProStaticPopupDialog): StatsProStaticPopupEditBox

---@class (exact) StatsProStaticPopupDefinition
---@field text string
---@field button1 string
---@field button2? string
---@field OnAccept? fun()
---@field OnCancel? fun()
---@field hasEditBox? boolean
---@field editBoxWidth? number
---@field OnShow? fun(self: StatsProStaticPopupDialog, data: any)
---@field EditBoxOnEnterPressed? fun(editBox: StatsProStaticPopupEditBox)
---@field EditBoxOnEscapePressed? fun(editBox: StatsProStaticPopupEditBox)
---@field timeout number
---@field whileDead boolean
---@field hideOnEscape boolean
---@field exclusive? boolean
---@field preferredIndex number

---@type string
CANCEL = ""

---@type number
MAX_SPELL_SCHOOLS = 7

---@type table<string, StatsProStaticPopupDefinition>
StaticPopupDialogs = {}

---@param which string
---@return table?
function StaticPopup_Show(which, ...) end

---@param which string
function StaticPopup_Hide(which) end

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

---@type StatsProDropdownFrame?
UIDROPDOWNMENU_OPEN_MENU = nil

---@type StatsProTargetSnapshotDropdownOption[]
StatsProTargetSnapshotDropdownOptions = {}

---@return string
function StatsProGetTargetSnapshotDropdownValue() return "" end

---@param value string
---@param option StatsProTargetSnapshotDropdownOption
---@param dropdown StatsProDropdownFrame
---@return boolean?
function StatsProSelectTargetSnapshotDropdownValue(value, option, dropdown) end

---@type table?
SwiftStatsDB = nil

---@type table?
SwiftStatsLocalDB = nil

---@type boolean?
__STATSPRO_ARCHON_TARGETS_MODULE = nil
