--[[
DragonBags - Bank Module
Manages:
  1. A "BANK" button at the bottom-right of the Backpack frame (replaces the old ALT button
     and the old header "B" button).  Clicking it opens/closes the Bank frame in snapshot
     mode when away from the banker, or does nothing when at the banker (live frame already
     handling display).
  2. A character dropdown that floats above the top-left of the Backpack frame, allowing the
     player to switch BOTH the Backpack and the Bank frame between "Self (live)" and any saved
     character's snapshot data.  The Bank frame NEVER has its own dropdown — it always mirrors
     the Backpack selection.
  3. BANKFRAME_OPENED handling: exit snapshot on both frames, reset dropdown to "Self".
--]]

local addonName, addon = ...
local L = addon.L

--<GLOBALS
local _G               = _G
local CreateFrame      = _G.CreateFrame
local GameTooltip      = _G.GameTooltip
local GetRealmName     = _G.GetRealmName
local UnitName         = _G.UnitName
local PlaySound        = _G.PlaySound
local RAID_CLASS_COLORS      = _G.RAID_CLASS_COLORS
local UIDropDownMenu_Initialize    = _G.UIDropDownMenu_Initialize
local UIDropDownMenu_CreateInfo    = _G.UIDropDownMenu_CreateInfo
local UIDropDownMenu_SetSelectedValue = _G.UIDropDownMenu_SetSelectedValue
local UIDropDownMenu_SetText       = _G.UIDropDownMenu_SetText
local UIDropDownMenu_AddButton     = _G.UIDropDownMenu_AddButton
local CloseDropDownMenus           = _G.CloseDropDownMenus
--GLOBALS>

local mod = addon:NewModule('BankView', 'AceEvent-3.0')

mod.uiName = L['Bank View']
mod.uiDesc = L['Displays a button to toggle the saved bank data view.']

-- Currently selected snapshot character key (nil = Self / live mode)
local activeSnapshotKey = nil

-- Cached frame references
local backpackContainer = nil
local bankContainer     = nil
local charDropdown      = nil  -- UIDropDownMenuTemplate frame

local ROW_WIDTH_SHRINK_THRESHOLD = 8

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Return the bank ContainerFrame (may be nil if not yet created)
local function GetBankContainer()
    if bankContainer and bankContainer:GetParent() ~= nil then
        return bankContainer
    end
    for _, bag in addon:IterateBags() do
        if bag.isBank and bag:HasFrame() then
            bankContainer = bag:GetFrame()
            return bankContainer
        end
    end
end

-- Return a sorted list of alts on this realm (excluding the logged-in player)
local function GetRealmCharacters()
    local list, realm = {}, GetRealmName()
    local me = UnitName("player")
    local chars = (addon.db and addon.db.global and addon.db.global.characters) or {}
    for key, data in pairs(chars) do
        local name, r = key:match("^(.-) %- (.+)$")
        if r == realm and name and name ~= me then
            _G.table.insert(list, { key = key, name = name, class = data.class })
        end
    end
    _G.table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

--------------------------------------------------------------------------------
-- Character selection logic (shared between dropdown and BANKFRAME_OPENED)
--------------------------------------------------------------------------------

-- Apply snapshot or live mode to both frames.
local function ApplySelection(key)
    activeSnapshotKey = key

    if key then
        -- Enter snapshot mode on Backpack (bags) and Bank (bank) if open
        if backpackContainer then
            backpackContainer:EnterSnapshotMode(key, false)
        end
        local bf = GetBankContainer()
        if bf and bf:IsShown() then
            bf:EnterSnapshotMode(key, true)
        end
    else
        -- Return to live mode
        if backpackContainer then
            backpackContainer:LeaveSnapshotMode()
        end
        local bf = GetBankContainer()
        if bf then
            if addon:GetInteractingWindow() == "BANKFRAME" then
                -- At banker → leave snapshot, live data will fill in via ResumeUpdates
                bf:LeaveSnapshotMode()
            else
                -- Away from banker → close the bank frame (nothing live to show)
                bf:LeaveSnapshotMode()
                bf:Hide()
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Dropdown (floats above top-left of Backpack frame)
--------------------------------------------------------------------------------

