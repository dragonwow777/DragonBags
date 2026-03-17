--[[-----------------------------------------------------------------------------
DragonBags – FinanceUI.lua (Warehouse Edition)
Layout: 884x500 | 4 Panels | Persistent Master Totals | Net Per Level
Logic: Robust Category Rendering | Safe Arithmetic | Debug Toggling
-----------------------------------------------------------------------------]]--

local addonName, addon = ...
local UI = {}
addon._FinanceUI = UI

-- WoW API
local _G = _G
local CreateFrame, UIParent = _G.CreateFrame, _G.UIParent
local GetMoney, GetMoneyString = _G.GetMoney, _G.GetMoneyString
local date, time, abs = _G.date, _G.time, _G.math.abs
local tinsert, sort = _G.table.insert, _G.table.sort
local string_format = _G.string.format

-- Shared References
local Data, Finance

-- ========== CONFIGURATION ==========
local DEBUG_MODE = false -- Set to true for verbose UI logic logs

-- ========== FINAL LAYOUT CALIBRATION ==========
local TOTAL_W, TOTAL_H = 884, 500
local HEADER_H = 28
local GAP_X, GAP_Y = 12, 32
local BOTTOM_PAD, KPI_H = 15, 75
local TOP_PAD = HEADER_H + 15 

local LEFT_W = 380            
local RIGHT_W = 460           

local TOTAL_CONTENT_H = TOTAL_H - TOP_PAD - KPI_H - GAP_Y - BOTTOM_PAD
local HALF_H = math.floor(TOTAL_CONTENT_H / 2)

-- Ledger Columns
local COL_ID_W, COL_DATE_W, COL_SRC_W, COL_AMT_W = 30, 100, 190, 135
local ROW_H = 20

-- MASTER CATEGORY LIST
UI.CATEGORIES = {
    "loot_solo", "loot_group", "loot_instance", "quest_in", 
    "merchant_sell", "auction_sell", "mail_in", "trade_in",
    "repair_out", "merchant_buy", "auction_buy", "trainer_out", 
    "taxi_out", "mail_out", "trade_out", "other_in", "other_out", "opening"
}

-- MEMORY POOLS for scrolling rows to prevent object creation lag
UI.rowPools = { 
    daily = {}, 
    level = {}, 
    summary = {}, 
    ledger = {},
    recat = {}
}

-- ========== INTERNAL UTILITIES ==========

local function dbg(msg)
    if DEBUG_MODE then
        _G.DEFAULT_CHAT_FRAME:AddMessage("|cff66ffcc[FinanceUI DBG]:|r "..tostring(msg))
    end
end

local function FS(parent, template)
    return parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
end

-- Formats copper into signed gold/silver/copper strings
local function moneySigned(delta)
    local d = tonumber(delta) or 0
    local s = GetMoneyString(abs(d), true)
    if d == 0 then return "|cffcccccc"..s.."|r" end
    return (d > 0 and "|cff20ff20+" or "|cffff4040-") .. s .. "|r"
end

-- Generic row factory for scrollable lists
local function GetRow(pool, index, parent, width)
    if not pool[index] then
        local row = CreateFrame("Button", nil, parent)
        row:SetSize(width, ROW_H)
        row.fsLeft = FS(row); row.fsLeft:SetPoint("LEFT", 5, 0)
        row.fsRight = FS(row); row.fsRight:SetPoint("RIGHT", -5, 0)
        row.fsMid = FS(row); row.fsMid:SetPoint("RIGHT", row.fsRight, "LEFT", -10, 0)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints(); row.bg:SetTexture(1, 1, 1, 0.03)
        pool[index] = row
    end
    pool[index]:SetParent(parent)
    pool[index]:Show()
    if pool[index].bg then
        if index % 2 == 0 then pool[index].bg:Show() else pool[index].bg:Hide() end
    end
    return pool[index]
end

local function HideUnused(pool, usedCount)
    for i = usedCount + 1, #pool do if pool[i] then pool[i]:Hide() end end
end

local function EnsureReferences()
    if not Data then Data = addon._FinanceData end
    if not Finance then Finance = addon:GetModule("Finance", true) end
end

-- ========== STATIC HANDLERS (Memory Leak Prevention) ==========

local function Ledger_OnEnter(self)
    local e = self.entry
    if not e then return end
    _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    _G.GameTooltip:AddLine("Transaction Detail", 1, 1, 1)
    -- Formatting category for tooltip: e.g. auction_sell -> AUCTION SELL
    _G.GameTooltip:AddDoubleLine("Category:", (e.source or "other"):upper():gsub("_", " "), 1,1,1, 1,0.8,0)
    if e.zone then _G.GameTooltip:AddDoubleLine("Location:", e.zone, 0.7,0.7,0.7, 1,1,1) end
    _G.GameTooltip:Show()
