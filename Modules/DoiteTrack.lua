---------------------------------------------------------------
-- DoiteTrack.lua
-- Dynamic aura duration recorder + runtime remaining-time API
-- WoW 1.12 | Lua 5.0
---------------------------------------------------------------

local DoiteTrack = {}
_G["DoiteTrack"] = DoiteTrack

---------------------------------------------------------------
-- DB wiring
---------------------------------------------------------------
local function _GetDB()
    local db = _G["DoiteAurasDB"]

    -- If the core addon hasn’t created it yet, create a minimal one.
    if not db then
        db = {}
        _G["DoiteAurasDB"] = db
    end

    db.trackedDurations     = db.trackedDurations     or {}  -- [spellId] = seconds (no combo)
    db.trackedDurationsCP   = db.trackedDurationsCP   or {}  -- [spellId] = { [cp] = seconds }
    db.trackedDurationsMeta = db.trackedDurationsMeta or {}  -- meta info (name, rank, samples, etc.)

    return db
end

-- Global maps
local TrackedBySpellId      = {}  -- [spellId] = entry
local TrackedByNameNorm     = {}  -- [normName] = entry
local RecentCastBySpellId   = {}  -- [spellId] = lastCastTime

---------------------------------------------------------------
-- Local API shortcuts
---------------------------------------------------------------
local GetTime        = GetTime
local UnitClass      = UnitClass
local UnitExists     = UnitExists
local UnitIsDead     = UnitIsDead
local UnitBuff       = UnitBuff
local UnitDebuff     = UnitDebuff
local GetComboPoints = GetComboPoints

local SpellInfo                = SpellInfo
local GetSpellRecField         = GetSpellRecField
local GetSpellNameAndRankForId = GetSpellNameAndRankForId
local GetSpellIdForName        = GetSpellIdForName
local GetUnitField             = GetUnitField

local str_find = string.find
local str_gsub = string.gsub

---------------------------------------------------------------
-- Utility helpers
---------------------------------------------------------------
local function _Print(msg, r, g, b)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(msg or "", r or 1.0, g or 1.0, b or 1.0)
    end
end

-- Player GUID cache (for SuperWoW's UnitExists return)
local _playerGUID_cached = nil

local function _GetUnitGuidSafe(unit)
    if not unit or not UnitExists then
        return nil
    end

    -- SuperWoW: UnitExists(unit) returns existsFlag, guid
    local exists, guid = UnitExists(unit)
    if exists and guid and guid ~= "" then
        return guid
    end

    return nil
end

local function _GetPlayerGUID()
    if _playerGUID_cached then
        return _playerGUID_cached
    end
    local g = _GetUnitGuidSafe("player")
    if g and g ~= "" then
        _playerGUID_cached = g
        return g
    end
    return nil
end

local function _PlayerUsesComboPoints()
    if not UnitClass then return false end
    local _, cls = UnitClass("player")
    cls = cls and string.upper(cls) or ""
    return (cls == "ROGUE" or cls == "DRUID")
end

local function _GetComboPointsSafe()
    if not GetComboPoints then
        return 0
    end

    local ok, val = pcall(GetComboPoints)
    if ok and type(val) == "number" and val >= 0 then
        return val
    end

    return 0
end

-- Find which visible unit currently matches a GUID.
local function _FindUnitByGuid(guid)
    if not guid or guid == "" then return nil end

    local pg = _GetPlayerGUID()
    if pg and pg == guid then
        return "player"
    end

    if UnitExists and UnitExists("target") then
        local tg = _GetUnitGuidSafe("target")
        if tg and tg == guid then
            return "target"
        end
    end

    return nil
end

---------------------------------------------------------------
-- SpellDuration.dbc: id -> duration (seconds)
---------------------------------------------------------------
local SpellDurationSec = {
    [1] = 10,
    [2] = 30,
    [3] = 60,
    [4] = 120,
    [5] = 300,
    [6] = 600,
    [7] = 5,
    [8] = 15,
    [9] = 30,
    [10] = 60,
    [11] = 10,
    [12] = 30,
    [13] = 60,
    [14] = 120,
    [15] = 300,
    [16] = 230,
    [17] = 5,
    [18] = 20,
    [19] = 30,
    [20] = 60,
    -- 21 has -1 -> infinite, intentionally ignored
    [22] = 45,
    [23] = 90,
    [24] = 160,
    [25] = 180,
    [26] = 240,
    [27] = 3,
    [28] = 5,
    [29] = 12,
    [30] = 1800,
    [31] = 8,
    [32] = 6,
    [35] = 4,
    [36] = 1,
    [37] = 0.001,
    [38] = 11,
    [39] = 2,
    [40] = 1200,
    [41] = 360,
    [42] = 3600,
    [62] = 75,
    [63] = 25,
    [64] = 40,
    [65] = 1.5,
    [66] = 2.5,
    [85] = 18,
    [86] = 21,
	-- 87 Rip / Druid / SpellDurationSecCP
    [105] = 9,
    [106] = 24,
    [125] = 35,
    [145] = 2700,
    [165] = 7,
    [185] = 6,
    [186] = 2,
    -- 187 has 0 duration, intentionally ignored
    [205] = 27,
    [225] = 604800,
    [245] = 50,
    [265] = 55,
    [285] = 1,
    [305] = 14,
    [325] = 36,
    [326] = 44,
    [327] = 0.5,
    [328] = 0.25,
    [347] = 900,
    [367] = 7200,
    [387] = 16,
    [407] = 0.1,
    -- 427 has negative duration / scaling, intentionally ignored
    [447] = 2,
    [467] = 22,
    [468] = 26,
    [487] = 1.7,
    [507] = 1.1,
    [508] = 1.1,
    [527] = 14400,
    [547] = 5400,
    [548] = 10800,
    [549] = 3.8,
    [552] = 210,
    [553] = 6,
}

-- CP-specific overrides keyed by durationIndex
local SpellDurationSecCP = {
    [87] = { -- Rip (Rank 6)/(9896)
        [1] = 10,
        [2] = 12,
        [3] = 14,
        [4] = 16,
        [5] = 18,
    },
}

---------------------------------------------------------------
-- DBC duration helper (durationIndex -> SpellDurationSec / SpellDurationSecCP)
---------------------------------------------------------------
local function _GetDBCBaseDuration(spellId, cp)
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then
        return nil
    end
    if not GetSpellRecField then
        return nil
    end

    -- durationIndex field confirmed working via /run probe
    local ok, idx = pcall(GetSpellRecField, spellId, "durationIndex")
    if not ok or type(idx) ~= "number" or idx <= 0 then
        return nil
    end

    -- 1) CP-specific override table, if present
    if cp and cp > 0 then
        local cpMap = SpellDurationSecCP[idx]
        if cpMap then
            local secCP = cpMap[cp]
            if type(secCP) == "number" and secCP > 0 then
                return secCP
            end
        end
    end

    -- 2) Flat numeric duration for this durationIndex
    local sec = SpellDurationSec[idx]
    if type(sec) == "number" and sec > 0 then
        return sec
    end

    return nil
end

