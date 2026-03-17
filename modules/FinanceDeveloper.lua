--[[-----------------------------------------------------------------------------
DragonBags - FinanceDeveloper.lua
UI-only viewer. 3.3.5 compatible (no BackdropTemplate).

Left-Top (60%): Daily Buckets
Left-Bottom (40%): Gold by Level
Right: Ledger

Requires addon._FinanceData with:
  GetDailyKeys(), GetDailyTotals(dayKey), GetLog(), GetLevelGold()
-----------------------------------------------------------------------------]]--

local addonName, addon = ...
local Dev = addon._FinanceDev or {}
addon._FinanceDev = Dev

-- WoW API
local CreateFrame   = CreateFrame
local UIParent      = UIParent
local GetMoney      = GetMoney
local GetMoneyString= GetMoneyString
local GameTooltip   = GameTooltip
local date, time    = date, time
local abs, floor, min = math.abs, math.floor, math.min
local tinsert, tsort= table.insert, table.sort
local ipairs, pairs = ipairs, pairs
local max           = math.max
local UnitLevel     = UnitLevel

-- Data module
local Data = addon and addon._FinanceData

-- formatting --------------------------------------------------------------
local function moneyPlain(c) return GetMoneyString(tonumber(c or 0) or 0, true) end
local function moneySigned(c)
  local d = tonumber(c or 0) or 0
  if d == 0 then return "|cffcccccc"..GetMoneyString(0, true).."|r" end
  local s = GetMoneyString(abs(d), true)
  if d > 0 then return "|cff20ff20+"..s.."|r"
  elseif d < 0 then return "|cffff4040-"..s.."|r" end
end

-- constants ---------------------------------------------------------------
local ROW_H       = 20
local LEFT_PAD    = 8
local SCROLLBAR_W = 20
local TOTAL_H     = 560
local TOP_PAD     = 36
local BOTTOM_PAD  = 8
local GAP         = 8
local USABLE_H    = TOTAL_H - TOP_PAD - BOTTOM_PAD -- 516
local LEFT_TOP_H  = floor( (USABLE_H - GAP) * 0.6 ) -- 305
-- Bottom height is implied by anchors