local function BuildDropdown(dd)
    local list = GetRealmCharacters()

    local selfEntry = UIDropDownMenu_CreateInfo()
    selfEntry.text         = "|cffFFFFFF" .. L["Self (live)"] .. "|r"
    selfEntry.value        = false
    selfEntry.func         = function()
        UIDropDownMenu_SetSelectedValue(dd, false)
        UIDropDownMenu_SetText(dd, L["Self (live)"])
        ApplySelection(nil)
    end
    selfEntry.checked      = (activeSnapshotKey == nil)
    selfEntry.notCheckable = false
    UIDropDownMenu_AddButton(selfEntry, 1)

    if #list == 0 then
        local noChars = UIDropDownMenu_CreateInfo()
        noChars.text     = L["No other characters on this realm."]
        noChars.disabled = true
        noChars.notCheckable = true
        UIDropDownMenu_AddButton(noChars, 1)
        return
    end

    for _, c in _G.ipairs(list) do
        local col   = RAID_CLASS_COLORS[c.class] or { r = 1, g = 1, b = 1 }
        local label = _G.string.format("|cff%02x%02x%02x%s|r",
            col.r * 255, col.g * 255, col.b * 255, c.name)
        local entry = UIDropDownMenu_CreateInfo()
        entry.text         = label
        entry.value        = c.key
        entry.checked      = (activeSnapshotKey == c.key)
        entry.notCheckable = false
        entry.func = function()
            UIDropDownMenu_SetSelectedValue(dd, c.key)
            UIDropDownMenu_SetText(dd, label)
            ApplySelection(c.key)
        end
        UIDropDownMenu_AddButton(entry, 1)
    end
end

local function CreateCharDropdown(backpackFrame)
    local dd = CreateFrame("Frame", "DragonBagsCharDropdown", _G.UIParent, "UIDropDownMenuTemplate")
    -- Anchor just above the top-left of the Backpack frame.
    -- The -10 x-offset compensates for UIDropDownMenu's built-in internal left padding.
    dd:SetPoint("BOTTOMLEFT", backpackFrame, "TOPLEFT", -10, 2)
    backpackFrame:HookScript("OnShow", function()
        dd:Show()
    end)
    backpackFrame:HookScript("OnHide", function()
        dd:Hide()
        CloseDropDownMenus()
    end)

    UIDropDownMenu_Initialize(dd, function(self, level)
        if level ~= 1 then return end
        BuildDropdown(self)
    end)

    UIDropDownMenu_SetText(dd, L["Self (live)"])
    UIDropDownMenu_SetSelectedValue(dd, false)

    charDropdown = dd
    return dd
end

--------------------------------------------------------------------------------
-- BANK button resize (mirrors AltViewer narrow-mode behaviour)
--------------------------------------------------------------------------------

function mod:UpdateBankButtonLayout()
    if not self.bankButton or not self.bankButton:IsShown() then return end
    local rowWidth = addon.db.profile.rowWidth.Backpack or 9
    if rowWidth < ROW_WIDTH_SHRINK_THRESHOLD then
        self.bankButton:SetText("|cffC7C7CFB|r")
        self.bankButton:SetWidth(20)
    else
        self.bankButton:SetText("|cffC7C7CFBANK|r")
        self.bankButton:SetWidth(40)
    end
end

--------------------------------------------------------------------------------
-- Module lifecycle
--------------------------------------------------------------------------------

function mod:OnEnable()
    self:RegisterEvent('BANKFRAME_OPENED', 'OnBankFrameOpened')
    addon:HookBagFrameCreation(self, 'OnBagFrameCreated')
    for _, bag in addon:IterateBags() do
        if bag:HasFrame() then
            self:OnBagFrameCreated(bag)
        end
    end
    self:RegisterMessage('DragonBags_LayoutChanged', 'UpdateBankButtonLayout')