---------------------------------------------------------------
-- Combo-point duration helper (using Nampower DBC)
---------------------------------------------------------------
local CPDurationCache = {}  -- [spellId] = true/false

local function _SpellUsesComboDuration(spellId)
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then
        return false
    end

    -- Cache hit?
    local cached = CPDurationCache[spellId]
    if cached ~= nil then
        return cached
    end

    local uses = false

    if GetSpellRecField then
        local ok, arr = pcall(GetSpellRecField, spellId, "effectPointsPerComboPoint", 1)
        if (not ok) or type(arr) ~= "table" then
            ok, arr = pcall(GetSpellRecField, spellId, "effectPointsPerComboPoint")
        end

        if ok and type(arr) == "table" then
            for i = 1, table.getn(arr) do
                local v = arr[i]
                if type(v) == "number" and v ~= 0 then
                    uses = true
                    break
                end
            end
        end
    end

    CPDurationCache[spellId] = uses and true or false
    return uses
end

---------------------------------------------------------------
-- Core DB access helpers
---------------------------------------------------------------
local function _GetTrackedFlatDuration(spellId)
    local db = _GetDB()
    return db.trackedDurations[spellId]
end

local function _GetTrackedCPDuration(spellId, cp)
    if not cp or cp <= 0 then return nil end
    local db = _GetDB()
    local t = db.trackedDurationsCP[spellId]
    if not t then return nil end
    return t[cp]
end

-- Baseline duration lookup in priority order:
--  1) DBC duration via SpellDuration.dbc (durationIndex -> SpellDurationSec)
--  2) CP-specific tracked duration (if cp > 0)
--  3) Flat tracked duration (no CP)
local function _GetBaselineDuration(spellId, cp)
    local d

    -- 1) Static DBC duration (optionally CP-specific), if available
    d = _GetDBCBaseDuration(spellId, cp)
    if d and d > 0 then
        return d
    end

    -- 2) CP-specific tracked duration
    if cp and cp > 0 then
        d = _GetTrackedCPDuration(spellId, cp)
        if d and d > 0 then
            return d
        end
    end

    -- 3) Flat tracked duration
    d = _GetTrackedFlatDuration(spellId)
    if d and d > 0 then
        return d
    end

    return nil
end

local function _ShouldRecord(spellId, cp)
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then
        return false
    end

    -- If SpellDurationSec / SpellDurationSecCP already knows this spell's duration, do NOT record again.
    local dbc = _GetDBCBaseDuration(spellId, cp)
    if dbc and dbc > 0 then
        return false
    end

    -- Otherwise fall back to the dynamic tracking rules:
    --  1) CP-specific measurement if cp > 0 and missing
    --  2) Flat measurement if no CP data and flat missing
    if cp and cp > 0 then
        local exist = _GetTrackedCPDuration(spellId, cp)
        if exist and exist > 0 then
            return false
        end
        return true
    end

    local flat = _GetTrackedFlatDuration(spellId)
    if flat and flat > 0 then
        return false
    end

    return true
end

local function _CommitDuration(spellId, spellName, spellRank, cp, measuredSec)
    if not spellId or spellId <= 0 then return end
    if not measuredSec or measuredSec <= 0 then return end

    local db  = _GetDB()
    local sec = math.floor(measuredSec + 0.5)

    if cp and cp > 0 then
        db.trackedDurationsCP[spellId] = db.trackedDurationsCP[spellId] or {}
        if not db.trackedDurationsCP[spellId][cp] then
            db.trackedDurationsCP[spellId][cp] = sec
        end
    else
        if not db.trackedDurations[spellId] then
            db.trackedDurations[spellId] = sec
        end
    end

    local meta = db.trackedDurationsMeta[spellId]
    if not meta then
        meta = { name = spellName, rank = spellRank, samples = 0 }
        db.trackedDurationsMeta[spellId] = meta
    end
    meta.samples = (meta.samples or 0) + 1

    if spellName and spellName ~= "" then
        meta.name = spellName
    end
    if spellRank and spellRank ~= "" then
        meta.rank = spellRank
    end
end

---------------------------------------------------------------
-- Normalise names so match by "Rend" across ranks
---------------------------------------------------------------
local function _NormSpellName(name)
    if not name or name == "" then return nil end

    -- trim
    name = string.gsub(name, "^%s+", "")
    name = string.gsub(name, "%s+$", "")

    name = string.lower(name)

    -- strip " (Rank X)" and " Rank X"
    name = string.gsub(name, "%s*%(rank%s*%d+%)", "")
    name = string.gsub(name, "%s*rank%s*%d+", "")

    -- trim again (after gsubs)
    name = string.gsub(name, "^%s+", "")
    name = string.gsub(name, "%s+$", "")

    return name
end

---------------------------------------------------------------
-- Scan DoiteAuras config for which buffs/debuffs should be tracked
---------------------------------------------------------------
local function _AddTrackedFromEntry(key, data)
    if not data or type(data) ~= "table" then return end

    -- Must be buff/debuff
    if data.type ~= "Buff" and data.type ~= "Debuff" then
        return
    end

    local c = data.conditions and data.conditions.aura
    if not c then
        return
    end

    -- Only track explicit "only mine" auras, and only if they target something
    local onlyMine   = (c.onlyMine == true)
    local onlyOthers = (c.onlyOthers == true)
    local hasTarget  = (c.targetSelf or c.targetHelp or c.targetHarm)

    if not hasTarget then
        return
    end

    -- Get spellId if present
    local sid = data.spellid and tonumber(data.spellid)
    if sid and sid <= 0 then
        sid = nil
    end

    local name = data.displayName or data.name or ""
    local norm = _NormSpellName(name)

    if not sid and not norm then
        return
    end

    -- Reuse existing entry if already have it by spellId or name
    local entry
    if sid then
        entry = TrackedBySpellId[sid]
    end
    if not entry and norm then
        entry = TrackedByNameNorm[norm]
    end

    if not entry then
        entry = {
            spellIds   = {},
            name       = name,
            normName   = norm,
            kind       = data.type, -- "Buff" / "Debuff"
            trackSelf  = false,
            trackHelp  = false,
            trackHarm  = false,
            onlyMine    = onlyMine,
            onlyOthers  = onlyOthers,
        }
    else
        -- Preserve ownership flags if any entry requested them
        if entry.onlyMine ~= true and onlyMine then
            entry.onlyMine = true
        end
        if entry.onlyOthers ~= true and onlyOthers then
            entry.onlyOthers = true
        end
    end

    if sid then
        entry.spellIds[sid] = true
        TrackedBySpellId[sid] = entry
    end
    if norm then
        TrackedByNameNorm[norm] = entry
    end

    if c.targetSelf then entry.trackSelf = true end
    if c.targetHelp then entry.trackHelp = true end
    if c.targetHarm then entry.trackHarm = true end
end

-- Does this table look like a spells table (entries with type + conditions.aura)?
local function _LooksLikeSpellConfigTable(tbl)
    if type(tbl) ~= "table" then return false end
    local seen = 0
    for _, v in pairs(tbl) do
        if type(v) == "table" then
            if v.type and v.conditions and v.conditions.aura then
                return true
            end
            seen = seen + 1
            if seen > 20 then break end
        end
    end
    return false