-- build / toggle ----------------------------------------------------------
function Dev:OnInitialize()
  if self.frame then return end

  local f = CreateFrame("Frame", "DragonBags_FinanceDev", UIParent)
  f:SetSize(1150, 560)
  f:SetPoint("CENTER")
  f:SetMovable(true); f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop",  f.StopMovingOrSizing)
  f:Hide()
  self.frame = f

  -- title bar
  local titleBar = f:CreateTexture(nil, "BACKGROUND")
  titleBar:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
  titleBar:SetVertexColor(0, 0, 0, 0.9)
  titleBar:SetPoint("TOPLEFT"); titleBar:SetPoint("TOPRIGHT"); titleBar:SetHeight(28)

  local titleFS = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  titleFS:SetPoint("LEFT", titleBar, "LEFT", 12, 0)
  self._titleFS = titleFS

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 1)

  -- LEFT (TOP): buckets ----------------------------------------------------
  local left = CreateFrame("Frame", nil, f)
  left:SetPoint("TOPLEFT", 8, -TOP_PAD)
  left:SetHeight(LEFT_TOP_H) -- CHANGED: Set explicit height
  left:SetWidth(380)
  local leftBg = left:CreateTexture(nil, "BACKGROUND")
  leftBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
  leftBg:SetVertexColor(0.07, 0.07, 0.07, 0.9)
  leftBg:SetAllPoints()
  self.left = left

  local leftHdr = left:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  leftHdr:SetPoint("TOPLEFT", LEFT_PAD, -8)
  leftHdr:SetText("Daily Buckets")

  local bucketScroll = CreateFrame("ScrollFrame", "LB_FinBucketsScroll", left, "UIPanelScrollFrameTemplate")
  bucketScroll:SetPoint("TOPLEFT", LEFT_PAD-2, -28)
  bucketScroll:SetPoint("BOTTOMRIGHT", -26, 6)
  -- bucketScroll.ScrollBar.doNotHide = true  
  self.bucketScroll = bucketScroll

  local bucketContent = CreateFrame("Frame", nil, bucketScroll)
  bucketContent:SetSize(360, 400) -- Default size, will be resized by refresh
  bucketScroll:SetScrollChild(bucketContent)
  self.bucketContent = bucketContent

  -- LEFT (BOTTOM): level ---------------------------------------------------
  -- NEW: This entire block is a copy of the 'left' panel block above
  local levelPanel = CreateFrame("Frame", nil, f)
  levelPanel:SetPoint("TOPLEFT", left, "BOTTOMLEFT", 0, -GAP) -- Anchor to panel above
  levelPanel:SetPoint("BOTTOMLEFT", 8, BOTTOM_PAD)             -- Anchor to frame bottom
  levelPanel:SetWidth(380)
  local levelPanelBg = levelPanel:CreateTexture(nil, "BACKGROUND")
  levelPanelBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
  levelPanelBg:SetVertexColor(0, 0, 0, .95)
  levelPanelBg:SetAllPoints()
  self.levelPanel = levelPanel

  local levelHdr = levelPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  levelHdr:SetPoint("TOPLEFT", LEFT_PAD, -8)
  levelHdr:SetText("Gold by Level")

  -- NEW: This block is a copy of the 'bucketScroll' block above
  local levelScroll = CreateFrame("ScrollFrame", "LB_FinLevelScroll", levelPanel, "UIPanelScrollFrameTemplate")
  levelScroll:SetPoint("TOPLEFT", LEFT_PAD-2, -28)
  levelScroll:SetPoint("BOTTOMRIGHT", -26, 6)
  -- levelScroll.ScrollBar.doNotHide = true
  self.levelScroll = levelScroll

  local levelContent = CreateFrame("Frame", nil, levelScroll)
  levelContent:SetSize(360, 400) -- Default size, will be resized by refresh
  levelScroll:SetScrollChild(levelContent)
  self.levelContent = levelContent

  -- RIGHT: ledger ----------------------------------------------------------
  local right = CreateFrame("Frame", nil, f)
  right:SetPoint("TOPLEFT", left, "TOPRIGHT", 8, 0)      -- Anchor to top-left panel
  right:SetPoint("BOTTOMRIGHT", levelPanel, "BOTTOMRIGHT", 8, 0) -- Anchor to bottom-left panel
  right:SetPoint("TOPLEFT", 380 + 8 + 8, -TOP_PAD) -- Use constants for anchoring
  right:SetPoint("BOTTOMRIGHT", -8, BOTTOM_PAD)
  
  local rightBg = right:CreateTexture(nil, "BACKGROUND")
  rightBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
  rightBg:SetVertexColor(0, 0, 0, 0.95)
  rightBg:SetAllPoints()
  self.right = right

  -- header
  local hdr = CreateFrame("Frame", nil, right)
  hdr:SetPoint("TOPLEFT", 0, 0); hdr:SetPoint("TOPRIGHT", 0, 0); hdr:SetHeight(22)
  local hdrBg = hdr:CreateTexture(nil, "BACKGROUND")
  hdrBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background"); hdrBg:SetVertexColor(0, 0, 0, 0.95)
  hdrBg:SetAllPoints()

  -- fixed, safe column widths
  local IDW, DATEW, TYPEW, SRCW, AMTW, RUNW, GAP = 46, 140, 76, 80, 120, 140, 8
  self._cols = { IDW=IDW, DATEW=DATEW, TYPEW=TYPEW, SRCW=SRCW, AMTW=AMTW, RUNW=RUNW, GAP=GAP }

  local H = {}
  local function mkH(key, text, x, w, just)
    local fs = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", x, 0); fs:SetWidth(w); fs:SetJustifyH(just or "LEFT"); fs:SetText(text)
    H[key] = fs
    return x + w + GAP
  end
  self._mkHeader = mkH
  self.hCols = H

  -- list area + FauxScrollFrame
  local list = CreateFrame("Frame", nil, right)
  list:SetPoint("TOPLEFT", 0, -22)
  list:SetPoint("BOTTOMRIGHT", 0, 0)
  self.list = list

  local scroll = CreateFrame("ScrollFrame", "LB_FinLedgerScroll", list, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 0, -2)
  scroll:SetPoint("BOTTOMRIGHT", -SCROLLBAR_W, 2)
  self.scroll = scroll

  self.rows = {}
  self._visibleRows = 0

  -- recompute rows to fill to bottom
  local function recomputeRows()
    local h = list:GetHeight() - 4
    local need = max(5, floor(h / ROW_H))
    if need ~= self._visibleRows then
      for _, r in ipairs(self.rows) do r:Hide() end
      self.rows = {}
      local prev
      for i=1, need do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(ROW_H)
        row:SetPoint("LEFT", 0, 0)
        row:SetPoint("RIGHT", -SCROLLBAR_W, 0)
        if not prev then row:SetPoint("TOP", list, "TOP", 0, -2)
        else row:SetPoint("TOP", prev, "BOTTOM", 0, 0) end
        prev = row

        local alt = row:CreateTexture(nil, "BACKGROUND")
        alt:SetAllPoints()
        alt:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
		alt:SetVertexColor(0.07, 0.07, 0.07, 0.9)
        row.altBG = alt

        -- create fonts; position later
        local id   = row:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        local dt   = row:CreateFontString(nil,"OVERLAY","GameFontWhiteSmall")
        local typ  = row:CreateFontString(nil,"OVERLAY","GameFontWhiteSmall")
        local src  = row:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        local amt  = row:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        local run  = row:CreateFontString(nil,"OVERLAY","GameFontWhiteSmall")
        row.cols = { id=id, dt=dt, typ=typ, src=src, amt=amt, run=run }

        self.rows[i] = row
      end
      self._visibleRows = need
      if self._positionColumns then self:_positionColumns() end
    end
  end
  self._recomputeRows = recomputeRows

  -- order matters: rows then columns then refresh
  f:SetScript("OnShow", function() self:_recomputeRows(); self:_positionColumns(); self:Refresh() end)
  f:SetScript("OnSizeChanged", function() self:_recomputeRows(); self:_positionColumns(); self:Refresh() end)
  self.scroll:SetScript("OnVerticalScroll", function(selfSF, delta)
    FauxScrollFrame_OnVerticalScroll(selfSF, delta, ROW_H, function() Dev:Refresh() end)
  end)

  self:Refresh()
