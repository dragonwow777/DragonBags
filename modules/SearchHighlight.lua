--[[
DragonBags - Adirelle's bag addon.
Copyright 2010-2011 Adirelle (adirelle@tagada-team.net)
All rights reserved.
--]]

if select(4, GetBuildInfo()) == 40300 then
	-- Client 4.3: integrated search box
	return
end

local addonName, addon = ...
local L = addon.L

--<GLOBALS
local _G = _G
local CreateFrame = _G.CreateFrame
local GetItemInfo = _G.GetItemInfo
--GLOBALS>

local mod = addon:NewModule('SearchHighlight', 'AceEvent-3.0')
mod.uiName = L['Item search']
mod.uiDesc = L['Provides a text widget at bottom of the backpack where you can type (part of) an item name to locate it in your bags.']

local ROW_WIDTH_SHRINK_THRESHOLD_NARROW = 6 -- Shrinks to 60px if rowWidth is 6 or less
local ROW_WIDTH_SHRINK_THRESHOLD_MEDIUM = 8 -- Shrinks to 80px if rowWidth is 8 or less

local MINIMAL_SEARCH_WIDTH = 60
local MEDIUM_SEARCH_WIDTH = 80
local NORMAL_SEARCH_WIDTH = 100


function mod:UpdateSearchLayout()
    if not self.widget then return end
    
    -- Read the current "buttons per row" setting for the Backpack (or default to 9)
    local currentWidthSetting = addon.db.profile.rowWidth.Backpack or 9
    
    local newWidth = NORMAL_SEARCH_WIDTH
    
    if currentWidthSetting <= ROW_WIDTH_SHRINK_THRESHOLD_NARROW then
        -- Narrowest Mode (6 columns or less)
        newWidth = MINIMAL_SEARCH_WIDTH
    elseif currentWidthSetting <= ROW_WIDTH_SHRINK_THRESHOLD_MEDIUM then
        -- Medium Mode (7 columns)
        newWidth = MEDIUM_SEARCH_WIDTH
    else
        -- Wide Mode (8 columns or more)
        newWidth = NORMAL_SEARCH_WIDTH
    end

    self.widget:SetWidth(newWidth)
        
end

function mod:OnEnable()
	addon:HookBagFrameCreation(self, 'OnBagFrameCreated')
	if self.widget then
		self.widget:Show()
		self:SendMessage('DragonBags_UpdateAllButtons')
	end
	self:RegisterMessage('DragonBags_UpdateButton', 'UpdateButton')
	self:RegisterMessage('DragonBags_UpdateLock', 'UpdateButton')
	self:RegisterMessage('DragonBags_UpdateBorder', 'UpdateButton')
	
    -- New: Register for layout updates
    self:RegisterMessage('DragonBags_LayoutChanged', 'UpdateSearchLayout') 
    self:UpdateSearchLayout() -- Set initial state on enable
end

function mod:OnDisable()
	if self.widget then
		self.widget:Hide()
		self:SendMessage('DragonBags_UpdateAllButtons')
	end
	-- New: Unregister the layout message
    self:UnregisterMessage('DragonBags_LayoutChanged')
end

local function SearchEditBox_OnTextChanged(editBox)
	local text = editBox:GetText()
	if not text or text:trim() == "" then
		editBox.clearButton:Hide()
	else
		editBox.clearButton:Show()
	end
	mod:SendMessage('DragonBags_UpdateAllButtons')
end

local function SearchEditBox_OnEnterPressed(editBox)
	editBox:ClearFocus()
	return SearchEditBox_OnTextChanged(editBox)
end

local function SearchEditBox_OnEscapePressed(editBox)
	editBox:ClearFocus()
	editBox:SetText('')
	return SearchEditBox_OnTextChanged(editBox)
end

function mod:OnBagFrameCreated(bag)
	if bag.bagName ~= "Backpack" then return end
	local frame = bag:GetFrame()
	local searchEditBox = CreateFrame("EditBox", addonName.."SearchFrame", frame, "InputBoxTemplate")
	self.widget = searchEditBox
	searchEditBox:SetSize(NORMAL_SEARCH_WIDTH, 18)
	searchEditBox:SetAutoFocus(false)
	searchEditBox:SetPoint("TOPLEFT")
	searchEditBox:SetPoint("TOPRIGHT")
	searchEditBox:SetTextInsets(14, 20, 0, 0)
	searchEditBox:SetScript("OnEnterPressed", SearchEditBox_OnEnterPressed)
	searchEditBox:SetScript("OnEscapePressed", SearchEditBox_OnEscapePressed)
	searchEditBox:SetScript("OnTextChanged", SearchEditBox_OnTextChanged)
	
	self:UpdateSearchLayout() -- Sets the initial width based on settings
	
	local searchIcon = searchEditBox:CreateTexture(nil, "OVERLAY")
	searchIcon:SetPoint("LEFT", 0, -2)
	searchIcon:SetSize(14, 14)
	searchIcon:SetTexture([[Interface\Common\UI-Searchbox-Icon]])
	searchIcon:SetVertexColor(0.6, 0.6, 0.6)

	local searchClearButton = CreateFrame("Button", nil, searchEditBox, "UIPanelButtonTemplate")
	searchClearButton:SetPoint("RIGHT",searchEditBox,"RIGHT",-2,0)
	searchClearButton:SetSize(20, 20)
	searchClearButton:SetText("X")
	searchClearButton:Hide()
	searchClearButton:SetScript('OnClick', function() SearchEditBox_OnEscapePressed(searchEditBox) end)

	searchEditBox.clearButton = searchClearButton

	addon.SetupTooltip(searchEditBox, {
		L["Item search"],
		L["Enter a text to search in item names."]
	}, "ANCHOR_TOPLEFT", 0, 8)

	frame:AddBottomWidget(searchEditBox, "LEFT", 50, 32, 10, 2)
end

function mod:UpdateButton(event, button)
	if not self.widget then return end
	local text = self.widget:GetText()
	if not text or text:trim() == "" then return end
	text = text:lower():trim()
	local name = button.itemId and GetItemInfo(button.itemId)
	if name and not name:lower():match(text) then
		button.IconTexture:SetVertexColor(0.2, 0.2, 0.2)
		button.IconQuestTexture:Hide()
		button.Count:Hide()
		button.Stock:Hide()
	end
end