end

-- Walk DoiteAurasDB / DoiteDB to discover where spells actually live.
local function _DiscoverSpellTable()
    local visited = {}

    local function scan(tbl, path)
        if type(tbl) ~= "table" or visited[tbl] then return nil, nil end
        visited[tbl] = true

        if type(tbl.spells) == "table" and _LooksLikeSpellConfigTable(tbl.spells) then
            return tbl.spells, path..".spells"
        end

        for k, v in pairs(tbl) do
            if type(v) == "table" then
                local found, foundPath = scan(v, path.."."..tostring(k))
                if found then return found, foundPath end
            end
        end

        return nil, nil
    end

    local db = _G["DoiteAurasDB"]
    if db then
        local found, path = scan(db, "DoiteAurasDB")
        if found then return found, path end
    end

    if _G["DoiteDB"] then
        local found, path = scan(_G["DoiteDB"], "DoiteDB")
        if found then return found, path end
    end

    return nil, nil
end

function DoiteTrack:RebuildWatchList()
    -- Clear previous maps
    local k
    for k in pairs(TrackedBySpellId) do
        TrackedBySpellId[k] = nil
    end
    for k in pairs(TrackedByNameNorm) do
        TrackedByNameNorm[k] = nil
    end

    local spells = _DiscoverSpellTable()
    if not spells then
        return
    end

    for key, data in pairs(spells) do
        _AddTrackedFromEntry(key, data)
    end
end

_G["DoiteTrack_RebuildWatchList"] = function()
    DoiteTrack:RebuildWatchList()
end

local _lastWatchListRebuild = 0

local function _MaybeRebuildWatchListForSpell(spellId)
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then
        return nil
    end

    local now = GetTime and GetTime() or 0

    if (now - _lastWatchListRebuild) < 1.0 then
        return nil
    end
    _lastWatchListRebuild = now

    DoiteTrack:RebuildWatchList()
    return TrackedBySpellId[spellId]
end

---------------------------------------------------------------
-- Active aura tracking / sessions
---------------------------------------------------------------
local ActiveSessions  = {}
local SessionCounter  = 0
local AuraStateByGuid = {}

local function _GetAuraBucketForGuid(guid, create)
    if not guid or guid == "" then return nil end
    local t = AuraStateByGuid[guid]
    if not t and create then
        t = {}
        AuraStateByGuid[guid] = t
    end
    return t
end

local function _ClearAuraForSession(session)
    if not session or not session.targetGuid or not session.spellId then return end
    local bucket = AuraStateByGuid[session.targetGuid]
    if bucket then
        bucket[session.spellId] = nil
    end
end

local function _RecordAuraForSession(session)
    if not session or not session.targetGuid or not session.spellId then return end
    local bucket = _GetAuraBucketForGuid(session.targetGuid, true)
    if not bucket then return end

    bucket[session.spellId] = {
        appliedAt = session.appliedAt or session.startedAt,
        lastSeen  = session.lastSeen or session.appliedAt or session.startedAt,
        fullDur   = _GetBaselineDuration(session.spellId, session.cp),
        cp        = session.cp or 0,
        isDebuff  = (session.isDebuff == true),
    }
end

-- Find any active session for (spellId, targetGuid)
local function _FindSessionFor(spellId, targetGuid)
    if not spellId or not targetGuid then return nil end
    local id, s
    for id, s in pairs(ActiveSessions) do
        if s.spellId == spellId and s.targetGuid == targetGuid and not s.aborted and not s.complete then
            return id, s
        end
    end
    return nil, nil
end

local function _AbortSession(session, reason)
    if not session or session.aborted or session.complete then return end
    session.aborted      = true
    session.abortReason  = reason or "unknown"
    _ClearAuraForSession(session)
end

local function _FinishSession(session, finalDuration)
    if not session or session.aborted or session.complete then return end
    if not finalDuration or finalDuration <= 0 then
        return
    end

    ----------------------------------------------------------------
    -- Special handling for damage-origin auras like Deep Wounds
    -- that can be kept rolling far beyond their base duration.
    ----------------------------------------------------------------
    if session.source == "damage" and session.spellName then
        local norm = _NormSpellName(session.spellName)
        if norm == "deep wounds" then
            local rounded = math.floor(finalDuration + 0.5)
            if rounded > 7 then
                finalDuration = 6
            else
                finalDuration = rounded
            end
        end
    end

    ----------------------------------------------------------------
    -- Normal completion & commit
    ----------------------------------------------------------------
    session.complete      = true
    session.finalDuration = finalDuration

    -- Only learn / persist when this spell actually needs recording.
    if session.willRecord then
        _CommitDuration(
            session.spellId,
            session.spellName,
            session.spellRank,
            session.cp,
            finalDuration
        )
    end

    -- Always refresh runtime bucket so remaining-time API stays correct.
    _RecordAuraForSession(session)
end

---------------------------------------------------------------
-- Clear helpers (global, per-spell, per-name)
---------------------------------------------------------------
local function _ClearAllTrackedDurations()
    local db = _GetDB()

    -- Wipe persisted measurements
    db.trackedDurations     = {}
    db.trackedDurationsCP   = {}
    db.trackedDurationsMeta = {}

    -- Wipe runtime state so nothing uses old data
    local k
    for k in pairs(AuraStateByGuid) do
        AuraStateByGuid[k] = nil
    end
    for k in pairs(ActiveSessions) do
        ActiveSessions[k] = nil
    end
    SessionCounter = 0

    _Print("|cff6FA8DCDoiteAuras:|r cleared all learned aura durations.")
end

local function _ClearTimersForSpellId(spellId)
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then
        _Print("|cff6FA8DCDoiteAuras:|r bad spellId "..tostring(spellId).." for clear.")
        return
    end

    local db = _GetDB()
    local removedIds = 0

    if db.trackedDurations[spellId] then
        db.trackedDurations[spellId] = nil
        removedIds = removedIds + 1
    end
    if db.trackedDurationsCP[spellId] then
        db.trackedDurationsCP[spellId] = nil
        removedIds = removedIds + 1
    end
    if db.trackedDurationsMeta[spellId] then
        db.trackedDurationsMeta[spellId] = nil
        removedIds = removedIds + 1
    end

    -- Wipe runtime state only for this spellId
    local guid, bucket
    for guid, bucket in pairs(AuraStateByGuid) do
        if bucket[spellId] then
            bucket[spellId] = nil
        end
    end
    local id, s
    for id, s in pairs(ActiveSessions) do
        if s.spellId == spellId then
            ActiveSessions[id] = nil
        end
    end

    if removedIds > 0 then
        _Print("|cff6FA8DCDoiteAuras:|r cleared timers for spellId "..spellId..".")
    else
        _Print("|cff6FA8DCDoiteAuras:|r no timers found for spellId "..spellId..".")
    end
end