end

function Dev:_positionColumns()
  local C = self._cols
  local IDW, DATEW, TYPEW, SRCW, AMTW, RUNW, GAP = C.IDW, C.DATEW, C.TYPEW, C.SRCW, C.AMTW, C.RUNW, C.GAP

  -- header positions
  local x = 8
  self._mkHeader("ID",     "ID",     x, IDW,   "LEFT");  x = x + IDW + GAP
  self._mkHeader("DATE",   "Date",   x, DATEW, "LEFT");  x = x + DATEW + GAP
  self._mkHeader("TYPE",   "Type",   x, TYPEW, "LEFT");  x = x + TYPEW + GAP
  self._mkHeader("SRC",    "Source", x, SRCW,  "LEFT");  x = x + SRCW + GAP
  self._mkHeader("AMOUNT", "Amount", x, AMTW,  "RIGHT"); x = x + AMTW + GAP
  self._mkHeader("RUN",    "Running",x, RUNW,  "RIGHT")

  -- rows
  for _, row in ipairs(self.rows) do
    local cols = row.cols
    x = 8
    cols.id:ClearAllPoints();   cols.id:SetPoint  ("LEFT", row, "LEFT", x, 0); cols.id:SetWidth(IDW);   cols.id:SetJustifyH("LEFT");  x = x + IDW + GAP
    cols.dt:ClearAllPoints();   cols.dt:SetPoint  ("LEFT", row, "LEFT", x, 0); cols.dt:SetWidth(DATEW); cols.dt:SetJustifyH("LEFT");  x = x + DATEW + GAP
    cols.typ:ClearAllPoints();  cols.typ:SetPoint ("LEFT", row, "LEFT", x, 0); cols.typ:SetWidth(TYPEW);cols.typ:SetJustifyH("LEFT"); x = x + TYPEW + GAP
    cols.src:ClearAllPoints();  cols.src:SetPoint ("LEFT", row, "LEFT", x, 0); cols.src:SetWidth(SRCW); cols.src:SetJustifyH("LEFT");  x = x + SRCW + GAP
    cols.amt:ClearAllPoints();  cols.amt:SetPoint ("LEFT", row, "LEFT", x, 0); cols.amt:SetWidth(AMTW); cols.amt:SetJustifyH("RIGHT"); x = x + AMTW + GAP
    cols.run:ClearAllPoints();  cols.run:SetPoint ("LEFT", row, "LEFT", x, 0); cols.run:SetWidth(RUNW); cols.run:SetJustifyH("RIGHT")
  end
