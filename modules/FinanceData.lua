--[[-----------------------------------------------------------------------------
FinanceData.lua
DragonBags — Finance (Rock Solid Warehouse Edition)

Core Contract:
  1) Log every transaction with a unique, permanent ID.
  2) When the hot log exceeds 1100, move the oldest 100 to db.archive.
  3) Maintain Daily Buckets and Level Snapshots for UI performance.
  4) Maintain a persistent "master_totals" table for cumulative category tracking.
  5) HARDENED: Mathematically recovers missing delta values from snapshots.
  6) VERIFICATION: Auto-fixes misclassified Mail/AH entries during audits.
-----------------------------------------------------------------------------]]--

local addonName, addon = ...
local Data = {}
addon._FinanceData = Data

-- Root SavedVariables table
DragonBagsFinanceDB = DragonBagsFinanceDB or {}

-- MANDATORY DEBUG FLAG: Set to true for logic pulses
local DEBUG_MODE = false

-- ─────────────────────────────────────────────────────────────────────────────
-- INTERNAL UTILITIES
-- ─────────────────────────────────────────────────────────────────────────────

-- Internal debugger for tracking data flow
local function dbg(msg)
    if DEBUG_MODE then
        _G.DEFAULT_CHAT_FRAME:AddMessage("|cff66ffcc[FinanceData DBG]:|r "..tostring(msg))
    end
end

-- Generates the key for SavedVariables indexing (Player - Realm)
local function charKey()
  local p = (_G.UnitName and _G.UnitName("player")) or "?"
  local r = (_G.GetRealmName and _G.GetRealmName()) or "?"
  return p .. " - " .. r
end

-- Formats a timestamp into a YYYY-MM-DD bucket key
local function ymd(ts)
  local t = _G.date("*t", ts)
  return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
end