local function _ClearTimersForName(normName)
    if not normName or normName == "" then
        _Print("|cff6FA8DCDoiteAuras:|r empty name for clear.")
        return
    end

    local db = _GetDB()
    local clearedIds = {}
    local spellId, meta

    for spellId, meta in pairs(db.trackedDurationsMeta) do
        local mname = meta and meta.name
        local mNorm = _NormSpellName(mname)
        if mNorm and mNorm == normName then
            db.trackedDurations[spellId]      = nil
            db.trackedDurationsCP[spellId]    = nil
            db.trackedDurationsMeta[spellId]  = nil
            clearedIds[spellId] = true
        end
    end

    if not next(clearedIds) then
        _Print("|cff6FA8DCDoiteAuras:|r no timers matched '"..normName.."'.")
        return
    end

    -- Runtime state for all affected spellIds
    local guid, bucket
    for guid, bucket in pairs(AuraStateByGuid) do
        local sid
        for sid in pairs(clearedIds) do
            if bucket[sid] then
                bucket[sid] = nil
            end
        end
    end
    local id, s
    for id, s in pairs(ActiveSessions) do
        if clearedIds[s.spellId] then
            ActiveSessions[id] = nil
        end
    end

    local count = 0
    local sid
    for sid in pairs(clearedIds) do
        count = count + 1
    end

    _Print("|cff6FA8DCDoiteAuras:|r cleared timers for "..normName.." ("..count.." spellId"..(count ~= 1 and "s" or "")..").")
end

_G["DoiteTrack_ClearTimers"] = function(arg)
    -- No argument: nuke everything (old behaviour).
    if not arg or arg == "" then
        _ClearAllTrackedDurations()
        return
    end

    -- Trim spaces
    arg = string.gsub(arg, "^%s+", "")
    arg = string.gsub(arg, "%s+$", "")
    if arg == "" then
        _ClearAllTrackedDurations()
        return
    end

    -- Numeric -> spellId
    local sid = tonumber(arg)
    if sid and sid > 0 then
        _ClearTimersForSpellId(sid)
        return
    end

    -- String -> normalised name, clear all ranks/ids with that meta.name
    local norm = _NormSpellName(arg)
    if not norm then
        _Print("|cff6FA8DCDoiteAuras:|r could not parse name/spellId '"..tostring(arg).."'.")
        return
    end

    _ClearTimersForName(norm)
end