end

function Dev:Toggle()
  if not self.frame then self:OnInitialize() end
  if self.frame:IsShown() then self.frame:Hide() else self.frame:Show(); self:Refresh() end
end

-- left: buckets -----------------------------------------------------------
local function clearChildren(frame)
  if not frame then return end
  local kids = { frame:GetChildren() }
  for _, child in ipairs(kids) do child:Hide(); child:SetParent(nil) end
end

local function FS(parent, template) return parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall") end

function Dev:_refreshBuckets()
  -- title with current money
  if self._titleFS then
    local cur = (GetMoney and GetMoney()) or 0
    self._titleFS:SetText("DragonBags Finance — Dev   |   Current: "..GetMoneyString(cur,true))
  end

  -- Use robust destroy/recreate method
  if self.bucketContent then
    self.bucketContent:Hide()
    clearChildren(self.bucketContent)
    self.bucketContent:SetParent(nil)
  end
  self.bucketContent = CreateFrame("Frame", nil, self.bucketScroll)
  self.bucketContent:SetSize(360, 400) -- Default size
  self.bucketScroll:SetScrollChild(self.bucketContent)

  local keys = (Data and Data.GetDailyKeys and Data:GetDailyKeys()) or {}

  local y = -2
  if #keys == 0 then
    local fs = FS(self.bucketContent, "GameFontDisable")
    fs:SetPoint("TOPLEFT", LEFT_PAD, y)
    fs:SetText("No daily buckets yet.")
    self.bucketContent:SetHeight(40)
    return
  end

  for _, day in ipairs(keys) do
    local b = Data:GetDailyTotals(day)
    if b and b.overall and b.by_source then
      local o = b.overall
      -- Day header: NET only + count
      local hdr = FS(self.bucketContent, "GameFontNormal")
      hdr:SetPoint("TOPLEFT", LEFT_PAD, y)
      hdr:SetText( string.format("|cffffffff%s|r   Net %s   |cffaaaaaa(x%d)|r",
        day, moneySigned(o.net or 0), o.count or 0) )
      y = y - 18

      -- Column headers: Source | Gained | Spent | Cnt
      local h_src  = FS(self.bucketContent, "GameFontDisableSmall"); h_src:SetPoint("TOPLEFT", LEFT_PAD, y);           h_src:SetWidth(80);   h_src:SetJustifyH("LEFT");  h_src:SetText("Source")
      local h_g    = FS(self.bucketContent, "GameFontDisableSmall"); h_g:SetPoint   ("TOPLEFT", LEFT_PAD+98, y);       h_g:SetWidth(90);   h_g:SetJustifyH("RIGHT"); h_g:SetText("Gained")
      local h_s    = FS(self.bucketContent, "GameFontDisableSmall"); h_s:SetPoint   ("TOPLEFT", LEFT_PAD+198, y);      h_s:SetWidth(90);   h_s:SetJustifyH("RIGHT"); h_s:SetText("Spent")
      local h_c    = FS(self.bucketContent, "GameFontDisableSmall"); h_c:SetPoint   ("TOPLEFT", LEFT_PAD+298, y);      h_c:SetWidth(36);   h_c:SetJustifyH("RIGHT"); h_c:SetText("Cnt")
      y = y - 14

      -- per-source lines
      local srcs = {}
      for s,t in pairs(b.by_source) do
        tinsert(srcs, { s=s, g=t.gained or 0, p=t.spent or 0, n=t.net or 0, c=t.count or 0 })
      end
      tsort(srcs, function(a,b2) return abs(a.n) > abs(b2.n) end)

      for _, it in ipairs(srcs) do
        local sfs  = FS(self.bucketContent, "GameFontHighlightSmall"); sfs:SetPoint("TOPLEFT", LEFT_PAD, y);        sfs:SetWidth(80);   sfs:SetJustifyH("LEFT");  sfs:SetText(it.s)
        local gfs  = FS(self.bucketContent, "GameFontWhiteSmall");     gfs:SetPoint("TOPLEFT", LEFT_PAD+98, y);     gfs:SetWidth(90);   gfs:SetJustifyH("RIGHT"); gfs:SetText(moneyPlain(it.g))
        local pfs  = FS(self.bucketContent, "GameFontWhiteSmall");     pfs:SetPoint("TOPLEFT", LEFT_PAD+198, y);    pfs:SetWidth(90);   pfs:SetJustifyH("RIGHT"); pfs:SetText(moneyPlain(it.p))
        local cfs  = FS(self.bucketContent, "GameFontWhiteSmall");     cfs:SetPoint("TOPLEFT", LEFT_PAD+298, y);    cfs:SetWidth(36);   cfs:SetJustifyH("RIGHT"); cfs:SetText(tostring(it.c))
        y = y - 14
      end
      y = y - 8
    end
  end
  self.bucketContent:SetHeight(-y + 10)