end

local function Ledger_OnLeave() _G.GameTooltip:Hide() end

-- Triggers the logic change and refreshes the dashboard
local function Recat_OnClick(self)
    EnsureReferences()
    dbg("Recategorizing ID " .. self.txnId .. " to " .. self.cat)
    if Finance and Finance.RecategorizeTransaction then
        Finance:RecategorizeTransaction(self.txnId, self.cat)
        UI.recatDialog:Hide()
        UI:UpdateDisplay()
    end
end

-- ========== PUBLIC API ==========

function UI:ToggleDisplay()
    if not self.frame then self:CreateFinanceFrame() end
    if self.frame:IsShown() then self.frame:Hide()
    else self.frame:Show(); self:UpdateDisplay() end
end

-- ========== 1. KPI DASHBOARD ==========
function UI:UpdateKpis()
    EnsureReferences()
    if not self.kpiPanel then return end
    
    local cur = GetMoney()
    local charKey = _G.UnitName("player") .. " - " .. _G.GetRealmName()
    local db = DragonBagsFinanceDB[charKey]
    local todayKey = date("%Y-%m-%d")
    local todayNet = (db and db.daily and db.daily.buckets[todayKey]) and db.daily.buckets[todayKey].overall.net or 0

    if not self.kpiCards then
        self.kpiCards = {}
        local labels = {"SESSION NET", "TODAY'S NET", "CURRENT TOTAL"}
        local anchors = {"LEFT", "CENTER", "RIGHT"}
        for i=1, 3 do
            local c = CreateFrame("Frame", nil, self.kpiPanel)
            c:SetSize(270, 60); c:SetPoint(anchors[i], (i==1 and 10 or (i==3 and -10 or 0)), 0)
            local t = FS(c, "GameFontDisableSmall")
            t:SetPoint("TOP", 0, -5); t:SetText(labels[i])
            c.val = FS(c, "GameFontNormalLarge"); c.val:SetPoint("CENTER", 0, 5)
            self.kpiCards[i] = c
        end
    end
    self.kpiCards[1].val:SetText(moneySigned(cur - (Finance.sessionStart or cur)))
    self.kpiCards[2].val:SetText(moneySigned(todayNet))
    self.kpiCards[3].val:SetText(GetMoneyString(cur, true))
    if self.TitleTextFS then self.TitleTextFS:SetText("DragonBags Finance | " .. charKey) end
end

-- ========== 2. DAILY HISTORY ==========
function UI:UpdateDailyHistory()
    EnsureReferences()
    local db = DragonBagsFinanceDB[_G.UnitName("player") .. " - " .. _G.GetRealmName()]
    local buckets = db and db.daily and db.daily.buckets or {}
    local keys = {}
    for k in _G.pairs(buckets) do tinsert(keys, k) end
    sort(keys, function(a,b) return a > b end)

    local y, count = -5, 0
    for _, day in _G.ipairs(keys) do
        count = count + 1
        local row = GetRow(self.rowPools.daily, count, self.dailyContent, LEFT_W - 45)
        row:SetPoint("TOPLEFT", 5, y)
        row.fsLeft:SetText(day); row.fsRight:SetText(moneySigned(buckets[day].overall.net)); row.fsMid:SetText("")
        y = y - 16
    end
    HideUnused(self.rowPools.daily, count)
    self.dailyContent:SetHeight(abs(y) + 20)
end

-- ========== 3. MILESTONES ==========
function UI:UpdateLevelHistory()
    EnsureReferences()
    local db = DragonBagsFinanceDB[_G.UnitName("player") .. " - " .. _G.GetRealmName()]
    local levelData = db and db.level_gold or {}
    local lvls = {}
    for lvl in _G.pairs(levelData) do tinsert(lvls, lvl) end
    sort(lvls, function(a, b) return tonumber(a) > tonumber(b) end)

    local y, count = -5, 0
    for _, lvl in _G.ipairs(lvls) do
        count = count + 1
        local row = GetRow(self.rowPools.level, count, self.levelContent, LEFT_W - 45)
        row:SetPoint("TOPLEFT", 5, y)
        local curG, prevG = levelData[lvl], levelData[tonumber(lvl)-1]
        row.fsLeft:SetText("Level " .. lvl); row.fsRight:SetText(GetMoneyString(curG, true))
        row.fsMid:SetText(prevG and moneySigned(curG - prevG) or "")
        y = y - 16
    end
    HideUnused(self.rowPools.level, count)
    self.levelContent:SetHeight(abs(y) + 20)
end