---------------------------------------------------------------
-- Aura presence queries (using SuperWoW's auraId table)
---------------------------------------------------------------
local function _GetUnitAuraTable(unit, isDebuff)
    if not GetUnitField then return nil end

    local function getFieldTable(fieldName)
        -- Try copy=1 first (safe to store/iterate)
        local ok, t = pcall(GetUnitField, unit, fieldName, 1)
        if ok and type(t) == "table" then
            return t
        end

        -- Fallback: older API builds may not accept the copy param
        ok, t = pcall(GetUnitField, unit, fieldName)
        if ok and type(t) == "table" then
            return t
        end

        return nil
    end

    -- Primary field used in this addon so far
    local t = getFieldTable("aura")
    if t then return t end

    -- Fallbacks (harmless if unsupported)
    if isDebuff then
        t = getFieldTable("debuff")
        if t then return t end
    else
        t = getFieldTable("buff")
        if t then return t end
    end

    return nil
end

-- Discover and cache spellIds for an entry by scanning the unit’s aura spellIds,
-- resolving spell name from spellId, and matching normalized name.
local function _CacheMatchingAuraIdsOnUnit(entry, unit)
    if not entry or not entry.normName or not unit then
        return nil
    end

    local auras = _GetUnitAuraTable(unit, entry.kind == "Debuff")
    if type(auras) ~= "table" then
        return nil
    end

    local foundSid = nil

    local function considerSpellId(raw)
        local sid = tonumber(raw) or 0
        if sid <= 0 then return end

        local n = nil
        if GetSpellNameAndRankForId then
            local ok, nn = pcall(GetSpellNameAndRankForId, sid)
            if ok and nn and nn ~= "" then
                n = nn
            end
        end
        if (not n or n == "") and SpellInfo then
            local nn = SpellInfo(sid)
            if type(nn) == "string" and nn ~= "" then
                n = nn
            end
        end

        local norm = _NormSpellName(n)
        if norm and norm == entry.normName then
            entry.spellIds = entry.spellIds or {}
            entry.spellIds[sid] = true
            TrackedBySpellId[sid] = entry
            if not foundSid then
                foundSid = sid
            end
        end
    end

    -- Array-style
    local n = table.getn(auras)
    if n and n > 0 then
        local i
        for i = 1, n do
            considerSpellId(auras[i])
        end
    end

    -- Hash/other-style
    local k, v
    for k, v in pairs(auras) do
        -- if table is { [spellId]=true } or { [1]=spellId, ... } handle both
        considerSpellId(k)
        considerSpellId(v)
    end

    return foundSid
end

-- Based on probe D: GetUnitField("target","aura") returns a table of spellIds.
local function _AuraHasSpellId(unit, spellId, isDebuff)
    spellId = tonumber(spellId) or 0
    if not unit or spellId <= 0 then
        return false
    end

    local auras = _GetUnitAuraTable(unit, isDebuff)
    if type(auras) ~= "table" then
        return false
    end

    -- Hash case: auras[spellId] == true
    if auras[spellId] then
        return true
    end

    -- Array case
    local n = table.getn(auras)
    if n and n > 0 then
        local i
        for i = 1, n do
            if auras[i] == spellId then
                return true
            end
        end
    end

    -- Fallback pairs scan
    local k, v
    for k, v in pairs(auras) do
        if k == spellId or v == spellId then
            return true
        end
    end

    return false
end

---------------------------------------------------------------
-- Pretty name / rank from spellId using Nampower / SuperWoW
-- (both APIs verified by probe E)
---------------------------------------------------------------
local function _GetSpellNameRank(spellId)
    local name, rank

    if GetSpellNameAndRankForId then
        local ok, n, r = pcall(GetSpellNameAndRankForId, spellId)
        if ok and n and n ~= "" then
            name = n
            rank = r
        end
    end

    if (not name or name == "") and SpellInfo then
        -- SpellInfo(spellId) -> name, rank, texture
        local n, r = SpellInfo(spellId)
        if type(n) == "string" and n ~= "" then
            name = n
        end
        if type(r) == "string" and r ~= "" then
            rank = r
        end
    end

    return name or ("Spell " .. tostring(spellId)), rank
end

---------------------------------------------------------------
-- Chat notifications
---------------------------------------------------------------
local function _FormatCPSuffix(cp)
    if not cp or cp <= 0 then return "" end
    return " (" .. tostring(cp) .. " combo points)"
end

local function _NotifyTrackingStart(spellName, cp, isPlayerTarget)
    local label    = "|cff6FA8DCDoiteAuras:|r "
    local nameCol  = "|cffffff00" .. (spellName or "Unknown") .. "|r"
    local cpSuffix = _FormatCPSuffix(cp)
    local tail

    if isPlayerTarget then
        tail = " duration is being tracked on you to reliably show duration going forward."
    else
        tail = " duration is being tracked to reliably show duration going forward - stay on target until complete."
    end

    _Print(label .. nameCol .. cpSuffix .. tail)
end

local function _NotifyTrackingCancelled(spellName, reason)
    local label   = "|cff6FA8DCDoiteAuras:|r "
    local nameCol = "|cffffff00" .. (spellName or "Unknown") .. "|r"
    local msg     = " tracking cancelled (" .. (reason or "unknown") .. ")."
    _Print(label .. nameCol .. msg)
end

local function _NotifyTrackingFinished(spellId, spellName, spellRank, cp, duration)
    local label    = "|cff6FA8DCDoiteAuras:|r "
    local nameCol  = "|cffffff00" .. (spellName or "Unknown") .. "|r"
    local cpSuffix = _FormatCPSuffix(cp)
    local durStr   = string.format(" recorded duration: %.1f sec", duration or 0)
    _Print(label .. nameCol .. cpSuffix .. durStr)

    ----------------------------------------------------------------
    -- Extra helper line to copy into SpellDurationSec / SpellDurationSecCP
    ----------------------------------------------------------------
    local sec = math.floor((duration or 0) + 0.5)

    -- Get the raw durationIndex from SpellRec (not mapped through SpellDurationSec)
    local durationIndex = nil
    if GetSpellRecField then
        local ok, idx = pcall(GetSpellRecField, spellId, "durationIndex")
        if ok and type(idx) == "number" and idx > 0 then
            durationIndex = idx
        end
    end

    -- Rank part "(Rank 6)" if present
    local rankSuffix = ""
    if spellRank and spellRank ~= "" then
        rankSuffix = " (" .. spellRank .. ")"
    end

    local nameForComment = spellName or ("Spell " .. tostring(spellId or 0))

    -- Build the trailing comment: "Rip (Rank 6)/(9896)/(4CP)"
    local comment = nameForComment .. rankSuffix

    -- /(spellId)
    if spellId and spellId > 0 then
        comment = comment .. "/(" .. tostring(spellId) .. ")"
    end

    -- /(4CP) if combo-based
    if cp and cp > 0 then
        comment = comment .. "/(" .. tostring(cp) .. "CP)"
    end

    -- Red label for the copy line
    local redLabel = "|cffff0000Notify & Copy for Doite:|r "

    local copyLine

    if durationIndex and durationIndex > 0 then
        if cp and cp > 0 then
            -- CP-based: paste inside SpellDurationSecCP = { ... }
            -- Example:
            --   [87] = { [1] = 10, }, -- Rip (Rank 6)/(9896)/(1CP)
            copyLine = string.format(
                "%s[%s] = { [%d] = %d, }, -- %s",
                redLabel,
                tostring(durationIndex),
                cp,
                sec,
                comment
            )
        else
            -- Flat duration: paste inside SpellDurationSec = { ... }
            -- Example:
            --   [265] = 55, -- Some Spell (Rank 3)/(12345)
            copyLine = string.format(
                "%s[%s] = %d, -- %s",
                redLabel,
                tostring(durationIndex),
                sec,
                comment
            )
        end
    else
        -- Fallback if durationIndex is unknown
        copyLine = string.format(
            "%s-- durationIndex=?  sec=%d  %s",
            redLabel,
            sec,
            comment
        )
    end

    _Print(copyLine)
end

---------------------------------------------------------------
-- Spell debug helper
---------------------------------------------------------------
local _debugSpells = false

local function _DebugSpell(spellId, cp, stage)
    if not _debugSpells then return end
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then return end

    local name, rank = _GetSpellNameRank(spellId)
    local dbc = _GetDBCBaseDuration(spellId, cp)
    local flat = _GetTrackedFlatDuration(spellId)
    local cpDur = (cp and cp > 0) and _GetTrackedCPDuration(spellId, cp) or nil
    local willRecord = _ShouldRecord(spellId, cp)

    _Print(string.format(
        "DoiteTrackDBG[%s]: id=%d name=%s cp=%d dbc=%s flat=%s cpDur=%s record=%s",
        stage or "?", spellId, tostring(name),
        cp or 0,
        tostring(dbc),
        tostring(flat),
        tostring(cpDur),
        tostring(willRecord)
    ))
end

_G["DoiteTrack_SetSpellDebug"] = function(on)
    _debugSpells = (on and true or false)
    if _debugSpells then
        _Print("|cff6FA8DCDoiteAuras:|r spell debug |cffffff00ON|r")
    else
        _Print("|cff6FA8DCDoiteAuras:|r spell debug |cffffff00OFF|r")
    end
end

---------------------------------------------------------------
-- SPELL_CAST_EVENT handler (Nampower)
---------------------------------------------------------------
local TrackFrame = CreateFrame("Frame", "DoiteTrackFrame")
local _lastUpdate = 0

local function _EnsureOnUpdateEnabled()
    if not TrackFrame._onUpdateActive then
        TrackFrame._onUpdateActive = true
        TrackFrame:SetScript("OnUpdate", function()
            local now = GetTime()
            -- Only do heavy work every 0.1s
            if now - _lastUpdate < 0.1 then
                return
            end
            _lastUpdate = now

            local anyActive = false
            local id, s

            for id, s in pairs(ActiveSessions) do
                if not s.aborted and not s.complete then
                    anyActive = true

                    local unit = _FindUnitByGuid(s.targetGuid)
                    local now2 = now

                    if not unit then
                        local lastUnit = s.lastUnitSeenAt or s.startedAt or now2
                        if (now2 - lastUnit) > 15 then
                            _AbortSession(s, "target lost")
                            if s.willRecord then
                                _NotifyTrackingCancelled(s.spellName, "target lost")
                            end
                        end
                    else
                        s.lastUnitSeenAt = now2

                        if UnitIsDead and UnitIsDead(unit) == 1 then
                            _AbortSession(s, "target died")
                            if s.willRecord then
                                _NotifyTrackingCancelled(s.spellName, "target died")
                            end
                        else
                            local hasAura = _AuraHasSpellId(unit, s.spellId, s.isDebuff)

                            if hasAura then
                                if not s.appliedAt then
                                    s.appliedAt = now2
                                end
                                s.lastSeen = now2

                                -- Keep runtime aura bucket in sync for remaining-time queries.
                                _RecordAuraForSession(s)
                            else
                                if s.appliedAt then
                                    local lastSeen = s.lastSeen or s.appliedAt or now2
                                    local gap      = now2 - lastSeen

                                    if gap > 1.5 then
                                        _AbortSession(s, "aura faded off-target")
                                        if s.willRecord then
                                            _NotifyTrackingCancelled(s.spellName, "aura faded while not targeted")
                                        end
                                    else
                                        local dur = lastSeen - s.appliedAt
                                        if dur > 0.5 and dur < 600 then
                                            _FinishSession(s, dur)
                                            if s.willRecord then
                                                _NotifyTrackingFinished(s.spellId, s.spellName, s.spellRank, s.cp, dur)
                                            end
                                        else
                                            _AbortSession(s, "duration out of range")
                                            if s.willRecord then
                                                _NotifyTrackingCancelled(s.spellName, "duration out of range")
                                            end
                                        end
                                    end
                                else
                                    local age = now2 - (s.startedAt or now2)
                                    if age > 1.5 then
                                        _AbortSession(s, "aura never applied")
                                        if s.willRecord then
                                            _NotifyTrackingCancelled(s.spellName, "aura never applied")
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end

            if not anyActive then
                TrackFrame._onUpdateActive = false
                TrackFrame:SetScript("OnUpdate", nil)
            end
        end)
    end
end

function DoiteTrack:_OnSpellCastEvent()
    local success    = arg1
    local spellId    = arg2
    local castType   = arg3
    local targetGuid = arg4
    local itemId     = arg5

    if success ~= 1 then
        return
    end

    if not spellId or spellId == 0 then
        return
    end

    local now = GetTime()
    RecentCastBySpellId[spellId] = now
    local entry = TrackedBySpellId[spellId]

    -- Fallback: resolve by normalised spell name so downranks still match
    if not entry then
        local castName

        if GetSpellNameAndRankForId then
            local ok, n = pcall(GetSpellNameAndRankForId, spellId)
            if ok and n and n ~= "" then
                castName = n
            end
        end

        if not castName and SpellInfo then
            local n = SpellInfo(spellId)
            if type(n) == "string" and n ~= "" then
                castName = n
            end
        end

        if castName then
            local norm = _NormSpellName(castName)
            if norm then
                local byNorm = TrackedByNameNorm[norm]
                if byNorm then
                    entry = byNorm
                    entry.spellIds[spellId] = true
                    TrackedBySpellId[spellId] = entry
                end
            end
        end
    end

    if not entry then
        entry = _MaybeRebuildWatchListForSpell(spellId)
    end

    if not entry then
        return
    end

    local pGuid = _GetPlayerGUID()
    if not pGuid then
        return
    end

    if not targetGuid or targetGuid == "0x000000000" or targetGuid == "0x0000000000000000" then
        targetGuid = pGuid
    end

    local cp = 0
    if _PlayerUsesComboPoints() and entry.kind == "Debuff" and _SpellUsesComboDuration(spellId) then
        cp = _GetComboPointsSafe()
    end

    local willRecord = _ShouldRecord(spellId, cp)

    _DebugSpell(spellId, cp, "CAST")

    local sid, existing = _FindSessionFor(spellId, targetGuid)
    if existing then
        _AbortSession(existing, "refreshed before fade")
        if existing.willRecord then
            _NotifyTrackingCancelled(existing.spellName, "refreshed before fade; starting new recording")
        end
    end

    SessionCounter = SessionCounter + 1

    local name, rank     = _GetSpellNameRank(spellId)
    local isPlayerTarget = (targetGuid == pGuid)

    local s = {
        id         = SessionCounter,
        spellId    = spellId,
        spellName  = name,
        spellRank  = rank,
        kind       = entry.kind,
        isDebuff   = (entry.kind == "Debuff"),
        targetGuid = targetGuid,
        ownerGuid  = pGuid,
        cp         = cp,
        startedAt  = now,
        appliedAt  = nil,
        lastSeen   = nil,
        aborted    = false,
        complete   = false,
        source     = "cast",
        willRecord = willRecord,
    }

    ActiveSessions[s.id] = s

    if willRecord then
        _NotifyTrackingStart(name, cp, isPlayerTarget)
    end
    _EnsureOnUpdateEnabled()
end

function DoiteTrack:_OnUnitCastEvent()
    local casterGuid = arg1
    local targetGuid = arg2
    local evType     = arg3
    local spellId    = arg4
    local castDur    = arg5

    if evType ~= "CAST" and evType ~= "CHANNEL" and evType ~= "START" then
        return
    end

    if not spellId or spellId == 0 then
        return
    end

    local pGuid = _GetPlayerGUID()
    if not pGuid or not casterGuid or casterGuid == "" or casterGuid ~= pGuid then
        return
    end

    local now = GetTime()

    local last = RecentCastBySpellId[spellId]
    if last and (now - last) < 0.2 then
        return
    end
    RecentCastBySpellId[spellId] = now

    local entry = TrackedBySpellId[spellId]

    if not entry then
        local castName

        if GetSpellNameAndRankForId then
            local ok, n = pcall(GetSpellNameAndRankForId, spellId)
            if ok and n and n ~= "" then
                castName = n
            end
        end

        if not castName and SpellInfo then
            local n = SpellInfo(spellId)
            if type(n) == "string" and n ~= "" then
                castName = n
            end
        end

        if castName then
            local norm = _NormSpellName(castName)
            if norm then
                local byNorm = TrackedByNameNorm[norm]
                if byNorm then
                    entry = byNorm
                    entry.spellIds[spellId] = true
                    TrackedBySpellId[spellId] = entry
                end
            end
        end
    end

    if not entry then
        entry = _MaybeRebuildWatchListForSpell(spellId)
    end

    if not entry then
        return
    end

    if not targetGuid or targetGuid == "" or targetGuid == "0x000000000" or targetGuid == "0x0000000000000000" then
        targetGuid = pGuid
    end

    local cp = 0
    if _PlayerUsesComboPoints() and entry.kind == "Debuff" and _SpellUsesComboDuration(spellId) then
        cp = _GetComboPointsSafe()
    end

    local willRecord = _ShouldRecord(spellId, cp)

    _DebugSpell(spellId, cp, "UNIT_CAST")

    local sid, existing = _FindSessionFor(spellId, targetGuid)
    if existing then
        _AbortSession(existing, "refreshed before fade")
        if existing.willRecord then
            _NotifyTrackingCancelled(existing.spellName, "refreshed before fade; starting new recording")
        end
    end

    SessionCounter = SessionCounter + 1

    local name, rank     = _GetSpellNameRank(spellId)
    local isPlayerTarget = (targetGuid == pGuid)

    local s = {
        id         = SessionCounter,
        spellId    = spellId,
        spellName  = name,
        spellRank  = rank,
        kind       = entry.kind,
        isDebuff   = (entry.kind == "Debuff"),
        targetGuid = targetGuid,
        ownerGuid  = pGuid,
        cp         = cp,
        startedAt  = now,
        appliedAt  = nil,
        lastSeen   = nil,
        aborted    = false,
        complete   = false,
        source     = "cast",
        willRecord = willRecord,
    }

    ActiveSessions[s.id] = s

    if willRecord then
        _NotifyTrackingStart(name, cp, isPlayerTarget)
    end
    _EnsureOnUpdateEnabled()
end

function DoiteTrack:_OnSpellDamageSelf()
    local targetGuid = arg1  -- targetGuid
    local casterGuid = arg2  -- casterGuid
    local spellId    = arg3  -- spellId

    if not spellId or spellId == 0 then
        return
    end

    local now      = GetTime()
    local lastCast = RecentCastBySpellId[spellId]
    if lastCast and (now - lastCast) < 1.0 then
        return
    end

    local entry = TrackedBySpellId[spellId]
    if not entry then
        return
    end

    local pGuid = _GetPlayerGUID()
    if not pGuid or casterGuid ~= pGuid then
        return
    end

    local cp = 0
    local willRecord = _ShouldRecord(spellId, cp)

    if _DebugSpell then
        _DebugSpell(spellId, cp, "DAMAGE")
    end

    now = GetTime()

    local sid, existing = _FindSessionFor(spellId, targetGuid)
    if existing then
        return
    end

    SessionCounter = SessionCounter + 1

    local name, rank     = _GetSpellNameRank(spellId)
    local isPlayerTarget = (targetGuid == pGuid)

    local s = {
        id         = SessionCounter,
        spellId    = spellId,
        spellName  = name,
        spellRank  = rank,
        kind       = entry.kind,
        isDebuff   = (entry.kind == "Debuff"),
        targetGuid = targetGuid,
        ownerGuid  = pGuid,
        cp         = cp,
        startedAt  = now,
        appliedAt  = now,
        lastSeen   = now,
        aborted    = false,
        complete   = false,
        source     = "damage",
        willRecord = willRecord,
    }

    ActiveSessions[s.id] = s

    if willRecord then
        _NotifyTrackingStart(name, cp, isPlayerTarget)
    end
    _EnsureOnUpdateEnabled()
end

---------------------------------------------------------------
-- PLAYER_LOGIN / PLAYER_ENTERING_WORLD / PLAYER_TARGET_CHANGED
---------------------------------------------------------------
function DoiteTrack:_OnPlayerLogin()
    _playerGUID_cached = nil
    _GetPlayerGUID()
    self:RebuildWatchList()
end

function DoiteTrack:_OnTargetChanged()
    -- reserved for future safeguards
end

TrackFrame:RegisterEvent("PLAYER_LOGIN")
TrackFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
TrackFrame:RegisterEvent("SPELL_CAST_EVENT")
TrackFrame:RegisterEvent("SPELL_DAMAGE_EVENT_SELF")
TrackFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
TrackFrame:RegisterEvent("UNIT_CASTEVENT")

TrackFrame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        DoiteTrack:_OnPlayerLogin()
    elseif event == "SPELL_CAST_EVENT" then
        DoiteTrack:_OnSpellCastEvent()
    elseif event == "SPELL_DAMAGE_EVENT_SELF" then
        DoiteTrack:_OnSpellDamageSelf()
    elseif event == "PLAYER_TARGET_CHANGED" then
        DoiteTrack:_OnTargetChanged()
    elseif event == "UNIT_CASTEVENT" then
        DoiteTrack:_OnUnitCastEvent()
    end
end)