-- Ensures all required tables and default values exist in SavedVariables
local function ensureCharDB()
  local key = charKey()
  local db = DragonBagsFinanceDB[key]
  if not db then
    db = {}
    DragonBagsFinanceDB[key] = db
  end

  -- Master running totals for the 18 specific categories used by the UI
  db.master_totals = db.master_totals or {}
  local cats = {
    "loot_solo", "loot_group", "loot_instance", "quest_in", 
    "merchant_sell", "auction_sell", "mail_in", "trade_in",
    "repair_out", "merchant_buy", "auction_buy", "trainer_out", 
    "taxi_out", "mail_out", "trade_out", "other_in", "other_out", "opening"
  }
  for _, cat in _G.ipairs(cats) do
      db.master_totals[cat] = db.master_totals[cat] or 0
  end

  db.transaction_log = db.transaction_log or {}
  db.archive         = db.archive or {}      -- Persistent Warehouse storage
  db.next_id         = db.next_id or (#db.transaction_log + 1)
  db.lastMoney       = db.lastMoney or nil
  db.logLimit        = db.logLimit or 1000   
  db.daily           = db.daily or { window = 30, buckets = {} }
  db.daily.buckets   = db.daily.buckets or {}
  db.level_gold      = db.level_gold or {}
  return db
end

-- ─────────────────────────────────────────────────────────────────────────────
-- WAREHOUSE & CLEANUP LOGIC
-- ─────────────────────────────────────────────────────────────────────────────

-- Removes daily bucket data older than the configured window
local function prune_old_buckets(db)
  local window = tonumber(db.daily.window or 30) or 30
  local keys = {}
  for k in pairs(db.daily.buckets) do _G.table.insert(keys, k) end
  _G.table.sort(keys)
  local keep = {}
  for i = _G.math.max(1, #keys - window + 1), #keys do
    keep[keys[i]] = true
  end
  for k in pairs(db.daily.buckets) do
    if not keep[k] then db.daily.buckets[k] = nil end
  end
end

-- ARCHIVE LOGIC: Moves oldest 100 entries to db.archive when log hits High Water Mark
local function prune_transaction_log(db)
  local limit = tonumber(db.logLimit or 1000) or 1000
  local log = db.transaction_log
  
  if limit == 0 then return end
  
  if #log > (limit + 100) then
    dbg("Log limit exceeded ("..#log.."). Archiving oldest 100 entries...")
    for i = 1, 100 do
        local entry = _G.table.remove(log, 1) -- Remove from live log
        _G.table.insert(db.archive, entry)    -- Move to warehouse
    end
    dbg("Archiving complete. New log size: "..#log)
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- AGGREGATION HELPERS
-- ─────────────────────────────────────────────────────────────────────────────

-- Updates master totals and daily gains/spent/net totals
local function add_to_buckets(db, ts, delta, source)
  delta = tonumber(delta) or 0
  if delta == 0 then return end

  -- Update Master running total
  if db.master_totals[source] then
      db.master_totals[source] = db.master_totals[source] + delta
  else
      db.master_totals["other_in"] = (db.master_totals["other_in"] or 0) + delta
  end

  local key = ymd(ts)
  db.daily.buckets[key] = db.daily.buckets[key] or {}
  local b = db.daily.buckets[key]
  
  b.overall = b.overall or { gained=0, spent=0, net=0, count=0 }
  b.by_source = b.by_source or {}

  -- Update Overall Statistics
  if delta >= 0 then b.overall.gained = b.overall.gained + delta
  else b.overall.spent = b.overall.spent + (-delta) end
  b.overall.net = b.overall.net + delta
  b.overall.count = b.overall.count + 1

  -- Update Source-specific Statistics
  local s = b.by_source[source] or { gained=0, spent=0, net=0, count=0 }
  if delta >= 0 then s.gained = s.gained + delta
  else s.spent = s.spent + (-delta) end
  s.net = s.net + delta
  s.count = s.count + 1
  b.by_source[source] = s
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PUBLIC API
-- ─────────────────────────────────────────────────────────────────────────────


-- Initializes the database
function Data:Init()
  local db = ensureCharDB()
  if type(db.lastMoney) ~= "number" then
    db.lastMoney = _G.GetMoney() or 0
  end
  prune_old_buckets(db)
  prune_transaction_log(db)
  dbg("Data module initialized for " .. charKey())
end

-- Saves a new transaction, assigns a unique ID, and triggers archiving if full
function Data:Append(e)
  local db = ensureCharDB()
  if not e then return end

  -- RECOVERY GUARD: If delta is missing but snapshots exist, recover it
  if (not e.delta or e.delta == 0) and e.after and e.before then
      e.delta = e.after - e.before
      dbg("RECOVERY: Calculated missing delta for entry.")
  end

  if e.delta == 0 then return end

  if not e.id then
    e.id = db.next_id
    db.next_id = e.id + 1
  else
    db.next_id = _G.math.max(db.next_id, e.id + 1)
  end

  e.ts = e.ts or _G.time()
  e.player = e.player or _G.UnitName("player")
  e.realm = e.realm or _G.GetRealmName()

  _G.table.insert(db.transaction_log, e)
  db.lastMoney = e.after
  
  add_to_buckets(db, e.ts, e.delta, e.source)
  db.level_gold[e.level or 1] = e.after
  
  prune_transaction_log(db)
  return e
end

-- Full audit: Re-calculates master_totals and fixes misclassifications
function Data:RecalculateAllTotals()
    local db = ensureCharDB()
    dbg("Starting Master Audit. Synchronizing ledger with snapshots...")

    -- Reset the master totals
    for k, _ in pairs(db.master_totals) do db.master_totals[k] = 0 end

    local function audit_list(list)
        for _, entry in _G.ipairs(list) do
            -- Safety Recovery: Attempt to fix missing delta math
            local amount = tonumber(entry.delta) or (entry.after and entry.before and (entry.after - entry.before)) or 0
            local src = entry.source or "other_in"
            local note = entry.note or ""

            -- VERIFICATION: Fix generic Mail labels if the Note confirms it was AH
            if src == "mail_in" and (note:find("Auction") or note:find("AH")) then
                src = "auction_sell"
                entry.source = "auction_sell" -- Correct the entry permanently
                dbg("AUDIT FIX: Transaction #" .. (entry.id or "?") .. " moved to Auction Sell based on Note.")
            end

            -- Ensure modern category names
            if src == "looted" or src == "looted_solo" then src = "loot_solo" end
            if src == "looted_group" then src = "loot_group" end
            if src == "looted_instance" then src = "loot_instance" end
            if src == "ah_income" then src = "auction_sell" end
            
            if db.master_totals[src] then
                db.master_totals[src] = db.master_totals[src] + amount
            else
                db.master_totals["other_in"] = (db.master_totals["other_in"] or 0) + amount
            end
        end
    end

    audit_list(db.archive)
    audit_list(db.transaction_log)
    dbg("Audit complete. All categories updated.")
end

-- Reverses the effects of a transaction on totals
function Data:UndoBucketEffect(ts, delta, source)
    local db = ensureCharDB()
    delta = tonumber(delta) or 0
    
    if db.master_totals[source] then
        db.master_totals[source] = db.master_totals[source] - delta
    end

    local key = ymd(ts)
    local b = db.daily.buckets[key]
    if not b then return end
    
    b.overall.gained = b.overall.gained - (delta >= 0 and delta or 0)
    b.overall.spent  = b.overall.spent  - (delta < 0 and (-delta) or 0)
    b.overall.net    = b.overall.net    - delta
    b.overall.count  = b.overall.count  - 1

    local s = b.by_source[source]
    if s then
        s.gained = s.gained - (delta >= 0 and delta or 0)
        s.spent  = s.spent  - (delta < 0 and (-delta) or 0)
        s.net    = s.net    - delta
        s.count  = s.count  - 1
        if s.count == 0 then b.by_source[source] = nil end
    end
end



-- [[ FinanceData.lua: Manual Bucket Update Helper ]]

function Data:UpdateBucketsManual(ts, delta, source)
    local db = ensureCharDB()
    -- Re-use the existing internal logic to update master totals and daily buckets
    add_to_buckets(db, ts, delta, source)
    dbg("Data: Manual bucket update complete for " .. source)
end


-- Accessors
function Data:GetLog() return ensureCharDB().transaction_log end
function Data:GetArchive() return ensureCharDB().archive end
function Data:GetLogLimit() return ensureCharDB().logLimit or 1000 end
function Data:SetLogLimit(n)
  local db = ensureCharDB()
  db.logLimit = _G.math.max(500, _G.tonumber(n) or 1000)
  prune_transaction_log(db)
end