-- ========== 4. SOURCE SUMMARY ==========
function UI:UpdateSummary()
    EnsureReferences()
    local db = DragonBagsFinanceDB[_G.UnitName("player") .. " - " .. _G.GetRealmName()]
    local totals = db and db.master_totals or {}
    local sorted = {}
    for k, v in _G.pairs(totals) do if v ~= 0 then tinsert(sorted, {k=k, v=v}) end end
    sort(sorted, function(a,b) return a.v > b.v end)

    local y, count = -5, 0
    for _, item in _G.ipairs(sorted) do
        count = count + 1
        local row = GetRow(self.rowPools.summary, count, self.summaryContent, RIGHT_W - 45)
        row:SetPoint("TOPLEFT", 5, y)
        local color = item.v >= 0 and "|cff20ff20" or "|cffff4040"
        row.fsLeft:SetText(color .. item.k:upper():gsub("_", " ") .. "|r")
        row.fsRight:SetText(moneySigned(item.v)); row.fsMid:SetText("")
        y = y - 18
    end
    HideUnused(self.rowPools.summary, count)
    self.summaryContent:SetHeight(abs(y) + 20)
end

-- ========== 5. TRANSACTION LEDGER ==========
function UI:UpdateLedger()
    EnsureReferences()
    local db = DragonBagsFinanceDB[_G.UnitName("player") .. " - " .. _G.GetRealmName()]
    local archiveCount = (db and db.archive) and #db.archive or 0
    local log = Data:GetLog() or {}
    
    if self.ledgerHeaderFS then
        self.ledgerHeaderFS:SetText(string_format("TRANSACTION LEDGER   |cff888888(%d archived records)|r", archiveCount))
    end
    
    local y, count = 0, 0
    for i = #log, 1, -1 do
        count = count + 1
        local e = log[i]
        local row = GetRow(self.rowPools.ledger, count, self.ledgerContent, RIGHT_W - 45)
        row:SetPoint("TOPLEFT", 5, y)
        row.entry = e
        
        row.fsLeft:SetText("|cff888888"..e.id.."|r  "..date("%m/%d %H:%M", e.ts))
        row.fsRight:SetText(moneySigned(e.delta))
        row.fsMid:SetJustifyH("LEFT"); row.fsMid:SetPoint("LEFT", COL_ID_W + COL_DATE_W, 0)
        row.fsMid:SetText("|cffffd100"..(e.note or e.source):gsub("_", " ").."|r")
        
        row:SetScript("OnEnter", Ledger_OnEnter)
        row:SetScript("OnLeave", Ledger_OnLeave)
        y = y - ROW_H
    end
    HideUnused(self.rowPools.ledger, count)
    self.ledgerContent:SetHeight(abs(y) + 20)
    if self.ledgerSF then self.ledgerSF:UpdateScrollChildRect() end
end

-- ========== 6. DIALOGS & RECATEGORIZATION ==========

function UI:CreateRecategorizeDialog()
    if self.recatDialog then return end
    dbg("Initializing Recategorization Dialog...")
    local f = CreateFrame("Frame", "DragonBags_RecatDialog", UIParent, "DialogBoxFrame")
    f:SetSize(450, 400); f:SetPoint("CENTER"); f:SetFrameStrata("DIALOG"); f:Hide()
    self.recatDialog = f
    
    -- Explicitly setting header FontString
    local headerText = FS(f, "GameFontHighlight")
    headerText:SetPoint("TOP", 0, -15)
    headerText:SetText("Ledger Recategorization")
    
    local edit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    edit:SetPoint("TOP", 0, -45); edit:SetSize(80, 20); edit:SetNumeric(true); edit:SetJustifyH("CENTER"); self.recatEditBox = edit
    
    local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btn:SetPoint("TOP", edit, "BOTTOM", 0, -5); btn:SetSize(100, 22); btn:SetText("Lookup ID")
    btn:SetScript("OnClick", function() 
        EnsureReferences()
        local id = tonumber(edit:GetText())
        dbg("Lookup requested for ID: " .. (id or "Invalid"))
        if id and Finance and Finance.Recat_LookupTxn then Finance:Recat_LookupTxn(id) end 
    end)
    
    self.txnInfoFS = FS(f, "GameFontNormal"); self.txnInfoFS:SetPoint("TOP", 0, -100)
    self.catContainer = CreateFrame("Frame", nil, f); self.catContainer:SetPoint("TOPLEFT", 25, -125); self.catContainer:SetSize(400, 250)
end