---------------------------------------------------------------
-- Runtime API
---------------------------------------------------------------
function DoiteTrack:IsMyAuraActive(spellId, unit)
    if not spellId or not unit then
        return false
    end

    -- "Active" == currently have a positive remaining time.
    local rem = self:GetAuraRemainingSeconds(spellId, unit)
    return (rem ~= nil and rem > 0)
end

function DoiteTrack:GetAuraRemainingSeconds(spellId, unit)
    if not spellId or not unit then return nil end
    local guid = _GetUnitGuidSafe(unit)
    if not guid then return nil end

    local bucket = AuraStateByGuid[guid]
    if not bucket then return nil end

    local a = bucket[spellId]
    if not a then return nil end

    local base = a.fullDur
    if not base or base <= 0 then
        base = _GetBaselineDuration(spellId, a.cp or 0)
        if not base or base <= 0 then
            return nil
        end
        a.fullDur = base
    end

    local appliedAt = a.appliedAt or a.lastSeen
    if not appliedAt then
        return nil
    end

    local now     = GetTime()
    local elapsed = now - appliedAt
    local rem     = base - elapsed

    if rem <= 0 then
        -- past players own duration, forget this entry for ownership purposes
        bucket[spellId] = nil
        return nil
    end

    return rem
end

function DoiteTrack:RemainingPasses(spellId, unit, comp, threshold)
    if not spellId or not unit or not comp or threshold == nil then
        return nil
    end
    local rem = self:GetAuraRemainingSeconds(spellId, unit)
    if not rem or rem <= 0 then
        return nil
    end

    if comp == ">=" then
        return rem >= threshold
    elseif comp == "<=" then
        return rem <= threshold
    elseif comp == "==" then
        return rem == threshold
    end
    return nil