end

-- NEW: Refresher for the level panel
function Dev:_refreshLevelData()
  -- Use robust destroy/recreate method
  if self.levelContent then
    self.levelContent:Hide()
    clearChildren(self.levelContent)
    self.levelContent:SetParent(nil)
  end
  self.levelContent = CreateFrame("Frame", nil, self.levelScroll)
  self.levelContent:SetSize(360, 400) -- Default size
  self.levelScroll:SetScrollChild(self.levelContent)

  -- Get data
  local goldData = (Data and Data.GetLevelGold and Data:GetLevelGold()) or {}
  local keys = {}
  for k in pairs(goldData) do tinsert(keys, k) end
  tsort(keys, function(a,b) return a > b end) -- Sort high to low

  local currentLvl = (UnitLevel and UnitLevel("player")) or 0
  local currentGold = (GetMoney and GetMoney()) or 0

  -- Add current level to the top of the list
  if (keys[1] or 0) ~= currentLvl then
    tinsert(keys, 1, currentLvl)
  end

  local y = -2
  if #keys == 0 then
    local fs = FS(self.levelContent, "GameFontDisable")
    fs:SetPoint("TOPLEFT", LEFT_PAD, y)
    fs:SetText("No level data yet.")
    self.levelContent:SetHeight(40)
    return
  end
  
  -- CHANGED: Define column widths, just like in _refreshBuckets
  local LEVEL_W = 200
  local NET_W   = 120

  for _, level in ipairs(keys) do
    level = tonumber(level) or 0
    local levelGold
    local prevLevelGold
    local prevLevel = level - 1
    
    if level == currentLvl then
      -- This is the special "Current Level" row
      levelGold = currentGold
      prevLevelGold = goldData[prevLevel] or 0
    else
      -- This is a past level row
      levelGold = goldData[level] or 0
      prevLevelGold = goldData[prevLevel] or 0
    end
    
    -- Handle level 1, which has no previous level
    if level == 1 then prevLevelGold = 0 end
    
    local net = levelGold - prevLevelGold

    -- CHANGED: Create two separate FontStrings
    
    -- 1. Level Label (Left-aligned)
    local level_fs = FS(self.levelContent, "GameFontNormal")
    level_fs:SetPoint("TOPLEFT", LEFT_PAD, y)
    level_fs:SetWidth(LEVEL_W)
    level_fs:SetJustifyH("LEFT")

    local lvlStr
    if level == currentLvl then
      lvlStr = "|cffffffffLevel "..level.." (Current)|r"
    else
      lvlStr = "|cffccccccLevel "..level.."|r"
    end
    level_fs:SetText(lvlStr)
    
    -- 2. Net Gain Label (Right-aligned)
    local net_fs = FS(self.levelContent, "GameFontNormal")
    net_fs:SetPoint("TOPLEFT", LEFT_PAD + LEVEL_W + 8, y)
    net_fs:SetWidth(NET_W)
    net_fs:SetJustifyH("RIGHT")
    net_fs:SetText(moneySigned(net))
    
    y = y - 18 -- A little more vertical space for readability
  end
  
  self.levelContent:SetHeight(-y + 10)
