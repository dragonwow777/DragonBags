--[[
DragonBags - Consolidated Money and Gold Summary Module
Corrected version with guaranteed working click handler + debug tracing.
--]]

local addonName, addon = ...
local L = addon.L

------------------------------------------------------------
-- DEBUG TOGGLE
------------------------------------------------------------
local DEBUG = false

local function dbg(msg)
    if DEBUG then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ffcc[Money DEBUG]:|r "..tostring(msg))
    end
end

------------------------------------------------------------
-- GLOBALS
------------------------------------------------------------
local _G = _G
local CreateFrame = _G.CreateFrame
local GetMoney = _G.GetMoney
local floor = _G.math.floor
local GetMoneyString = _G.GetMoneyString
local GameTooltip = _G.GameTooltip
local RAID_CLASS_COLORS = _G.RAID_CLASS_COLORS
local GetRealmName = _G.GetRealmName
local UnitName = _G.UnitName
local UnitClass = _G.UnitClass
local UnitLevel = _G.UnitLevel
local type = _G.type 
local tinsert = _G.tinsert 
local tsort = _G.table.sort 
local DEFAULT_COLOR = {r=1, g=1, b=1}
local DEFAULT_CHAT_FRAME = _G.DEFAULT_CHAT_FRAME
local pcall = _G.pcall
local tostring = _G.tostring

------------------------------------------------------------
-- MODULE SETUP
------------------------------------------------------------
local mod = addon:NewModule('Money', 'AceEvent-3.0')
mod.uiName = L['Money Display']
mod.uiDesc = L['Displays character money with a multi-character gold summary tooltip.']

------------------------------------------------------------
-- MONEY FORMATTER
------------------------------------------------------------
local function FormatMoney(copper)
    if copper == 0 then
        return "|cffFFFFFF0|r|cffCD853Fc|r"
    end

    local gold = floor(copper / 10000)
    local silver = floor((copper % 10000) / 100)
    local copperVal = copper % 100
    
    local text = ""
    
    if gold > 0 then
        text = text .. "|cffFFFFFF" .. gold .. "|r|cffFFFF00g|r "
    end
    if silver > 0 or gold > 0 then
        text = text .. "|cffFFFFFF" .. silver .. "|r|cffC7C7CFs|r "
    end
    
    text = text .. "|cffFFFFFF" .. copperVal .. "|r|cffCD853Fc|r"
    
    return text
end

------------------------------------------------------------
-- DISPLAY UPDATE
------------------------------------------------------------
local function UpdateDisplay(self)
    if not self.text then return end
    self.text:SetText(FormatMoney(GetMoney()))
end

------------------------------------------------------------
-- MODULE ENABLE / DISABLE
------------------------------------------------------------
function mod:OnEnable()
    dbg("Money module enabled")

    addon:HookBagFrameCreation(self, 'OnBagFrameCreated')

    for _, bag in addon:IterateBags() do
        if bag:HasFrame() then
            self:OnBagFrameCreated(bag)
        end
    end

    self:RegisterEvent("PLAYER_MONEY", function() UpdateDisplay(mod) end)
end

function mod:OnDisable()
    dbg("Money module disabled")

    if self.container then
        self.container:Hide()
    end

    self:UnregisterEvent("PLAYER_MONEY")
end

