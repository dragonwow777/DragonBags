--[[-----------------------------------------------------------------------------
DragonBags – Finance.lua (Vanilla/Classic - Full Feature Baseline)
---------------------------------------------------------------------------------
GUIDING PRINCIPLES:
1. Well-Commented: Logic gates and state changes are explicitly described.
2. Granular Debugging: Narrates the decision story for every transaction.
3. Correct Category Enforcement: Sticky registry protects against mailbox race conditions.
4. Flight Path Detection: Captures taxi/travel expenses via timing pulse system.
-----------------------------------------------------------------------------]]--

local addonName, addon = ...
local Finance = addon:NewModule("Finance", "AceEvent-3.0", "AceHook-3.0")
local L = addon.L
local Data = addon._FinanceData
local table_remove = _G.table.remove 

local DEBUG_MODE = false

local function dbg(msg)
    if DEBUG_MODE then
        _G.DEFAULT_CHAT_FRAME:AddMessage("|cff66ffcc[Finance DBG]:|r "..tostring(msg))
    end
end

-- =========================================================================================
-- STATE TRACKING
-- =========================================================================================
-- This table tracks all relevant game states and timing windows for transaction classification.
-- Pulse timers work by recording the timestamp when certain UI elements open/close, then
-- checking if money changes happen within a 2-second window.
-- =========================================================================================

Finance.state = {
    -- UI State Flags (true when at specific NPCs)
    atMerchant = false,  -- At vendor NPC
    atTrainer = false,   -- At class trainer
    atMail = false,      -- Mailbox is open
    atAuction = false,   -- At auction house
    
    -- Loot State
    lootActive = false,  -- Currently looting a corpse/container
    lastMob = "Unknown", -- Name of last targeted mob (for loot attribution)
    
    -- Instance Tracking
    instanceContext = "Open World",  -- Current zone/instance name
    
    -- Auction House Sticky Registry
    -- This prevents race conditions where mailbox refreshes might re-scan the same mail
    -- Registry persists across MAIL_INBOX_UPDATE events until mailbox is closed
    ahRegistry = {},
    
    -- Pulse Timers (timestamp of last relevant action)
    -- Money changes within 2 seconds of these timestamps get special categorization
    questPulse = 0,      -- Quest completion
    groupLootPulse = 0,  -- Group loot message received
    soloLootPulse = 0,   -- Solo loot message received
    repairPulse = 0,     -- Repair button clicked
    taxiPulse = 0,       -- Flight map opened (NEW - for taxi detection)
}

Finance._lastMoney = _G.GetMoney()

-- =========================================================================================
-- MAILBOX SCANNER
-- =========================================================================================
-- Scans the mailbox for Auction House mail and registers amounts in a sticky registry.
-- This prevents AH income from being misclassified as generic mail when the inbox refreshes.
-- 
-- Detection Strategy:
-- 1. Check for AH stationery ID (62)
-- 2. Check for sender name containing "auction" or "house"
-- 3. Register the exact copper amount to match against later transactions
-- =========================================================================================

local function UpdateMailboxState()
    local st = Finance.state
    local numItems = _G.GetInboxNumItems()
    dbg("[SCANNER] Story: Updating AH Registry from " .. numItems .. " items...")
    
    for i = 1, numItems do
        local _, stationeryID = _G.GetInboxText(i)
        local _, _, sender, _, money = _G.GetInboxHeaderInfo(i)
        
        if money and money > 0 and sender then
            local s = sender:lower()
            
            -- Detect Auction House mail by stationery or sender name
            if (stationeryID == 62) or s:find("auction") or s:find("house") then
                -- Check if this amount is already registered (prevent duplicates)
                local found = false
                for _, val in _G.ipairs(st.ahRegistry) do
                    if val == money then 
                        found = true 
                        break 
                    end
                end
                
                -- Register new AH mail amount
                if not found then
                    _G.table.insert(st.ahRegistry, money)
                    dbg("[SCANNER] Registered AH Mail: " .. money .. " copper")
                end
            end
        end
    end
end

-- =========================================================================================
-- TRANSACTION CLASSIFICATION ENGINE
-- =========================================================================================
-- This is the brain of the Finance module. It examines game state, timing pulses, and
-- context to determine the source category for every money change.
--
-- Classification Priority (checked in order):
-- 
-- INCOME (delta > 0):
--   1. Quest rewards (questPulse within 2 seconds)
--   2. Instance loot (in dungeon/raid)
--   3. Vendor sales (at merchant NPC)
--   4. Auction House mail (sticky registry match)
--   5. Generic mail (at mailbox, not in registry)
--   6. Group loot (group pulse within 2 seconds)
--   7. Solo loot (loot window open OR solo pulse within 2 seconds)
--   8. Other income (fallback)
--
-- EXPENSES (delta < 0):
--   1. Repairs (repair pulse within 2 seconds)
--   2. Flight paths (taxi pulse within 2 seconds) ← NEW!
--   3. Training (at trainer NPC)
--   4. Vendor purchases (at merchant NPC)
--   5. Auction house purchases (at AH)
--   6. Postage/COD (at mailbox)
--   7. Other expenses (fallback)
-- =========================================================================================