end


-- right: ledger -----------------------------------------------------------
local function newestFirst(srcLog)
  local out = {}
  for i = #srcLog, 1, -1 do tinsert(out, srcLog[i]) end
  return out
end

function Dev:_refreshLedger()
  if self._recomputeRows then self._recomputeRows() end
  if self._visibleRows <= 0 then return end
  if self._positionColumns then self:_positionColumns() end

  local log = (Data and Data.GetLog and Data:GetLog()) or {}
  if type(log) ~= "table" then log = {} end

  local nlog = newestFirst(log)
  local totalRows = #nlog
  local visible = self._visibleRows

  FauxScrollFrame_Update(self.scroll, totalRows, visible, ROW_H)
  local offset = _G.FauxScrollFrame_GetOffset(self.scroll)

  for i = 1, visible do
    local idx = offset + i
    local row = self.rows[i]
    local e   = nlog[idx]
    if e then
      row:Show()
      local id   = e.id and ("#"..tostring(e.id)) or ""
      local when = date("%Y-%m-%d %H:%M:%S", tonumber(e.ts or e.time or e.timestamp) or time())
      local kind = e.kind or ((tonumber(e.delta or 0) or 0) >= 0 and "gain" or "spend")
      local src  = e.source or e.type or "other"
      local amtS = moneySigned(e.delta)
      local runS = moneyPlain(e.after or 0)

      row.cols.id:SetText(id)
      row.cols.dt:SetText(when)
      row.cols.typ:SetText(kind)
      row.cols.src:SetText(src)
      row.cols.amt:SetText(amtS)
      row.cols.run:SetText(runS)

      row:SetScript("OnEnter", function(selfBtn)
        if not GameTooltip then return end
        GameTooltip:SetOwner(selfBtn, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine((id ~= "" and id.."  " or "")..when, 1,1,1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Type",    tostring(kind), .8,.8,.8, 1,1,1)
        GameTooltip:AddDoubleLine("Source",  tostring(src),  .8,.8,.8, 1,1,1)
        GameTooltip:AddDoubleLine("Delta",   amtS,           .8,.8,.8, 1,1,1)
        GameTooltip:AddDoubleLine("Before",  moneyPlain(e.before or 0), .8,.8,.8, 1,1,1)
        GameTooltip:AddDoubleLine("After",   moneyPlain(e.after  or 0), .8,.8,.8, 1,1,1)
        if e.level then GameTooltip:AddDoubleLine("Level", tostring(e.level), .8,.8,.8, 1,1,1) end
        if e.player or e.realm then
          local who = (tostring(e.player or "?").." - "..tostring(e.realm or ""))
          GameTooltip:AddDoubleLine("Character", who, .8,.8,.8, 1,1,1)
        end
        if e.zone or e.subzone then
          local loc = e.zone or ""
          if e.subzone and e.subzone ~= "" then
            if loc ~= "" then loc = loc.." — "..e.subzone else loc = e.subzone end
          end
          if loc ~= "" then GameTooltip:AddDoubleLine("Location", loc, .8,.8,.8, 1,1,1) end
        end
        if e.sessionID then
          GameTooltip:AddDoubleLine("Session", tostring(e.sessionID), .8,.8,.8, 1,1,1)
        end
        if e.note then
          GameTooltip:AddLine(" ")
          GameTooltip:AddLine(tostring(e.note), .9,.9,1, true)
        end
        GameTooltip:Show()
      end)
      row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    else
      row:Hide()
      row:SetScript("OnEnter", nil)
      row:SetScript("OnLeave", nil)
    end
  end
end

-- public ------------------------------------------------------------------
function Dev:Refresh()
  if not self.frame or not self.frame:IsShown() then return end
  self:_refreshBuckets()
  self:_refreshLevelData() -- ADDED: Call the new refresh function
  self:_refreshLedger()
end

-- slash -------------------------------------------------------------------
if not SlashCmdList["LBFINDEV"] then
  SLASH_LBFINDEV1 = "/lbfindev"
  SlashCmdList["LBFINDEV"] = function()
    if addon._FinanceDev and addon._FinanceDev.Toggle then addon._FinanceDev:Toggle() end
  end
end