------------------------------------------------------------
-- BAG FRAME CREATED
------------------------------------------------------------
function mod:OnBagFrameCreated(bag)
    if bag.bagName ~= "Backpack" then
        dbg("Skipping non-backpack bag: "..tostring(bag.bagName))
        return
    end

    local frame = bag:GetFrame()
    if not frame then
        dbg("Backpack frame missing")
        return
    end

    dbg("Creating Money widget")

    ------------------------------------------------------------
    -- 1. Container
    ------------------------------------------------------------
    local container = CreateFrame("Frame", addonName.."MoneyContainer", frame)
    container:SetSize(100, 20)
    container:EnableMouse(true)
    self.container = container

    ------------------------------------------------------------
    -- 2. Invisible click button (TOP LAYER)
    ------------------------------------------------------------
    local clickButton = CreateFrame("Button", addonName.."MoneyClickButton", container)
    clickButton:SetAllPoints(container)
    clickButton:SetFrameLevel(container:GetFrameLevel() + 1)
    clickButton:SetFrameStrata("HIGH")
    clickButton:SetAlpha(0)
    clickButton:EnableMouse(true)
    clickButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    ------------------------------------------------------------
    -- 3. Money text
    ------------------------------------------------------------
    local text = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("RIGHT", container, "RIGHT", 0, 0)
    text:SetJustifyH("RIGHT")
    self.text = text

    ------------------------------------------------------------
    -- 4. Attach to BottomRightRegion
    ------------------------------------------------------------
    frame:AddBottomWidget(container, "RIGHT", 50, 20)

    ------------------------------------------------------------
    -- 5. Initial display
    ------------------------------------------------------------
    UpdateDisplay(self)

    ------------------------------------------------------------
    -- 6. UPDATED CLICK HANDLER (FinanceUI Integration)
    ------------------------------------------------------------
    clickButton:SetScript("OnClick", function(selfBtn, button)
        dbg("Money button click detected")

        -- Look for the new UI module reference
        local UI_Mod = addon._FinanceUI
        
        if UI_Mod and UI_Mod.ToggleDisplay then
            dbg("Calling FinanceUI:ToggleDisplay()")
            UI_Mod:ToggleDisplay()
            _G.PlaySound("igMainMenuOpen")
        else
            -- Fallback: If UI is not loaded, try to find the module directly
            dbg("FinanceUI reference missing, trying module lookup")
            local financeModule = addon:GetModule("Finance", true)
            if financeModule and financeModule.SlashCommand then
                financeModule:SlashCommand()
            else
                _G.DEFAULT_CHAT_FRAME:AddMessage("|cffff4040[DragonBags Error]:|r Finance UI not found. Check load order.")
            end
        end
    end)

    dbg("Click handler successfully attached")

    ------------------------------------------------------------
    -- 7. Tooltip logic (unchanged)
    ------------------------------------------------------------
    clickButton:SetScript("OnEnter", function(selfFrame)
        GameTooltip:SetOwner(selfFrame, "ANCHOR_TOPRIGHT")
        GameTooltip:SetBackdropColor(0, 0, 0, 0.85)
        GameTooltip:AddLine(L["Gold Summary"], 1, 1, 1)

        local ok, err = pcall(function()

            local className, class = UnitClass("player")
            local currentColor = RAID_CLASS_COLORS[class] or DEFAULT_COLOR
            GameTooltip:AddDoubleLine(
                UnitName("player"),
                GetMoneyString(GetMoney()),
                currentColor.r, currentColor.g, currentColor.b,
                1, 1, 1
            )

            --------------------------------------------------------
            -- LEVEL SNAPSHOT LOGIC (unchanged)
            --------------------------------------------------------
            local financeModule = addon:GetModule("Finance", true)
            local history = financeModule and financeModule.db and financeModule.db.char and financeModule.db.char.level_snapshots
            local currentLevel = UnitLevel("player")
            local currentMoney = GetMoney()

            local function formatNet(value)
                local formattedMoney = GetMoneyString(value, true)
                local color = value >= 0 and "|cff20ff20" or "|cffff2020"
                return color .. formattedMoney .. "|r"
            end

            if history and currentLevel > 0 and history[currentLevel] then
                GameTooltip:AddLine(" ")

                local currentLevelSnapshot = history[currentLevel]
                local currentLevelGain = currentMoney - currentLevelSnapshot

                GameTooltip:AddDoubleLine(
                    L["Current Level"] or "Current Level:",
                    formatNet(currentLevelGain),
                    0.8, 0.8, 0.8,
                    1, 1, 1
                )

                local prevLevel = currentLevel - 1
                if prevLevel >= 1 and history[prevLevel] then
                    local prevLevelGain = currentLevelSnapshot - history[prevLevel]

                    GameTooltip:AddDoubleLine(
                        L["Previous Level"] or "Previous Level:",
                        formatNet(prevLevelGain),
                        0.8, 0.8, 0.8,
                        1, 1, 1
                    )
                end

                GameTooltip:AddLine(" ")
            end

            --------------------------------------------------------
            -- ALT GOLD SUMMARY (unchanged)
            --------------------------------------------------------
            local groupedAlts = {}
            local totalAltsFound = 0
            local fullCurrentPlayerKey = (UnitName("player") or "Unknown").." - "..(GetRealmName() or "Unknown")
            local seen = {}

            local function addChar(charKey, charData)
                if charKey ~= fullCurrentPlayerKey and type(charData) == "table" and type(charData.money) == "number" then
                    if not seen[charKey] then
                        local realmName = charKey:match("%- (.*)$") or "Unknown Realm"
                        groupedAlts[realmName] = groupedAlts[realmName] or {}
                        tinsert(groupedAlts[realmName], { key = charKey, data = charData })
                        totalAltsFound = totalAltsFound + 1
                        seen[charKey] = true
                    end
                end
            end

            if addon.db and addon.db.global and addon.db.global.characters then
                for k, v in pairs(addon.db.global.characters) do addChar(k, v) end
            end

            local sv = addon.db and addon.db.sv
            if sv and sv.realm then
                for realmName, rdata in pairs(sv.realm) do
                    local chars = rdata.characters
                    if type(chars) == "table" then
                        for k, v in pairs(chars) do addChar(k, v) end
                    end
                end
            end

            if addon.db and addon.db.global and addon.db.global.characters then
                for k, v in pairs(addon.db.global.characters) do addChar(k, v) end
            end

            if totalAltsFound > 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(L["All Other Characters:"], 1, 1, 1)

                local sortedRealmKeys = {}
                for realmKey in pairs(groupedAlts) do tinsert(sortedRealmKeys, realmKey) end
                tsort(sortedRealmKeys)

                for _, realmName in ipairs(sortedRealmKeys) do
                    local altsInGroup = groupedAlts[realmName]

                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("|cffFFD700<< "..realmName.." >>|r", 1, 1, 1)

                    tsort(altsInGroup, function(a, b) return a.key < b.key end)

                    for _, v in ipairs(altsInGroup) do
                        local altColor = RAID_CLASS_COLORS[v.data.class] or DEFAULT_COLOR
                        local displayName = v.key:match("^(.-) %-") or v.key

                        GameTooltip:AddDoubleLine(
                            "  "..displayName,
                            GetMoneyString(v.data.money),
                            altColor.r, altColor.g, altColor.b,
                            1, 1, 1
                        )
                    end
                end
            else
                if currentLevel <= 1 then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("--- No other characters found in saved data. ---", 1, 0, 0)
                end
            end
        end)

        GameTooltip:Show()

        if not ok then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cffff0000Tooltip Load Error: |cffFFFFFF"..tostring(err), 1, 0, 0)
            dbg("Tooltip error: "..tostring(err))
        end
    end)

    clickButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    dbg("Money widget fully initialized")
end