local function ClassifyTransaction(st, delta)
    local now = _G.time()
    
    -- 1. Get Instance Data
    local zoneName, instanceType = _G.GetInstanceInfo()
    local isInst = (instanceType ~= "none")
    
    -- 2. Determine Location Context
    if isInst then
        -- Inside a dungeon/raid, keep the specific instance name
        st.instanceContext = zoneName or "Unknown Instance"
    else
        -- Open World: Combine SubZone and Zone for the tooltip
        local sz = _G.GetSubZoneText()
        local z = _G.GetRealZoneText()
        
        if sz ~= "" and sz ~= z then
            st.instanceContext = sz .. ", " .. z
        else
            st.instanceContext = z
        end
    end
            
    -- Group detection
    local numParty = _G.GetNumPartyMembers() or 0
    local numRaid = _G.GetNumRaidMembers() or 0
    local inGroup = (numParty > 0 or numRaid > 0)
    
    -- =================================================================================
    -- INCOME CLASSIFICATION (delta > 0)
    -- =================================================================================
    if delta > 0 then
        -- Quest rewards have highest priority (player just completed a quest)
        if (now - st.questPulse <= 2) then 
            return "quest_in", "Quest Reward" 
        end
        
        -- Instance loot gets special categorization (dungeons/raids)
        if isInst then 
            return "loot_instance", st.instanceContext 
        end
        
        -- Vendor sales (selling items to NPCs)
        if st.atMerchant then 
            return "merchant_sell", "Vendor Sale" 
        end

        -- Auction House mail detection (sticky registry prevents misclassification)
        if st.atMail and #st.ahRegistry > 0 then
            -- Check if this exact amount matches a registered AH mail
            for i, registeredAmount in _G.ipairs(st.ahRegistry) do
                if delta == registeredAmount then
                    -- Match found! Remove from registry and categorize as AH income
                    _G.table.remove(st.ahRegistry, i)
                    dbg("[DECISION] Story: Matched " .. delta .. " in Sticky Registry.")
                    return "auction_sell", "Mail: Auction House"
                end
            end
            -- At mailbox but not in AH registry = generic mail
            return "mail_in", "Mail Delivery"
        end

        -- Group loot (shared with party/raid)
        if inGroup and (now - st.groupLootPulse <= 2) then 
            return "loot_group", "Group Share" 
        end
        
        -- Solo loot (from killing mobs or looting containers)
        -- Triggers if: loot window is open, OR loot pulse happened recently
        if st.lootActive or (now - st.soloLootPulse <= 2) or (now - st.groupLootPulse <= 2) then 
            return "loot_solo", "Solo: " .. st.lastMob 
        end
        
        -- Fallback for unclassified income
        return (st.atMail and "mail_in") or "other_in", st.instanceContext

    -- =================================================================================
    -- EXPENSE CLASSIFICATION (delta < 0)
    -- =================================================================================
    elseif delta < 0 then
        -- Repairs have highest priority (just clicked repair button)
        if (now - st.repairPulse <= 2) then 
            return "repair_out", "Equipment Repair" 
        end
        
        -- Flight paths / Taxi expenses (NEW!)
        -- Detects when player takes a flight path by checking taxi map pulse
        -- IMPORTANT: This must come BEFORE atMerchant check because flight masters
        -- are merchant NPCs, and we want taxi expenses to take priority over purchases
        if (now - st.taxiPulse <= 2) then 
			return "taxi_out", "Flight Path (Initial)" 
		end
        
        -- Class/profession training
        if st.atTrainer then 
            return "trainer_out", "Skill Training" 
        end
        
        -- Vendor purchases (buying items from NPCs)
        if st.atMerchant then 
            return "merchant_buy", "Purchase" 
        end
        
        -- Auction house purchases (buying from AH)
        if st.atAuction then 
            return "auction_buy", "Auction House" 
        end
        
        -- Mail postage or COD payments
        if st.atMail then 
            return "mail_out", "Postage/COD" 
        end
        
		-- FINAL SAFETY CHECK: Specific Engine Inquiry
        -- This ignores the timer and just asks: "Am I currently flying?"
        if _G.UnitOnTaxi("player") then
            dbg("[DECISION] Story: Deduction caught by UnitOnTaxi engine safety check.")
            return "taxi_out", "Flight Path (Mid-Flight)" 
        end
		
        -- Fallback for unclassified expenses
        return "other_out", st.instanceContext
    end