end

---------------------------------------------------------------
-- Name-based + recording helpers for DoiteConditions
---------------------------------------------------------------

-- Find tracking entry for a display name ("Rend", all ranks)
local function _GetEntryForName(spellName)
    if not spellName or spellName == "" then
        return nil
    end
    local norm = _NormSpellName(spellName)
    if not norm then
        return nil
    end
    return TrackedByNameNorm[norm]
end

-- Find active recording session for (spellId, unit)
local function _GetActiveSessionForUnit(spellId, unit)
    spellId = tonumber(spellId) or 0
    if spellId <= 0 or not unit then
        return nil
    end

    local guid = _GetUnitGuidSafe(unit)
    if not guid or guid == "" then
        return nil
    end

    local id, s = _FindSessionFor(spellId, guid)
    if not id or not s or s.aborted or s.complete then
        return nil
    end
    return s
end

-- Public: is there a dynamic recording session for this aura on this unit?
function DoiteTrack:IsAuraRecording(spellId, unit)
    return _GetActiveSessionForUnit(spellId, unit) ~= nil
end

-- Public: remaining seconds by *name* (all ranks) on a unit.
-- Returns: remainingSeconds or nil if unknown/not active.
-- Second return value is the spellId that matched (or nil).
function DoiteTrack:GetAuraRemainingSecondsByName(spellName, unit)
    if not spellName or not unit then
        return nil
    end

    local entry = _GetEntryForName(spellName)
    if not entry or not entry.spellIds then
        return nil
    end

    local bestRem, bestSpellId = nil, nil

    for sid in pairs(entry.spellIds) do
        local rem = self:GetAuraRemainingSeconds(sid, unit)
        if rem and rem > 0 then
            if not bestRem or rem > bestRem then
                bestRem    = rem
                bestSpellId = sid
            end
        end
    end

    if not bestRem or bestRem <= 0 then
        return nil
    end

    return bestRem, bestSpellId
end

-- Public: comparison helper by *name* (same semantics as RemainingPasses)
-- Returns boolean or nil if no active / no duration.
function DoiteTrack:RemainingPassesByName(spellName, unit, comp, threshold)
    if not spellName or not unit or not comp or threshold == nil then
        return nil
    end

    local rem = self:GetAuraRemainingSecondsByName(spellName, unit)
    if not rem or rem <= 0 then
        return nil
    end

    if comp == ">=" then
        return rem >= threshold
    elseif comp == "<=" then
        return rem <= threshold
    elseif comp == "==" then
        return rem == threshold
    end
    return nil
end

-- Public: "is aura mine?" by *name* (true/false), using DoiteTrack’s state
function DoiteTrack:IsAuraMineByName(spellName, unit)
    if not spellName or not unit then
        return false
    end

    local entry = _GetEntryForName(spellName)
    if not entry or not entry.spellIds then
        return false
    end

    for sid in pairs(entry.spellIds) do
        if self:IsAuraMine(sid, unit) then
            return true
        end
    end

    return false
end

