--[[
DragonBags - Vendor Interaction Module
Handles junk selling (button / auto) and auto-repair at vendors.
--]]

local addonName, addon = ...
local L = addon.L

--<GLOBALS
local _G = _G
local CanMerchantRepair = _G.CanMerchantRepair
local CreateFrame = _G.CreateFrame
local GetContainerItemID = _G.GetContainerItemID
local GetContainerItemInfo = _G.GetContainerItemInfo
local GetContainerItemLink = _G.GetContainerItemLink
local GetItemInfo = _G.GetItemInfo
local GetMoneyString = _G.GetMoneyString
local GetRepairAllCost = _G.GetRepairAllCost
local GameTooltip = _G.GameTooltip
local BACKPACK_CONTAINER = _G.BACKPACK_CONTAINER
local ITEM_QUALITY_POOR = _G.ITEM_QUALITY_POOR
local NUM_BAG_SLOTS = _G.NUM_BAG_SLOTS
local PlaySound = _G.PlaySound
local RepairAllItems = _G.RepairAllItems
local UseContainerItem = _G.UseContainerItem
--GLOBALS>

local mod = addon:NewModule('JunkSell', 'AceEvent-3.0')
mod.uiName = L['JUNK Sell Button']
mod.uiDesc = L['Displays the JUNK button for selling grey items.']

local ROW_WIDTH_SHRINK_THRESHOLD = 8

-- Returns true if the item has been manually dragged to a non-Junk section.
-- DragonBags stores filter overrides as "SectionName#CategoryName".
-- If that key exists and doesn't reference the Junk section, the player
-- has intentionally kept the item — skip it when selling.
local function IsProtectedByOverride(itemId)
    local foMod = addon:GetModule("FilterOverride", true)
    if not foMod or not foMod.db then return false end
    local key = foMod.db.profile.overrides[itemId]
    if not key then return false end
    -- key contains "Junk" → player explicitly put it in Junk → not protected
    return not key:find("Junk", 1, true)
end

-- Sell all grey items. Skips items manually moved to a non-Junk section.
local function SellAllJunk()
    local v = 0
    for b = BACKPACK_CONTAINER, NUM_BAG_SLOTS do
        for s = GetContainerNumSlots(b), 1, -1 do
            local l = GetContainerItemLink(b, s)
            if l then
                local _, _, q, _, _, _, _, _, _, _, p = GetItemInfo(l)
                if q == ITEM_QUALITY_POOR and p and p > 0 then
                    local itemId = GetContainerItemID(b, s)
                    if not IsProtectedByOverride(itemId) then
                        local _, c = GetContainerItemInfo(b, s)
                        v = v + (p * (c or 1))
                        UseContainerItem(b, s)
                    end
                end
            end
        end
    end
    if v > 0 then
        print(L["Sold junk for:"] .. " " .. GetMoneyString(v))
    end
end

-- Single MERCHANT_SHOW handler for both auto-repair and auto-sell.
function mod:OnMerchantShow()
    if addon.db.profile.autoRepair and CanMerchantRepair() then
        local cost = GetRepairAllCost()
        if cost and cost > 0 then
            RepairAllItems()
            print(L["Repaired all items for:"] .. " " .. GetMoneyString(cost))
        end
    end
    if (addon.db.profile.junkMode or "button") == "auto" then
        SellAllJunk()
    end
end

-- Register or unregister MERCHANT_SHOW based on current settings.
function mod:ApplyMode()
    local mode = addon.db.profile.junkMode or "button"
    local autoRepair = addon.db.profile.autoRepair

    if self.button then
        if mode == "button" then
            self.button:Show()
            self:UpdateJunkButtonLayout()
            self:UpdateJunkButtonState()
        else
            self.button:Hide()
        end
    end

    if mode == "auto" or autoRepair then
        self:RegisterEvent("MERCHANT_SHOW", "OnMerchantShow")
    else
        self:UnregisterEvent("MERCHANT_SHOW")
    end
end