end

-- =========================================================================================
-- TRANSACTION LOGGING
-- =========================================================================================
-- Called whenever PLAYER_MONEY event fires. Calculates the delta, classifies it,
-- and writes to the database.
-- =========================================================================================

function Finance:LogMoneyChange()
    local now = _G.GetMoney()
    local delta = now - (self._lastMoney or now)
    
    -- Only log if money actually changed
    if delta ~= 0 then
        local autoSrc, autoNote = ClassifyTransaction(self.state, delta)
        dbg("[DB APPEND] Story: Writing " .. delta .. " copper to " .. autoSrc)
        
        -- Write transaction to database
        Data:Append({
            ts = _G.time(),              -- Timestamp
            delta = delta,               -- Copper amount (positive = gain, negative = loss)
            before = self._lastMoney,    -- Balance before transaction
            after = now,                 -- Balance after transaction
            source = autoSrc,            -- Category (e.g., "loot_solo", "taxi_out")
            note = autoNote,             -- Human-readable description
            level = _G.UnitLevel("player"),
            zone = self.state.instanceContext,
            player = _G.UnitName("player"),
            realm = _G.GetRealmName()
        })
    end
    
    self._lastMoney = now
end

-- =========================================================================================
-- RECATEGORIZATION SYSTEM
-- =========================================================================================
-- Allows the UI to look up transactions for manual recategorization.
-- Used when the automatic classification gets something wrong.
-- =========================================================================================

function Finance:Recat_LookupTxn(id)
    local log = Data:GetLog()
    for _, e in _G.ipairs(log) do
        if e.id == id then
            -- Send transaction data to UI for recategorization
            if addon._FinanceUI and addon._FinanceUI.Recat_UpdateInfo then
                addon._FinanceUI:Recat_UpdateInfo(e.id, e.delta, e.source)
            end
            return
        end
    end
end

--- Recategorizes an existing transaction and updates all totals
-- @param txnId     Unique transaction ID
-- @param newSource New category name (e.g., "loot_solo", "repair_out")
-- @return boolean  True if successful, false if transaction not found
function Finance:RecategorizeTransaction(txnId, newSource)
    local log = Data:GetLog()
    local entry
    
    -- 1. Find the exact entry in the log
    for _, e in _G.ipairs(log) do 
        if e.id == txnId then 
            entry = e 
            break 
        end 
    end
    
    if not entry then 
        dbg("[RECAT] Transaction ID " .. txnId .. " not found")
        return false 
    end
    
    -- 2. Subtract the old category values from totals
    Data:UndoBucketEffect(entry.ts, entry.delta, entry.source)
    
    -- 3. Apply the new category in-place
    local oldSource = entry.source
    entry.source = newSource
    entry.note = "Recat: " .. oldSource .. " -> " .. newSource
    
    -- 4. Re-calculate totals with the new category
    Data:UpdateBucketsManual(entry.ts, entry.delta, newSource)
    
    dbg("[RECAT] Transaction #" .. txnId .. " changed from " .. oldSource .. " to " .. newSource)
    return true
end

-- =========================================================================================
-- OPTIONS (for AceConfig integration)
-- =========================================================================================

function Finance:GetOptions()
    return {
        enableUI = { 
            name = "Enable Dashboard", 
            type = 'toggle', 
            order = 1, 
            get = function() return true end, 
            set = function(_, v) end 
        },
        logLimit = { 
            name = "Entry Limit", 
            type = 'range', 
            min = 500, 
            max = 5000, 
            step = 100, 
            get = function() return Data:GetLogLimit() end, 
            set = function(_, v) Data:SetLogLimit(v) end 
        },
    }
end

-- =========================================================================================
-- EVENT HANDLER
-- =========================================================================================
-- Central event dispatcher. Routes all game events to appropriate state updates.
-- =========================================================================================