-- Public: remaining or "recording" flag by *name*
-- Returns:
--   remSeconds or nil,
--   isRecording:boolean,
--   spellId or nil
function DoiteTrack:GetAuraRemainingOrRecordingByName(spellName, unit)
    if not spellName or not unit then
        return nil, false, nil
    end

    local rem, sid = self:GetAuraRemainingSecondsByName(spellName, unit)
    if rem and rem > 0 then
        return rem, false, sid
    end

    local entry = _GetEntryForName(spellName)
    if not entry or not entry.spellIds then
        return nil, false, nil
    end

    for spellId in pairs(entry.spellIds) do
        if self:IsAuraRecording(spellId, unit) then
            return nil, true, spellId
        end
    end

    return nil, false, nil
end

----------------------------------
-- API Public
----------------------------------

-- Public: does this unit have this aura (by name, any rank), regardless of owner?
function DoiteTrack:HasAnyAuraByName(spellName, unit)
    if not spellName or not unit then
        return false, nil
    end

    local entry = _GetEntryForName(spellName)
    if not entry then
        return false, nil
    end
    entry.spellIds = entry.spellIds or {}

    if not UnitExists or not UnitExists(unit) then
        return false, nil
    end

    -- 1) Fast path: known spellIds
    local sid
    for sid in pairs(entry.spellIds) do
        if _AuraHasSpellId(unit, sid, entry.kind == "Debuff") then
            return true, sid
        end
    end

    -- 2) Slow path: discover spellId by scanning unit aura ids -> spell name -> normalize
    local discovered = _CacheMatchingAuraIdsOnUnit(entry, unit)
    if discovered and discovered > 0 then
        return true, discovered
    end

    return false, nil
end

-- Public - consolidated ownership helper for DoiteConditions:
-- Returns:
--   remSeconds or nil,
--   isRecording:boolean,
--   spellId or nil (best "mine" spell if any),
--   isMine:boolean,      -- true if at least one *mine* aura exists
--   isOther:boolean,     -- true if at least one *non-mine* aura exists
--   ownerKnown:boolean   -- true if at least something about ownership
function DoiteTrack:GetAuraOwnershipByName(spellName, unit)
    if not spellName or not unit then
        return nil, false, nil, false, false, false
    end

    local entry = _GetEntryForName(spellName)
    if not entry or not entry.spellIds then
        return nil, false, nil, false, false, false
    end

    -- Cheap existence guard
    if not UnitExists or not UnitExists(unit) then
        return nil, false, nil, false, false, false
    end

    -- Ensure spellIds for whatever rank is actually on the unit right now
    entry.spellIds = entry.spellIds or {}
    _CacheMatchingAuraIdsOnUnit(entry, unit)

    local bestRem, bestSpellId = nil, nil
    local recording            = false
    local hasMine              = false
    local hasOther             = false

    -- Walk ALL spellIds for this name and inspect ownership per-id
    for sid in pairs(entry.spellIds) do
        -- Is this aura (this spellId) actually present on the unit?
        if _AuraHasSpellId(unit, sid, entry.kind == "Debuff") then
            local mineSid = self:IsAuraMine(sid, unit)

            if mineSid then
                hasMine = true

                -- Only ever report remaining time for *our* auras
                local remSid = self:GetAuraRemainingSeconds(sid, unit)
                if remSid and remSid > 0 then
                    if not bestRem or remSid > bestRem then
                        bestRem    = remSid
                        bestSpellId = sid
                    end
                end

                -- Recording is also "ours only"
                if self:IsAuraRecording(sid, unit) then
                    recording = true
                end
            else
                -- Aura with this spellId is present but not ours
                hasOther = true
            end
        end
    end

    local ownerKnown = (hasMine or hasOther)

    if bestRem ~= nil and bestRem <= 0 then
        bestRem = nil
    end

    return bestRem, recording, bestSpellId, hasMine, hasOther, ownerKnown
end


-- Return the baseline duration (DBC or learned) for this spellId/cp, or nil if unknown.
function DoiteTrack:GetBaselineDuration(spellId, cp)
    if not spellId then return nil end
    return _GetBaselineDuration(spellId, cp or 0)
end

-- Convenience boolean: know any duration (DBC or learned) for this spellId/cp?
function DoiteTrack:HasKnownDuration(spellId, cp)
    if not spellId then return false end
    return _GetBaselineDuration(spellId, cp or 0) ~= nil
end

-- Will a cast of this spell (with this cp) start a dynamic recording?w (i.e. no DBC entry and no stored duration yet)
function DoiteTrack:WillRecord(spellId, cp)
    if not spellId then return false end
    return _ShouldRecord(spellId, cp or 0)
end

-- Is the tracked aura on this unit ours (player-cast)? "Mine" == either:
--   * have an active recording session for this spell/unit, OR
--   * have a positive remaining time from our recorded/DBC duration.
function DoiteTrack:IsAuraMine(spellId, unit)
    if not spellId or not unit then
        return false
    end

    -- If there is an active session for this spell/unit, it is *probably* ours,
    -- but only for roughly its expected duration.
    local s = _GetActiveSessionForUnit(spellId, unit)
    if s then
        local base = _GetBaselineDuration(spellId, s.cp or 0)
        if base and s.appliedAt then
            local now     = GetTime()
            local elapsed = now - s.appliedAt

            -- After ~130% of the expected duration, assume the aura on the target
            -- (if any) now belongs to someone else.
            if elapsed > (base * 1.3) then
                _AbortSession(s, "elapsed beyond baseline; assume other owner")
            else
                return true
            end
        else
            -- No baseline known (no DBC/learned duration): keep old behavior
            return true
        end
    end

    -- Fallback: only trust our bucket if this spellId is actually present right now.
    local entry = TrackedBySpellId[spellId]
    local present = false

    if entry then
        present = _AuraHasSpellId(unit, spellId, entry.kind == "Debuff")
    else
        -- If not know buff/debuff kind, try both.
        present = _AuraHasSpellId(unit, spellId, true) or _AuraHasSpellId(unit, spellId, false)
    end

    if not present then
        -- Stale bucket entry; drop it so it doesn't claim ownership.
        local guid = _GetUnitGuidSafe(unit)
        if guid and AuraStateByGuid[guid] then
            AuraStateByGuid[guid][spellId] = nil
        end
        return false
    end

    local rem = self:GetAuraRemainingSeconds(spellId, unit)
    return (rem ~= nil and rem > 0)
end

--------------------
-- Ingame selftest
--------------------
-- Owner: /run d=DoiteTrack;n="Rend";u="target";rem,rec,sid,hm,ho,ok=d:GetAuraOwnershipByName(n,u);print("has",ok,"sid",sid,"mine",hm,"other",ho,"rem",rem,"rec",rec)
-- DurationIndex: /run id=123;idx=GetSpellRecField(id,"durationIndex");d=DoiteTrack:GetBaselineDuration(id,0);print("id",id,"idx",idx,"sec",d)
-- /run local id=11574 local d=DoiteTrack local r=d:GetAuraRemainingSeconds(id,"target") local c=d:IsAuraRecording(id,"target") local m=d:IsAuraMine(id,"target") local b=d:GetBaselineDuration(id,0) print("r",r,"c",c,"m",m,"b",b)