end

function mod:OnDisable()
    if charDropdown then charDropdown:Hide() end
    local bf = GetBankContainer()
    if bf then bf:LeaveSnapshotMode() end
end

function mod:OnBankFrameOpened()
    -- Player just arrived at the banker.  Exit any snapshot on both frames and
    -- reset the dropdown to "Self (live)".
    activeSnapshotKey = nil
    if backpackContainer then
        backpackContainer:LeaveSnapshotMode()
    end
    local bf = GetBankContainer()
    if bf then bf:LeaveSnapshotMode() end
    if charDropdown then
        UIDropDownMenu_SetText(charDropdown, L["Self (live)"])
        UIDropDownMenu_SetSelectedValue(charDropdown, false)
    end
end

function mod:OnBagFrameCreated(bag)
    -- Cache bank container reference when it's created
    if bag.isBank and bag:HasFrame() then
        bankContainer = bag:GetFrame()
        return
    end

    -- Only add UI widgets to the Backpack frame
    local container = bag:GetFrame()
    if container.name ~= "Backpack" then return end

    -- Guard: don't add widgets twice on re-enable
    if container.BankButton then return end

    backpackContainer = container

    --------------------------------------------------------------------------
    -- 1. BANK button — bottom-right, same slot the old ALT button occupied
    --------------------------------------------------------------------------
    local bankButton = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    bankButton:SetSize(40, 20)
    bankButton:SetText("|cffC7C7CFBANK|r")
    bankButton:SetNormalFontObject("GameFontNormalSmall")

    bankButton:SetScript("OnClick", function()
        PlaySound("igMainMenuOptionCheckBoxOn")

        -- At banker: live bank frame is already showing; don't overlay it.
        if addon:GetInteractingWindow() == "BANKFRAME" then return end

        local bf = GetBankContainer()
        if not bf then
            -- Frame hasn't been created yet (player hasn't visited bank this session).
            -- bag:GetFrame() lazily creates and returns the frame.
            for _, bag in addon:IterateBags() do
                if bag.isBank then
                    bf = bag:GetFrame()
                    bankContainer = bf
                    break
                end
            end
        end
        if not bf then return end

        if bf:IsShown() then
            bf:Hide()
        else
            local charKey = activeSnapshotKey
            if not charKey then
                charKey = UnitName("player") .. " - " .. GetRealmName()
            end
            bf:EnterSnapshotMode(charKey, true)
            bf:Show()
            -- bag:Open() normally sends DragonBags_BagOpened which triggers LayoutBags()
            -- to call SetPoint on the frame.  Since we bypass Open() (CanOpen() blocks it
            -- away from the banker), we must call LayoutBags() ourselves so the frame
            -- gets its screen position and actually appears.
            addon:LayoutBags()
        end
    end)

    addon.SetupTooltip(bankButton, {
        L["Bank Snapshot"],
        L["Click to view your saved bank contents."]
    }, "ANCHOR_TOPLEFT", 0, 8)

    -- AddBottomWidget(widget, side, order, height)
    container:AddBottomWidget(bankButton, "RIGHT", 20, 20)
    container.BankButton = bankButton
    self.bankButton = bankButton

    -- Ensure narrow/wide layout is applied immediately
    self:UpdateBankButtonLayout()
    addon:LayoutBags()

    --------------------------------------------------------------------------
    -- 2. Character dropdown — floats above top-left of Backpack frame
    --------------------------------------------------------------------------
    CreateCharDropdown(container)

    --------------------------------------------------------------------------
    -- 3. Backward-compat stub so any old callers don't error
    --------------------------------------------------------------------------
    container.ToggleBank = function()
        bankButton:GetScript("OnClick")(bankButton)
    end
end