function mod:UpdateJunkButtonLayout()
    if not self.button or not self.button:IsShown() then return end
    local currentWidthSetting = addon.db.profile.rowWidth.Backpack or 9
    if currentWidthSetting < ROW_WIDTH_SHRINK_THRESHOLD then
        self.button:SetText("|cffC7C7CFJ|r")
        self.button:SetWidth(20)
    else
        self.button:SetText("|cffC7C7CFJUNK|r")
        self.button:SetWidth(40)
    end
end

function mod:UpdateJunkButtonState()
    if not self.button then return end

    local totalValue = 0
    for bag = BACKPACK_CONTAINER, NUM_BAG_SLOTS do
        for slot = GetContainerNumSlots(bag), 1, -1 do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local _, _, quality, _, _, _, _, _, _, _, vendorPrice = GetItemInfo(link)
                if quality == ITEM_QUALITY_POOR and vendorPrice and vendorPrice > 0 then
                    local _, count = GetContainerItemInfo(bag, slot)
                    totalValue = totalValue + (vendorPrice * (count or 1))
                end
            end
        end
    end

    self.totalJunkValue = totalValue

    if totalValue > 0 then
        self.button:Enable()
    else
        self.button:Disable()
    end
end

function mod:OnEnable()
    addon:HookBagFrameCreation(self, 'OnBagFrameCreated')
    for _, bag in addon:IterateBags() do
        if bag:HasFrame() then
            self:OnBagFrameCreated(bag)
        end
    end
    self:RegisterMessage("DragonBags_PostContentUpdate", "UpdateJunkButtonState")
    self:RegisterMessage('DragonBags_LayoutChanged', 'UpdateJunkButtonLayout')
    self:ApplyMode()
end

function mod:OnDisable()
    if self.button then
        self.button:Hide()
    end
    self:UnregisterEvent("MERCHANT_SHOW")
    self:UnregisterMessage('DragonBags_LayoutChanged')
end

function mod:OnBagFrameCreated(bag)
    if bag.bagName ~= "Backpack" then return end
    if self.button then
        self:ApplyMode()
        return
    end

    local frame = bag:GetFrame()

    local button = CreateFrame("Button", addonName.."JunkSellButton", frame, "UIPanelButtonTemplate")
    button:SetSize(40, 20)
    button:SetText("|cffC7C7CFJUNK|r")
    button:SetNormalFontObject("GameFontNormalSmall")
    button:SetDisabledFontObject("GameFontDisableSmall")
    button:Hide()  -- ApplyMode will show it if mode == "button"
    self.button = button

    frame:AddBottomWidget(button, "RIGHT", 30, 20)

    button:SetScript("OnClick", function()
        PlaySound("igMainMenuOptionCheckBoxOn")
        SellAllJunk()
    end)
    button:SetScript("OnEnter", function(f)
        GameTooltip:SetOwner(f, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine(L["Sell Junk"], 1, 1, 1)
        GameTooltip:AddLine(L["Click to sell all junk (grey) items."], 0.8, 0.8, 0.8)
        if self.totalJunkValue and self.totalJunkValue > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine(L["Total Junk Value:"], GetMoneyString(self.totalJunkValue), 0.6, 0.6, 0.6, 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    self:UpdateJunkButtonLayout()
    self:UpdateJunkButtonState()
    -- Show or hide based on the current mode now that the button exists.
    -- ApplyMode() in OnEnable() only runs before the frame is created;
    -- this call covers the case where the frame is created after OnEnable().
    self:ApplyMode()
end

function mod:GetOptions()
    return {
        autoRepair = {
            name  = L["Auto-repair at vendor"],
            desc  = L["Automatically repair all items when visiting a vendor that can repair."],
            type  = "toggle",
            order = 10,
            get   = function() return addon.db.profile.autoRepair end,
            set   = function(_, value)
                addon.db.profile.autoRepair = value
                if mod:IsEnabled() then mod:ApplyMode() end
            end,
        },
        junkMode = {
            name  = L["Junk selling mode"],
            type  = "select",
            order = 20,
            values = {
                none   = L["Nothing"],
                button = L["Sell Junk button"],
                auto   = L["Auto-sell on vendor"],
            },
            get = function() return addon.db.profile.junkMode end,
            set = function(_, value)
                addon.db.profile.junkMode = value
                if mod:IsEnabled() then mod:ApplyMode() end
            end,
        },
    }
end