function Finance:OnEvent(event, ...)
    local st = self.state
    
    -- Debug all events except PLAYER_MONEY (too spammy)
    if event ~= "PLAYER_MONEY" then 
        dbg("[TRIGGER] " .. event) 
    end
    
    -- Money changed - log the transaction
    if event == "PLAYER_MONEY" then 
        self:LogMoneyChange()
    
    -- Loot messages (group or solo)
    elseif event == "CHAT_MSG_MONEY" then 
        st.groupLootPulse = _G.time()
        st.soloLootPulse = _G.time()
    
    -- Mailbox opened or updated
    elseif event == "MAIL_SHOW" or event == "MAIL_INBOX_UPDATE" then 
        st.atMail = true
        UpdateMailboxState()  -- Scan for AH mail
    
    -- Mailbox closed - clear state and registry
    elseif event == "MAIL_CLOSED" then 
        st.atMail = false
        st.ahRegistry = {}  -- Reset sticky registry
        dbg("[STATE] Mailbox Closed - AH Registry Cleared")
    
    -- Class trainer window
    elseif event == "TRAINER_SHOW" then 
        st.atTrainer = true 
    elseif event == "TRAINER_CLOSED" then 
        st.atTrainer = false 
    
    -- Merchant/vendor window
    elseif event == "MERCHANT_SHOW" then 
        st.atMerchant = true
    elseif event == "MERCHANT_CLOSED" then 
        st.atMerchant = false
    
    -- Loot window
    elseif event == "LOOT_OPENED" then 
        st.lootActive = true
        st.lastMob = _G.UnitName("target") or "Unknown"
    elseif event == "LOOT_CLOSED" then 
        st.lootActive = false
    
    -- Quest completion
    elseif event == "QUEST_FINISHED" then 
        st.questPulse = _G.time()
    
    -- Auction house window
    elseif event == "AUCTION_HOUSE_SHOW" then 
        st.atAuction = true
    elseif event == "AUCTION_HOUSE_CLOSED" then 
        st.atAuction = false
    
    -- Flight map (taxi system) - NEW!
    elseif event == "TAXIMAP_OPENED" then 
		-- Optional: Just for logging the interaction start
		dbg("[STATE] Taxi Map Opened")

	elseif event == "TAXIMAP_CLOSED" then 
		-- This is the critical moment: refresh the pulse when the choice is made
		st.taxiPulse = _G.time() 
		dbg("[STATE] Taxi Map Closed - Payment detection window active (2s)")
	end
end

-- =========================================================================================
-- MODULE INITIALIZATION
-- =========================================================================================

function Finance:OnEnable()
    -- Create event frame
    self.frame = self.frame or _G.CreateFrame("Frame")
    
    -- Register all relevant game events
    local events = { 
        "PLAYER_MONEY",           -- Money amount changed
        "LOOT_OPENED",            -- Loot window opened
        "LOOT_CLOSED",            -- Loot window closed
        "CHAT_MSG_MONEY",         -- Loot/money message in chat
        "QUEST_FINISHED",         -- Quest turn-in completed
        "MERCHANT_SHOW",          -- Vendor window opened
        "MERCHANT_CLOSED",        -- Vendor window closed
        "MAIL_SHOW",              -- Mailbox opened
        "MAIL_CLOSED",            -- Mailbox closed
        "MAIL_INBOX_UPDATE",      -- Mailbox contents changed
        "AUCTION_HOUSE_SHOW",     -- AH window opened
        "AUCTION_HOUSE_CLOSED",   -- AH window closed
        "TRAINER_SHOW",           -- Trainer window opened
        "TRAINER_CLOSED",         -- Trainer window closed
        "TAXIMAP_OPENED",         -- Flight map opened (NEW!)
        "TAXIMAP_CLOSED"          -- Flight map closed (NEW!)
    }
    
    for _, e in _G.ipairs(events) do 
        self.frame:RegisterEvent(e) 
    end
    
    -- Set event handler
    self.frame:SetScript("OnEvent", function(_, event, ...) 
        self:OnEvent(event, ...) 
    end)
    
    -- =================================================================================
    -- REPAIR HOOKS
    -- =================================================================================
    -- Hooks repair functions to set the repair pulse timer.
    -- This allows detection of repair expenses even when done via hotkey or macro.
    -- =================================================================================
    
    -- 1. Full Repair (both standard and guild bank repair)
    self:SecureHook("RepairAllItems", function() 
        self.state.repairPulse = _G.time() 
        dbg("[HOOK] RepairAllItems triggered - repair pulse set")
    end)
    
    -- 2. Single Item Repair (click individual items at vendor)
    -- We hook the button click that puts cursor into "repair mode"
    if _G.MerchantRepairItemButton then
        self:SecureHookScript(_G.MerchantRepairItemButton, "OnClick", function() 
            self.state.repairPulse = _G.time() 
            dbg("[HOOK] MerchantRepairItemButton clicked - repair pulse set")
        end)
    end
    
    -- Initialize money tracking.
    -- sessionStart is the baseline for the "SESSION NET" KPI in the UI.
    -- It must be set here so the UI always has a valid reference point,
    -- regardless of whether the Finance window is ever opened.
    self._lastMoney = _G.GetMoney()
    self.sessionStart = self._lastMoney

    dbg("[SYSTEM] Finance module enabled - All hooks and events active")
end

-- =========================================================================================
-- SLASH COMMAND
-- =========================================================================================

_G.SLASH_LBFIN1 = "/lbfin"
_G.SlashCmdList["LBFIN"] = function() 
    local UI_Mod = addon._FinanceUI
    if UI_Mod and UI_Mod.ToggleDisplay then 
        UI_Mod:ToggleDisplay() 
    end
end