-- Renders the actual buttons for all 18 categories
function UI:Recat_UpdateInfo(id, delta, oldSource)
    EnsureReferences()
    self.txnInfoFS:SetText(string_format("#%d: %s | Current: %s", id, moneySigned(delta), oldSource:upper()))
    
    local x, y, count = 0, 0, 0
    for i, cat in _G.ipairs(UI.CATEGORIES) do
        count = count + 1
        if not self.rowPools.recat[count] then 
            self.rowPools.recat[count] = CreateFrame("Button", nil, self.catContainer, "UIPanelButtonTemplate") 
        end
        local b = self.rowPools.recat[count]
        b:SetSize(95, 24); b:Show(); b.txnId, b.cat = id, cat
        
        -- Formatting button label: auction_sell -> Auction Sell
        local label = cat:gsub("_", " "):gsub("(%a)([%w]*)", function(f, r) return f:upper()..r:lower() end)
        b:SetText(label:sub(1,12)); b:SetPoint("TOPLEFT", x, y)
        b:SetScript("OnClick", Recat_OnClick)
        
        x = x + 100; if i % 4 == 0 then x = 0; y = y - 28 end
    end
    HideUnused(self.rowPools.recat, count)
end

-- ========== 7. CORE CONSTRUCTION ==========

function UI:CreateFinanceFrame()
    if self.frame then return end
    dbg("Building Main Finance Dashboard...")
    local f = CreateFrame("Frame", "DragonBags_FinanceUI", UIParent)
    _G.tinsert(_G.UISpecialFrames, "DragonBags_FinanceUI")
    f:SetSize(TOTAL_W, TOTAL_H); f:SetPoint("CENTER"); f:EnableMouse(true); f:SetMovable(true); f:SetFrameStrata("HIGH")
    f:RegisterForDrag("LeftButton"); f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16, insets = { 3,3,3,3 }})
    f:SetBackdropColor(0, 0, 0, 0.95); self.frame = f
    
    local function mkPanel(w, h, x, y, label, globalName)
        local p = CreateFrame("Frame", nil, f)
        p:SetSize(w, h); p:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
        p:SetBackdrop({bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { 4,4,4,4 }})
        p:SetBackdropColor(0, 0, 0, 0.6); p:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.9)
        local head = FS(p, "GameFontNormalSmall"); head:SetPoint("BOTTOMLEFT", p, "TOPLEFT", 8, 4)
        head:SetText(label:upper()); head:SetTextColor(1, 0.82, 0)
        
        if globalName == "Ledger" then self.ledgerHeaderFS = head end
        
        local sf = CreateFrame("ScrollFrame", "DragonBags_Fin" .. globalName, p, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 8, -8); sf:SetPoint("BOTTOMRIGHT", -28, 8)
        local c = CreateFrame("Frame", nil, sf); c:SetSize(w - 45, 1); sf:SetScrollChild(c); return c, sf
    end
    
    local lX, rX = 15, LEFT_W + GAP_X + 15
    local sY, bY = -TOP_PAD - KPI_H, -TOP_PAD - KPI_H - HALF_H - GAP_Y
    self.dailyContent, self.dailySF = mkPanel(LEFT_W, HALF_H, lX, sY, "Daily History", "Daily")
    self.summaryContent, self.summarySF = mkPanel(RIGHT_W, HALF_H, rX, sY, "Source Summary", "Summary")
    self.levelContent, self.levelSF = mkPanel(LEFT_W, HALF_H, lX, bY, "Level Milestones", "Level")
    self.ledgerContent, self.ledgerSF = mkPanel(RIGHT_W, HALF_H, rX, bY, "Transaction Ledger", "Ledger")
    
    self.TitleTextFS = FS(f, "GameFontNormalLarge"); self.TitleTextFS:SetPoint("TOPLEFT", 15, -10)
    CreateFrame("Button", nil, f, "UIPanelCloseButton"):SetPoint("TOPRIGHT", -5, -5)
    self.kpiPanel = CreateFrame("Frame", nil, f); self.kpiPanel:SetSize(TOTAL_W - 20, KPI_H); self.kpiPanel:SetPoint("TOP", 0, -TOP_PAD)
    
    local rb = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    rb:SetSize(110, 22); rb:SetPoint("TOPRIGHT", -40, -4); rb:SetText("Recategorize")
    rb:SetScript("OnClick", function() self:CreateRecategorizeDialog(); self.recatDialog:Show() end)
    
    local recalc = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    recalc:SetSize(110, 22); recalc:SetPoint("RIGHT", rb, "LEFT", -5, 0); recalc:SetText("Recalculate")
    recalc:SetScript("OnClick", function() 
        EnsureReferences()
        if Data and Data.RecalculateAllTotals then 
            Data:RecalculateAllTotals() 
        end
        UI:UpdateDisplay() 
    end)
    f:SetScript("OnShow", function() self:UpdateDisplay() end); f:Hide()
end

function UI:UpdateDisplay()
    if not self.frame or not self.frame:IsShown() then return end
    dbg("Refreshing Dashboard Display...")
    self:UpdateKpis(); self:UpdateDailyHistory(); self:UpdateLevelHistory(); self:UpdateSummary(); self:UpdateLedger()
end

function UI:OnInitialize(d, fin) Data, Finance = d, fin; self:CreateFinanceFrame() end