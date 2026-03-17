--[[
DragonBags - AltViewer module (retired UI, utility functions kept)

The ALT button and popup viewer have been replaced by the character dropdown that
floats above the Backpack frame (see modules/Bank.lua).  This module is kept
registered in addon options so existing saved settings don't error, but all UI
creation code has been removed.

The two realm-character utility functions are kept here because they are shared
across the codebase.
--]]

local addonName, addon = ...
local L = addon.L or setmetatable({}, { __index = function(t,k) return k end })

------------------------------------------------------------
-- Blizzard API locals
------------------------------------------------------------
local _G = _G
local GetRealmName = _G.GetRealmName
local UnitName     = _G.UnitName

------------------------------------------------------------
-- Module setup
------------------------------------------------------------
local mod = addon:NewModule("AltViewer", "AceEvent-3.0", "AceTimer-3.0")
mod.uiName = L["Alt Inventory"]

------------------------------------------------------------
-- Shared realm-character utilities
-- (used by Bank.lua's character dropdown)
------------------------------------------------------------

function mod.GetRealmCharacters()
    local list, realm = {}, GetRealmName()
    local me = UnitName("player")
    local chars = (addon.db and addon.db.global and addon.db.global.characters) or {}
    for key, data in _G.pairs(chars) do
        local name, r = key:match("^(.-) %- (.+)$")
        if r == realm and name and name ~= me then
            _G.table.insert(list, { key = key, name = name, class = data.class })
        end
    end
    _G.table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- Returns the key of the first saved character on this realm (any character,
-- including the logged-in player).  Used as a fallback when no alt is selected.
function mod.FirstCharOnRealmKey()
    local realm = GetRealmName()
    local chars = (addon.db and addon.db.global and addon.db.global.characters) or {}
    for key, _ in _G.pairs(chars) do
        local _, r = key:match("^(.-) %- (.+)$")
        if r == realm then return key end
    end
end

------------------------------------------------------------
-- Module lifecycle (no-ops — UI retired)
------------------------------------------------------------

function mod:OnEnable()  end
function mod:OnDisable() end
