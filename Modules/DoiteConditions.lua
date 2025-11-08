---------------------------------------------------------------
-- DoiteConditions.lua
-- Evaluates ability and aura conditions to show/hide/update icons
-- Turtle WoW (1.12) | Lua 5.0
---------------------------------------------------------------

local addonName, _ = "DoiteConditions"
local DoiteConditions = {}
_G["DoiteConditions"] = DoiteConditions

if not _G["DoiteAurasDB"] then
    _G["DoiteAurasDB"] = {}
end
DoiteAurasDB = _G["DoiteAurasDB"]
DoiteAurasDB.cache = DoiteAurasDB.cache or {}
DoiteAurasCacheDB = DoiteAurasDB.cache
local IconCache = DoiteAurasDB.cache
local GetTime       = GetTime
local UnitBuff      = UnitBuff
local UnitDebuff    = UnitDebuff
local UnitExists    = UnitExists
local UnitIsFriend  = UnitIsFriend
local UnitCanAttack = UnitCanAttack
local UnitIsUnit    = UnitIsUnit
local _lastAuraScanAt = 0

-- === Spell index cache (must be defined before any usage) ===
local SpellIndexCache = {}  -- [spellName] = index or false (if not found)

local function _GetSpellIndexByName(spellName)
    if not spellName then return nil end
    local cached = SpellIndexCache[spellName]
    if cached ~= nil then
        return (cached ~= false) and cached or nil
    end
    local i = 1
    while i <= 200 do
        local s = GetSpellName(i, BOOKTYPE_SPELL)
        if not s then break end
        if s == spellName then
            SpellIndexCache[spellName] = i
            return i
        end
        i = i + 1
    end
    SpellIndexCache[spellName] = false
    return nil
end


local dirty_ability = false
local dirty_aura    = false
local dirty_target  = false
local dirty_power   = false

local DG = _G["DoiteGlow"]
-- While the Doite edit panel is open, this global is set by DoiteEdit.lua
local function _IsKeyUnderEdit(k)
    return (k and _G["DoiteEdit_CurrentKey"] and _G["DoiteEdit_CurrentKey"] == k)
end

local _trackedByName, _trackedBuiltAt = nil, 0
local function _GetTrackedByName()
    local now = GetTime()
    if _trackedByName and (now - _trackedBuiltAt) < 0.5 then
        return _trackedByName
    end
    local t = {}
    if DoiteAurasDB and DoiteAurasDB.spells then
        for key, data in pairs(DoiteAurasDB.spells) do
            if data and (data.type == "Buff" or data.type == "Debuff") then
                local nm = data.displayName or data.name
                if nm and nm ~= "" then
                    local lst = t[nm]
                    if not lst then
                        lst = {}
                        t[nm] = lst
                    end
                    -- Lua 5.0-safe append
                    table.insert(lst, { key = key, typ = data.type })
                end
            end
        end
    end
    _trackedByName, _trackedBuiltAt = t, now
    return t
end

-- === Aura snapshot & single tooltip ===
local DoiteConditionsTooltip = _G["DoiteConditionsTooltip"]
if not DoiteConditionsTooltip then
    DoiteConditionsTooltip = CreateFrame("GameTooltip", "DoiteConditionsTooltip", nil, "GameTooltipTemplate")
    DoiteConditionsTooltip:SetOwner(UIParent, "ANCHOR_NONE")
end
local auraSnapshot = { player = { buffs = {}, debuffs = {} }, target = { buffs = {}, debuffs = {} } }

-- Create our hidden tooltip once; don't re-SetOwner every scan
local function _EnsureTooltip()
    if not DoiteConditionsTooltip then
        DoiteConditionsTooltip = CreateFrame("GameTooltip", "DoiteConditionsTooltip", UIParent, "GameTooltipTemplate")
        DoiteConditionsTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        DoiteConditionsTooltip:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 0, 0) -- offscreen
        if DoiteConditionsTooltip.SetScript then
            DoiteConditionsTooltip:SetScript("OnTooltipCleared", nil)
            DoiteConditionsTooltip:SetScript("OnHide", nil)
        end
    end
end

-- Tooltip-driven name fetch for a specific aura slot (Vanilla-safe)
local function _GetAuraName(unit, index, isDebuff)
    _EnsureTooltip()
    DoiteConditionsTooltip:ClearLines()
    if isDebuff then
        DoiteConditionsTooltip:SetUnitDebuff(unit, index)
    else
        DoiteConditionsTooltip:SetUnitBuff(unit, index)
    end
    return DoiteConditionsTooltipTextLeft1 and DoiteConditionsTooltipTextLeft1:GetText()
end

local function _ScanUnitAuras(unit)
    _EnsureTooltip()

    -- Use the cached lookup: auraName -> { list of keys that track this name }
    local trackedByName = _GetTrackedByName()

    local snap = auraSnapshot[unit]
    if not snap then return end
    local buffs, debuffs = snap.buffs, snap.debuffs
    for k in pairs(buffs) do buffs[k] = nil end
    for k in pairs(debuffs) do debuffs[k] = nil end

    -- BUFFS
    local i = 1
    while true do
        DoiteConditionsTooltip:ClearLines()
        DoiteConditionsTooltip:SetUnitBuff(unit, i)
        local tn = DoiteConditionsTooltipTextLeft1 and DoiteConditionsTooltipTextLeft1:GetText()
        if not tn then break end
        buffs[tn] = true

        local list = trackedByName and trackedByName[tn]
        if list then
            local tex = UnitBuff(unit, i)
            if tex and tn and IconCache[tn] ~= tex then
                IconCache[tn] = tex
                DoiteAurasDB.cache[tn] = tex
                if DoiteAurasDB.spells then
                    local n = table.getn(list)
                    for j = 1, n do
                        local info = list[j]
                        local s = DoiteAurasDB.spells[info.key]
                        if s then s.iconTexture = tex end
                    end
                end
                local n2 = table.getn(list)
                for j = 1, n2 do
                    local info = list[j]
                    local f = _G["DoiteIcon_" .. info.key]
                    if f and f.icon and (f.icon:GetTexture() ~= tex) then
                        f.icon:SetTexture(tex)
                    end
                end
            end
        end
        i = i + 1
    end

    -- DEBUFFS
    i = 1
    while true do
        DoiteConditionsTooltip:ClearLines()
        DoiteConditionsTooltip:SetUnitDebuff(unit, i)
        local tn = DoiteConditionsTooltipTextLeft1 and DoiteConditionsTooltipTextLeft1:GetText()
        if not tn then break end
        debuffs[tn] = true

        local list = trackedByName and trackedByName[tn]
        if list then
            local tex = UnitDebuff(unit, i)
            if tex and tn then
                IconCache[tn] = tex
                DoiteAurasDB.cache[tn] = tex
                if DoiteAurasDB.spells then
                    local n = table.getn(list)
                    for j = 1, n do
                        local info = list[j]
                        local s = DoiteAurasDB.spells[info.key]
                        if s then s.iconTexture = tex end
                    end
                end
                local n2 = table.getn(list)
                for j = 1, n2 do
                    local info = list[j]
                    local f = _G["DoiteIcon_" .. info.key]
                    if f and f.icon and (f.icon:GetTexture() ~= tex) then
                        f.icon:SetTexture(tex)
                    end
                end
            end
        end
        i = i + 1
    end

    if dirty_aura and DoiteAurasDB and DoiteAurasDB.cache then
        DoiteAurasDB.cache = IconCache
    end
end

---------------------------------------------------------------
-- Local helpers
---------------------------------------------------------------

local function SafeGet(tbl, key)
    if not tbl then return nil end
    return tbl[key]
end

local function InCombat()
    return UnitAffectingCombat("player") == 1
end

-- Power percent (0..100)
local function GetPowerPercent()
    local max = UnitManaMax("player")
    if not max or max <= 0 then return 0 end
    local cur = UnitMana("player")
    return (cur * 100) / max
end

-- === Remaining-time helpers ===

-- Compare helper: returns true if rem (seconds) passes comp vs target (seconds)
local function _RemainingPasses(rem, comp, target)
    if not rem or not comp or target == nil then return true end
    if comp == ">=" then
        return rem >= target
    elseif comp == "<=" then
        return rem <= target
    elseif comp == "==" then
        return rem == target
    end
    return true
end

-- Ability cooldown remaining (in seconds) for a spellbook index; nil if not on CD
local function _AbilityRemainingSeconds(spellIndex, bookType)
    if not spellIndex then return nil end
    local start, dur, enable = GetSpellCooldown(spellIndex, bookType or BOOKTYPE_SPELL)
    if start and dur and start > 0 and dur > 0 then
        local rem = (start + dur) - GetTime()
        if rem and rem > 0 then return rem end
    end
    return nil
end

-- Remaining time by spell *name* (searches spellbook, then calls _AbilityRemainingSeconds)
local function _AbilityRemainingByName(spellName)
    if not spellName then return nil end
    local idx = _GetSpellIndexByName(spellName)
    return _AbilityRemainingSeconds(idx, BOOKTYPE_SPELL)
end

-- Cooldown (remaining, totalDuration) by spell name; nil,nil if not in book
local function _AbilityCooldownByName(spellName)
    if not spellName then return nil, nil end
    local idx = _GetSpellIndexByName(spellName)
    if not idx then return nil, nil end

    local start, dur = GetSpellCooldown(idx, BOOKTYPE_SPELL)
    if start and dur and start > 0 and dur > 0 then
        local rem = (start + dur) - GetTime()
        if rem < 0 then rem = 0 end
        return rem, dur
    else
        return 0, dur or 0
    end
end

----------------------------------------------------------------
-- DoiteAuras Slide Manager (buttery-smooth 60fps animator)
----------------------------------------------------------------
local SlideMgr = {
    active = {},  -- [key] = { dir, baseX, baseY, endTime, started=true }
}
local _slideTick = CreateFrame("Frame")
_slideTick:SetScript("OnUpdate", function()
    local now = GetTime()
    local anyActive = false

    for key, s in pairs(SlideMgr.active) do
        if now >= s.endTime then
            SlideMgr.active[key] = nil
        else
            anyActive = true
        end
    end

    -- While sliding, force abilities to re-paint frequently so positions update smoothly.
    if anyActive then
        dirty_ability = true
    end
end)

-- Begin or refresh an animation for 'key'
-- endTime = GetTime() + remaining  (cap remaining inside caller)
function SlideMgr:StartOrUpdate(key, dir, baseX, baseY, endTime)
    local st = self.active[key]
    if not st then
        st = { dir = dir or "center", baseX = baseX or 0, baseY = baseY or 0, endTime = endTime or GetTime() }
        self.active[key] = st
    else
        st.dir = dir or st.dir
        st.baseX = baseX or st.baseX
        st.baseY = baseY or st.baseY
        st.endTime = endTime or st.endTime
    end
end

function SlideMgr:Stop(key)
    self.active[key] = nil
end

-- Query current offsets/alpha. Returns:
-- active:boolean, dx:number, dy:number, alpha:number, suppressGlow:boolean, suppressGrey:boolean
function SlideMgr:Get(key)
    local st = self.active[key]
    if not st then return false, 0, 0, 1, false, false end

    local now = GetTime()
    local t = (st.endTime - now) / (st.total or 3.0)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end

    local farX, farY = 0, 0
    if     st.dir == "left"  then farX, farY = -80,  0
    elseif st.dir == "right" then farX, farY =  80,  0
    elseif st.dir == "up"    then farX, farY =   0, 80
    elseif st.dir == "down"  then farX, farY =   0,-80
    else   -- center fade only
        farX, farY = 0, 0
    end

    local dx = farX * t
    local dy = farY * t
    local alpha = (st.dir == "center") and (1.0 - t) or 1.0
    if alpha < 0 then alpha = 0 elseif alpha > 1 then alpha = 1 end

    return true, dx, dy, alpha, true, true
end

-- For ApplyVisuals to get latest base anchoring while sliding
function SlideMgr:UpdateBase(key, baseX, baseY)
    local st = self.active[key]
    if st then
        st.baseX = baseX or st.baseX
        st.baseY = baseY or st.baseY
    end
end

-- For ApplyVisuals to read current base (even if not sliding)
function SlideMgr:GetBase(key)
    local st = self.active[key]
    if st then return st.baseX or 0, st.baseY or 0 end
    return 0, 0
end

-- Read the baseline (saved) XY for an icon (matches CreateOrUpdateIcon layout precedence)
local function _GetBaseXY(key, dataTbl)
    -- defaults
    local x, y = 0, 0

    -- primary source: DoiteAurasDB.spells
    if DoiteAurasDB and DoiteAurasDB.spells and key and DoiteAurasDB.spells[key] then
        local s = DoiteAurasDB.spells[key]
        x = s.offsetX or s.x or x
        y = s.offsetY or s.y or y
    end

    -- optional override: legacy DoiteDB.icons layout (if present)
    if DoiteDB and DoiteDB.icons and key and DoiteDB.icons[key] then
        local L = DoiteDB.icons[key]
        x = (L.posX or L.offsetX or x)
        y = (L.posY or L.offsetY or y)
    end

    return x, y
end

-- Player-only aura remaining (seconds); nil if not timed / not found
-- Uses 1.12-style GetPlayerBuff / GetPlayerBuffTimeLeft if available
local function _PlayerAuraRemainingSeconds(auraName)
    if not auraName then return nil end
    if not GetPlayerBuff or not GetPlayerBuffTimeLeft or not DoiteConditionsTooltip then
        return nil
    end

    -- search helpful first
    for i = 0, 31 do
        local idx = GetPlayerBuff(i, "HELPFUL")
        if idx and idx >= 0 then
            DoiteConditionsTooltip:ClearLines()
            if DoiteConditionsTooltip.SetPlayerBuff then
                DoiteConditionsTooltip:SetPlayerBuff(idx)
                local tn = DoiteConditionsTooltipTextLeft1 and DoiteConditionsTooltipTextLeft1:GetText()
                if tn == auraName then
                    local tl = GetPlayerBuffTimeLeft(idx)
                    if tl and tl > 0 then return tl end
                    return nil
                end
            end
        end
    end

    -- then harmful
    for i = 0, 31 do
        local idx = GetPlayerBuff(i, "HARMFUL")
        if idx and idx >= 0 then
            DoiteConditionsTooltip:ClearLines()
            if DoiteConditionsTooltip.SetPlayerBuff then
                DoiteConditionsTooltip:SetPlayerBuff(idx)
                local tn = DoiteConditionsTooltipTextLeft1 and DoiteConditionsTooltipTextLeft1:GetText()
                if tn == auraName then
                    local tl = GetPlayerBuffTimeLeft(idx)
                    if tl and tl > 0 then return tl end
                    return nil
                end
            end
        end
    end

    return nil
end

-- === Stacks helpers ===

-- Compare: returns true if 'cnt' satisfies 'comp' vs 'target'
local function _StacksPasses(cnt, comp, target)
    if not cnt or not comp or target == nil then return true end
    if comp == ">=" then
        return cnt >= target
    elseif comp == "<=" then
        return cnt <= target
    elseif comp == "==" then
        return cnt == target
    end
    return true
end

-- Get stack count for a named aura on a unit (works for player/target on Turtle)
-- Returns a number (>=1) if found, or nil if not found.
local function _GetAuraStacksOnUnit(unit, auraName, wantDebuff)
    if not unit or not auraName then return nil end
    local i = 1
    while i <= 40 do
        local n = _GetAuraName(unit, i, wantDebuff)
        if not n then break end
        if n == auraName then
            if wantDebuff then
				local _, applications = UnitDebuff(unit, i)
				return applications or 1
			else
				local _, applications = UnitBuff(unit, i)
				return applications or 1
			end
        end
        i = i + 1
    end
    return nil
end

-- === Health / Combo Points / Formatting helpers ===

-- Percent HP (0..100) for unit; returns nil if unit invalid or no maxhp
local function _HPPercent(unit)
    if not unit or not UnitExists(unit) then return nil end
    local cur = UnitHealth(unit)
    local max = UnitHealthMax(unit)
    if not cur or not max or max <= 0 then return nil end
    return (cur * 100) / max
end

-- Compare helper: returns true if 'val' satisfies 'comp' vs 'target'
local function _ValuePasses(val, comp, target)
    if val == nil or comp == nil or target == nil then return true end
    if comp == ">=" then
        return val >= target
    elseif comp == "<=" then
        return val <= target
    elseif comp == "==" then
        return val == target
    end
    return true
end

-- Combo points reader (1.12 API)
local function _GetComboPointsSafe()
    if not UnitExists("target") then return 0 end
    local cp = GetComboPoints("player", "target")
    if not cp then return 0 end
    return cp
end

-- Is a class that uses combo points?
local function _PlayerUsesComboPoints()
    local _, cls = UnitClass("player")
    cls = cls and string.upper(cls) or ""
    return (cls == "ROGUE" or cls == "DRUID")
end

-- Time remaining formatter for overlay text:
--  >= 3600s -> "#h"
--  >=   60s -> "#m"
--  <    10s -> "#.#s" (tenths)
--  else      "#s"
local function _FmtRem(remSec)
    if not remSec or remSec <= 0 then return nil end
    if remSec >= 3600 then
        return string.format("%dh", math.floor(remSec / 3600))
    elseif remSec >= 60 then
        return string.format("%dm", math.floor(remSec / 60))
    elseif remSec < 10 then
        -- Stabilize tenths by truncating, not rounding up
        local t = math.floor(remSec * 10) / 10
        return string.format("%.1fs", t)
    else
        return string.format("%ds", math.floor(remSec))
    end
end


-- === Form / Stance evaluation (no fallbacks) ===
local function _ActiveFormMap()
    local map = {}
    for i = 1, 10 do
        local _, name, active = GetShapeshiftFormInfo(i)
        if not name then break end
        map[name] = (active and active == 1) and true or false
    end
    return map
end

local function _AnyActive(map, names)
    for _, n in ipairs(names) do
        if map[n] then return true end
    end
    return false
end

local function _DruidNoForm(map)
    -- No Bear/Cat/Aquatic/Travel/Swift Travel/Moonkin/Tree is active
    local any = _AnyActive(map, {
        "Dire Bear Form","Bear Form","Cat Form","Aquatic Form",
        "Travel Form","Swift Travel Form","Moonkin Form","Tree of Life Form"
    })
    return not any
end

local function _DruidStealth(auraSnap)
    -- Strictly via aura (Prowl) per spec
    local s = auraSnap and auraSnap.player
    local buffs = s and s.buffs
    return buffs and buffs["Prowl"] == true
end

-- Normalize editor labels so logic is robust to wording differences
local function _NormalizeFormLabel(s)
    if not s or s == "" then return "All" end
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    -- unify "All ..." variants (editor may say "All Auras", "All stances", etc.)
    if s == "All" or s == "All forms" or s == "All stances" or s == "All Auras" then
        return "All"
    end
    -- unify the druid "no form(s)" label
    if s == "0. No form" or s == "0. No forms" then
        return "0. No form"
    end
    return s
end

-- Paladin: no aura selected in the shapeshift bar
local function _PaladinNoAura(map)
    return not _AnyActive(map, {
        "Devotion Aura","Retribution Aura","Concentration Aura",
        "Shadow Resistance Aura","Frost Resistance Aura","Fire Resistance Aura","Sanctity Aura"
    })
end

local function _PassesFormRequirement(formStr, auraSnap)
    formStr = _NormalizeFormLabel(formStr)
    if not formStr or formStr == "All" then return true end

    local _, cls = UnitClass("player")
    cls = cls and string.upper(cls) or ""
    local map = _ActiveFormMap()

    -- WARRIOR
    if cls == "WARRIOR" then
        if formStr == "1. Battle"    then return map["Battle Stance"]    == true end
        if formStr == "2. Defensive" then return map["Defensive Stance"] == true end
        if formStr == "3. Berserker" then return map["Berserker Stance"] == true end
        if formStr == "Multi: 1+2"   then return _AnyActive(map, {"Battle Stance","Defensive Stance"}) end
        if formStr == "Multi: 1+3"   then return _AnyActive(map, {"Battle Stance","Berserker Stance"}) end
        if formStr == "Multi: 2+3"   then return _AnyActive(map, {"Defensive Stance","Berserker Stance"}) end
        return true
    end

    -- ROGUE
    if cls == "ROGUE" then
        if formStr == "1. Stealth"    then return map["Stealth"] == true end
        if formStr == "0. No Stealth" then return map["Stealth"] ~= true end
        return true
    end

    -- PRIEST
    if cls == "PRIEST" then
        if formStr == "1. Shadowform" then return map["Shadowform"] == true end
        if formStr == "0. No form"    then return map["Shadowform"] ~= true end
        return true
    end

    -- DRUID  (accepts both "0. No form" and "0. No forms")
    if cls == "DRUID" then
        if formStr == "0. No form"    then return _DruidNoForm(map) end
        if formStr == "1. Bear"       then return _AnyActive(map, {"Dire Bear Form","Bear Form"}) end
        if formStr == "2. Aquatic"    then return map["Aquatic Form"] == true end
        if formStr == "3. Cat"        then return map["Cat Form"] == true end
        if formStr == "4. Travel"     then return _AnyActive(map, {"Travel Form","Swift Travel Form"}) end
        if formStr == "5. Moonkin"    then return map["Moonkin Form"] == true end
        if formStr == "6. Tree"       then return map["Tree of Life Form"] == true end
        -- stealth variants use aura state
        if formStr == "7. Stealth"    then return _DruidStealth(auraSnap) end
        if formStr == "8. No Stealth" then return not _DruidStealth(auraSnap) end
        -- multis
        if formStr == "Multi: 0+5"     then return _DruidNoForm(map) or (map["Moonkin Form"] == true) end
        if formStr == "Multi: 0+6"     then return _DruidNoForm(map) or (map["Tree of Life Form"] == true) end
        if formStr == "Multi: 1+3"     then return _AnyActive(map, {"Dire Bear Form","Bear Form","Cat Form"}) end
        if formStr == "Multi: 3+7"     then return (map["Cat Form"] == true) or _DruidStealth(auraSnap) end
        if formStr == "Multi: 3+8"     then return (map["Cat Form"] == true) and (not _DruidStealth(auraSnap)) end
        if formStr == "Multi: 5+6"     then return _AnyActive(map, {"Moonkin Form","Tree of Life Form"}) end
        if formStr == "Multi: 0+5+6"   then return _DruidNoForm(map) or _AnyActive(map, {"Moonkin Form","Tree of Life Form"}) end
        if formStr == "Multi: 1+3+8"   then return _AnyActive(map, {"Dire Bear Form","Bear Form","Cat Form"}) and (not _DruidStealth(auraSnap)) end
        return true
    end

    -- PALADIN (treat auras as shapeshift forms via GetShapeshiftFormInfo)
    if cls == "PALADIN" then
        -- Editor options: "All Auras", "No Aura", "1. Devotion" .. "7. Sanctity" + multis
        if formStr == "No Aura"                 then return _PaladinNoAura(map) end
        if formStr == "1. Devotion"             then return map["Devotion Aura"]          == true end
        if formStr == "2. Retribution"          then return map["Retribution Aura"]       == true end
        if formStr == "3. Concentration"        then return map["Concentration Aura"]     == true end
        if formStr == "4. Shadow Resistance"    then return map["Shadow Resistance Aura"] == true end
        if formStr == "5. Frost Resistance"     then return map["Frost Resistance Aura"]  == true end
        if formStr == "6. Fire Resistance"      then return map["Fire Resistance Aura"]   == true end
        if formStr == "7. Sanctity"             then return map["Sanctity Aura"]          == true end

        -- multis (logical OR among the listed auras)
        if formStr == "Multi: 1+2"               then return _AnyActive(map, {"Devotion Aura","Retribution Aura"}) end
        if formStr == "Multi: 1+3"               then return _AnyActive(map, {"Devotion Aura","Concentration Aura"}) end
        if formStr == "Multi: 1+4+5+6"           then return _AnyActive(map, {"Devotion Aura","Shadow Resistance Aura","Frost Resistance Aura","Fire Resistance Aura"}) end
        if formStr == "Multi: 1+7"               then return _AnyActive(map, {"Devotion Aura","Sanctity Aura"}) end
        if formStr == "Multi: 1+2+3"             then return _AnyActive(map, {"Devotion Aura","Retribution Aura","Concentration Aura"}) end
        if formStr == "Multi: 1+2+3+4+5+6"       then return _AnyActive(map, {"Devotion Aura","Retribution Aura","Concentration Aura","Shadow Resistance Aura","Frost Resistance Aura","Fire Resistance Aura"}) end
        if formStr == "Multi: 2+3"               then return _AnyActive(map, {"Retribution Aura","Concentration Aura"}) end
        if formStr == "Multi: 2+4+5+6"           then return _AnyActive(map, {"Retribution Aura","Shadow Resistance Aura","Frost Resistance Aura","Fire Resistance Aura"}) end
        if formStr == "Multi: 2+7"               then return _AnyActive(map, {"Retribution Aura","Sanctity Aura"}) end
        if formStr == "Multi: 2+3+4+5+6"         then return _AnyActive(map, {"Retribution Aura","Concentration Aura","Shadow Resistance Aura","Frost Resistance Aura","Fire Resistance Aura"}) end
        if formStr == "Multi: 3+4+5+6"           then return _AnyActive(map, {"Concentration Aura","Shadow Resistance Aura","Frost Resistance Aura","Fire Resistance Aura"}) end
        if formStr == "Multi: 3+7"               then return _AnyActive(map, {"Concentration Aura","Sanctity Aura"}) end
        if formStr == "Multi: 4+5+6+7"           then return _AnyActive(map, {"Shadow Resistance Aura","Frost Resistance Aura","Fire Resistance Aura","Sanctity Aura"}) end

        return true
    end

    return true
end

local function _EnsureAbilityTexture(frame, data)
    if not frame or not frame.icon or not data then return end
    if frame.icon:GetTexture() then return end

    local spellName = data.displayName or data.name
    if not spellName then return end

    local idx = _GetSpellIndexByName(spellName)
    if idx then
        local tex = GetSpellTexture(idx, BOOKTYPE_SPELL)
        if tex then
            frame.icon:SetTexture(tex)
            IconCache[spellName] = tex -- persist
        end
    end
end


-- Ensure a Buff/Debuff icon has a texture (player/target, then fallback via spellbook)
local function _EnsureAuraTexture(frame, data)
    if not frame or not frame.icon or not data then return end

    local curTex = frame.icon:GetTexture()
    local isPlaceholder = (curTex == nil) or (type(curTex) == "string" and string.find(curTex, "INV_Misc_QuestionMark"))

    local c = data.conditions and data.conditions.aura
    local name = data.displayName or data.name
    if not c or not name then return end

    local cached = IconCache[name]
    if cached and (not frame.icon:GetTexture() or frame.icon:GetTexture() ~= cached) then
        frame.icon:SetTexture(cached)
        return
    end

    -- Resolve unit(s) to scan
    local tgt = c.target or (c.targetSelf and "self") or (c.targetTarget and "target") or "self"
    local checkSelf, checkTarget = false, false
    if tgt == "self" then
        checkSelf = true
    elseif tgt == "target" then
        checkTarget = true
    elseif tgt == "both" then
        checkSelf = true; checkTarget = true
    else
        checkSelf = true
    end

    local function tryUnit(unit)
        -- 1) BUFFS: confirm NAME via tooltip, then take TEXTURE from UnitBuff (Turtle 1.12 behavior)
        local i = 1
        while i <= 40 do
            local n = _GetAuraName(unit, i, false)
            if not n then break end
            if n == name then
                local tex = UnitBuff(unit, i) -- returns texture or nil
                if tex and (isPlaceholder or curTex ~= tex) then
                    frame.icon:SetTexture(tex)
                    IconCache[name] = tex -- persist in DoiteAurasDB.cache
                end
                return true
            end
            i = i + 1
        end

        -- 2) DEBUFFS: confirm NAME via tooltip, then take TEXTURE from UnitDebuff (Turtle 1.12 behavior)
        i = 1
        while i <= 40 do
            local n = _GetAuraName(unit, i, true)
            if not n then break end
            if n == name then
                local tex = UnitDebuff(unit, i) -- returns texture or nil
                if tex and (isPlaceholder or curTex ~= tex) then
                    frame.icon:SetTexture(tex)
                    IconCache[name] = tex -- persist in DoiteAurasDB.cache
                end
                return true
            end
            i = i + 1
        end

        return false
    end

    local got = false
    if checkSelf then got = tryUnit("player") end
    if (not got) and checkTarget and UnitExists("target") then got = tryUnit("target") end

	-- Fallback to spellbook texture
	if (not got) then
		local i = 1
		while i <= 200 do
			local s = GetSpellName(i, BOOKTYPE_SPELL)
			if not s then break end
			if s == name then
				local tex = GetSpellTexture(i, BOOKTYPE_SPELL)
				if tex and (isPlaceholder or curTex ~= tex) then
					frame.icon:SetTexture(tex)
					IconCache[name] = tex
				end
				break
			end
			i = i + 1
		end
		-- Nudge the next regular update, but don't re-enter recursively
		dirty_aura = true
		return
	end

end

---------------------------------------------------------------
-- Ability condition evaluation
---------------------------------------------------------------
local function CheckAbilityConditions(data)
    if not data or not data.conditions or not data.conditions.ability then
        return true -- if no conditions, always show
    end
    local c = data.conditions.ability

    local show = true

    -- === 1. Cooldown / usability ===
	local spellName = data.displayName or data.name
	local spellIndex = _GetSpellIndexByName(spellName)
	local bookType = BOOKTYPE_SPELL
	local foundInBook = (spellIndex ~= nil)

	if not foundInBook then
		return false
	end

    local function IsOnCooldown(idx)
        if not idx then return false end
        local start, dur, enable = GetSpellCooldown(idx, bookType)
        return (start and start > 0 and dur and dur > 1.5)
    end

    if c.mode == "usable" and spellIndex then
        local usable, noMana = IsSpellUsable(spellName)
        local onCooldown = IsOnCooldown(spellIndex)
        if (usable ~= 1) or onCooldown then
            show = false
        end
    elseif c.mode == "notcd" and spellIndex then
        if IsOnCooldown(spellIndex) then show = false end
    elseif c.mode == "oncd" and spellIndex then
        if not IsOnCooldown(spellIndex) then show = false end
    end

    -- === Combat state ===
    local inCombatFlag  = (c.inCombat == true)
    local outCombatFlag = (c.outCombat == true)

    -- If both are checked, always allowed
    if not (inCombatFlag and outCombatFlag) then
        if inCombatFlag and not InCombat() then show = false end
        if outCombatFlag and InCombat() then show = false end
    end

	-- === 3. Target (multi-select: help/harm/self; at least one)
	local allowHelp = (c.targetHelp == true)
	local allowHarm = (c.targetHarm == true)
	local allowSelf = (c.targetSelf == true)

	-- If nothing selected, do NOT gate on target at all.
	local ok = true
	if allowHelp or allowHarm or allowSelf then
		ok = false

		-- Self: must be explicitly targeting yourself
		if allowSelf and UnitExists("target") and UnitIsUnit("player","target") then
			ok = true
		end

		-- Help: friendly target (EXCLUDING self), requires a target
		if (not ok) and allowHelp and UnitExists("target")
		   and UnitIsFriend("player","target")
		   and (not UnitIsUnit("player","target")) then
			ok = true
		end

		-- Harm: hostile/attackable and not friendly, requires a target
		if (not ok) and allowHarm and UnitExists("target")
		   and UnitCanAttack("player","target")
		   and (not UnitIsFriend("player","target")) then
			ok = true
		end
	end

	if not ok then show = false end

    -- === 4. Form / Stance requirement (if set)
    if show and c.form and c.form ~= "All" then
        if not _PassesFormRequirement(c.form, auraSnapshot) then
            show = false
        end
    end

	    -- === HP threshold (% of max) — player or target
    if show and c.hpComp and c.hpVal and c.hpMode and c.hpMode ~= "" then
        local hpTarget = nil
        if c.hpMode == "my" then
            hpTarget = "player"
        elseif c.hpMode == "target" then
            -- Gate by target kind if user also set targetHelp/targetHarm/targetSelf
            if UnitExists("target") then
                local allowHelp = (c.targetHelp == true)
                local allowHarm = (c.targetHarm == true)
                local allowSelf = (c.targetSelf == true)

                -- If any of help/harm/self are set, enforce "harm" implies hostile, "help" implies friendly (excluding self here)
                if (allowHelp or allowHarm or allowSelf) then
                    local okHP = true
                    if allowSelf then
                        okHP = UnitIsUnit("player","target")
                    elseif allowHelp then
                        okHP = UnitIsFriend("player","target") and (not UnitIsUnit("player","target"))
                    elseif allowHarm then
                        okHP = UnitCanAttack("player","target") and (not UnitIsFriend("player","target"))
                    end
                    if not okHP then hpTarget = nil else hpTarget = "target" end
                else
                    hpTarget = "target"
                end
            end
        end
        if hpTarget then
            local pct = _HPPercent(hpTarget)
            local thr = tonumber(c.hpVal)
            if thr and not _ValuePasses(pct, c.hpComp, thr) then
                show = false
            end
        end
    end

	    -- === Combo Points (Rogue/Druid only) ===
    if show and c.cpEnabled == true and _PlayerUsesComboPoints() then
        local cp = _GetComboPointsSafe()
        local thr = tonumber(c.cpVal)
        if thr and c.cpComp and c.cpComp ~= "" then
            if not _ValuePasses(cp, c.cpComp, thr) then
                show = false
            end
        end
    end


    -- === Power threshold (% of max) ===
    if c.powerEnabled
       and c.powerComp ~= nil and c.powerComp ~= ""
       and c.powerVal  ~= nil and c.powerVal  ~= "" then

        local valPct    = GetPowerPercent()
        local targetPct = tonumber(c.powerVal) or 0
        local comp      = c.powerComp

        local pass = true
        if comp == ">=" then
            pass = (valPct >= targetPct)
        elseif comp == "<=" then
            pass = (valPct <= targetPct)
        elseif comp == "==" then
            pass = (valPct == targetPct)
        end

        if not pass then
            show = false
        end
    end

    -- === Remaining (cooldown time left) ===
    -- Only meaningful when the spell is actually on cooldown. If there is no cooldown/timer, ignore the setting.
    if c.remainingEnabled and c.remainingComp and c.remainingComp ~= "" and c.remainingVal ~= nil and c.remainingVal ~= "" then
        local threshold = tonumber(c.remainingVal)
        if threshold then
            local rem = _AbilityRemainingSeconds(spellIndex, bookType)
            -- Only apply comparison if the spell has a real remaining time (>0). Otherwise ignore.
            if rem and rem > 0 then
                if not _RemainingPasses(rem, c.remainingComp, threshold) then
                    show = false
                end
            end
        end
    end

    local glow = c.glow and true or false
    local grey = c.greyscale and true or false

    return show, glow, grey
end

---------------------------------------------------------------
-- Aura condition evaluation (with caching)
---------------------------------------------------------------
local function CheckAuraConditions(data)
    if not data or not data.conditions or not data.conditions.aura then
        return true, false, false
    end
    local c = data.conditions.aura
    local name = data.displayName or data.name
    if not name then return false, false, false end

    -- Enforce correct aura type
    local wantBuff   = (data.type == "Buff")
    local wantDebuff = (data.type == "Debuff")
    if not wantBuff and not wantDebuff then
        -- Back-compat: if type missing, allow either
        wantBuff, wantDebuff = true, true
    end

    -- multi-select booleans
	local allowHelp = (c.targetHelp == true)
	local allowHarm = (c.targetHarm == true)
	local allowSelf = (c.targetSelf == true)

	-- If none selected, default to Self
	if (not allowHelp) and (not allowHarm) and (not allowSelf) then
		allowSelf = true
	end

	-- Self is exclusive with Help/Harm
	if allowSelf then
		allowHelp, allowHarm = false, false
	end

	-- === Target gating exactly as requested ===
	local requiresTarget = (allowHelp or allowHarm) and (not allowSelf)
	if requiresTarget then
		if not UnitExists("target") then
			-- Must have a target for help/harm modes
			return false, false, false
		end
		if allowHelp then
			-- Require friendly (player counts as friendly only if actively targeted)
			if not UnitIsFriend("player","target") then
				return false, false, false
			end
		end
		if allowHarm then
			-- Require hostile/attackable and not friendly
			if UnitIsFriend("player","target") or not UnitCanAttack("player","target") then
				return false, false, false
			end
		end
	end

	local found = false

	-- Self auras — aura on player, regardless of target
	if (not found) and allowSelf then
		local s = auraSnapshot.player
		if s and ((wantBuff and s.buffs[name]) or (wantDebuff and s.debuffs[name])) then
			found = true
		else
			-- light live probe if snapshot missed it
			local i, hit = 1, false
			if wantBuff then
				while i <= 40 do
					local n = _GetAuraName("player", i, false); if not n then break end
					if n == name then hit = true; break end
					i = i + 1
				end
			end
			if (not hit) and wantDebuff then
				i = 1
				while i <= 40 do
					local n = _GetAuraName("player", i, true); if not n then break end
					if n == name then hit = true; break end
					i = i + 1
				end
			end
			if hit then found = true end
		end
	end

	-- Target (help) — requires friendly target (already gated above)
	if (not found) and allowHelp then
		local s = auraSnapshot.target
		if s and ((wantBuff and s.buffs[name]) or (wantDebuff and s.debuffs[name])) then
			found = true
		end
	end

	-- Target (harm) — requires hostile target (already gated above)
	if (not found) and allowHarm then
		local s = auraSnapshot.target
		if s and ((wantBuff and s.buffs[name]) or (wantDebuff and s.debuffs[name])) then
			found = true
		end
	end

    -- Decide show based on mode first
    local show
    if c.mode == "missing" then
        show = (not found)
    else -- default and "found"
        show = found
    end

    -- Combat state (use the same helper as abilities; if both checked, always allowed)
    local inCombatFlag  = (c.inCombat == true)
    local outCombatFlag = (c.outCombat == true)
    if not (inCombatFlag and outCombatFlag) then
        if inCombatFlag and not InCombat() then show = false end
        if outCombatFlag and InCombat() then show = false end
    end

    -- === Form / Stance requirement (if set)
    if c.form and c.form ~= "All" then
        if not _PassesFormRequirement(c.form, auraSnapshot) then
            show = false
        end
    end

	    -- === Power threshold (% of max) — same semantics as abilities
    if show and c.powerEnabled
       and c.powerComp and c.powerComp ~= ""
       and c.powerVal  and c.powerVal  ~= "" then

        local valPct    = GetPowerPercent()
        local targetPct = tonumber(c.powerVal) or 0
        local comp      = c.powerComp

        local pass = true
        if comp == ">=" then
            pass = (valPct >= targetPct)
        elseif comp == "<=" then
            pass = (valPct <= targetPct)
        elseif comp == "==" then
            pass = (valPct == targetPct)
        end
        if not pass then show = false end
    end

	    -- === HP threshold (% of max) — respects target flags
    if show and c.hpComp and c.hpVal and c.hpMode and c.hpMode ~= "" then
        local hpTarget = nil
        if c.hpMode == "my" then
            hpTarget = "player"
        elseif c.hpMode == "target" then
            -- Decide if "target" qualifies given help/harm/self flags:
            local allowHelp = (c.targetHelp == true)
            local allowHarm = (c.targetHarm == true)
            local allowSelf = (c.targetSelf == true)

            if UnitExists("target") then
                if allowSelf then
                    if UnitIsUnit("player","target") then hpTarget = "target" end
                elseif allowHelp then
                    if UnitIsFriend("player","target") and (not UnitIsUnit("player","target")) then hpTarget = "target" end
                elseif allowHarm then
                    if UnitCanAttack("player","target") and (not UnitIsFriend("player","target")) then hpTarget = "target" end
                else
                    -- no target gating set -> accept any target
                    hpTarget = "target"
                end
            end
        end
        if hpTarget then
            local pct = _HPPercent(hpTarget)
            local thr = tonumber(c.hpVal)
            if thr and not _ValuePasses(pct, c.hpComp, thr) then
                show = false
            end
        end
    end

	    -- === Combo Points (Rogue/Druid only) ===
    if show and c.cpEnabled == true and _PlayerUsesComboPoints() then
        local cp = _GetComboPointsSafe()
        local thr = tonumber(c.cpVal)
        if thr and c.cpComp and c.cpComp ~= "" then
            if not _ValuePasses(cp, c.cpComp, thr) then
                show = false
            end
        end
    end

	-- === Remaining (aura time left) — only valid for player-self auras ===
	-- Works only on player auras in 1.12; silently ignored elsewhere.
	if c.remainingEnabled
	   and c.remainingComp and c.remainingComp ~= ""
	   and c.remainingVal  ~= nil and c.remainingVal  ~= "" then

		if c.mode ~= "missing" and show and (c.targetSelf == true) then
			local threshold = tonumber(c.remainingVal)
			if threshold then
				local rem = _PlayerAuraRemainingSeconds(name)
				if rem and rem > 0 then
					if not _RemainingPasses(rem, c.remainingComp, threshold) then
						show = false
					end
				end
				-- If rem is nil (timeless aura / no timer), ignore as requested.
			end
		end
	end

    -- === Stacks (aura applications) — valid for self/help/harm on Turtle API ===
    -- Only meaningful when aura is FOUND (mode == "found").
    if c.stacksEnabled
       and c.stacksComp and c.stacksComp ~= ""
       and c.stacksVal  ~= nil and c.stacksVal  ~= ""
       and c.mode ~= "missing"
       and show then

        local threshold = tonumber(c.stacksVal)
        if threshold then
            -- Decide which unit to read from, based on target flags (same logic as your found-target logic)
            local unitToCheck = nil
            if c.targetSelf == true then
                unitToCheck = "player"
            elseif c.targetHelp == true and UnitExists("target") and UnitIsFriend("player","target") then
                unitToCheck = "target"
            elseif c.targetHarm == true
               and UnitExists("target")
               and UnitCanAttack("player","target")
               and (not UnitIsFriend("player","target")) then
                unitToCheck = "target"
            end

            if unitToCheck then
                local cnt = _GetAuraStacksOnUnit(unitToCheck, name, wantDebuff)
                -- If we could read a stack count, enforce comparison; if we couldn't, silently ignore (per spec).
                if cnt and (not _StacksPasses(cnt, c.stacksComp, threshold)) then
                    show = false
                end
            end
        end
    end

    local glow = c.glow and true or false
    local grey = c.greyscale and true or false
    return show, glow, grey
end

---------------------------------------------------------------
-- Main update
---------------------------------------------------------------
function DoiteConditions:EvaluateAll()
    local source = (DoiteDB and DoiteDB.icons) or (DoiteAurasDB and DoiteAurasDB.spells)
    if not source then return end

    for key, data in pairs(source) do
        if data and data.type then
            data.key = key
            if data.type == "Ability" then
                local show, glow, grey = CheckAbilityConditions(data)
                DoiteConditions:ApplyVisuals(key, show, glow, grey)
            elseif data.type == "Buff" or data.type == "Debuff" then
                local show, glow, grey = CheckAuraConditions(data)
                DoiteConditions:ApplyVisuals(key, show, glow, grey)
            end
        end
    end
end

---------------------------------------------------------------
-- Apply visuals to icons
---------------------------------------------------------------
function DoiteConditions:ApplyVisuals(key, show, glow, grey)
    local frame = _G["DoiteIcon_" .. key]
    if not frame then
        if DoiteAuras_RefreshIcons then DoiteAuras_RefreshIcons() end
        frame = _G["DoiteIcon_" .. key]
        if not frame then return end
    end

    local dataTbl = (DoiteDB and DoiteDB.icons and DoiteDB.icons[key])
                    or (DoiteAurasDB and DoiteAurasDB.spells and DoiteAurasDB.spells[key])

	-- load textures when showing OR while this key is being edited
	local editing = _IsKeyUnderEdit(key)
	if show or editing then
		if frame.icon and not frame.icon:GetTexture() and dataTbl and (dataTbl.displayName or dataTbl.name) then
			local cached = IconCache[dataTbl.displayName or dataTbl.name]
			if cached then frame.icon:SetTexture(cached) else frame.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark") end
		end
		if dataTbl then
			if dataTbl.type == "Ability" then
				_EnsureAbilityTexture(frame, dataTbl)
			elseif dataTbl.type == "Buff" or dataTbl.type == "Debuff" then
				_EnsureAuraTexture(frame, dataTbl)
			end
		end
	end


    ------------------------------------------------------------
    -- Slider (driven by SlideMgr; ignores GCD; super smooth)
    ------------------------------------------------------------
    local slideActive, dx, dy, slideAlpha, supGlow, supGrey = false, 0, 0, 1, false, false

    if dataTbl and dataTbl.type == "Ability" and dataTbl.conditions and dataTbl.conditions.ability then
        local ca = dataTbl.conditions.ability
        local startedSlide = false
        local stoppedSlide = false                                -- NEW

        if ca.slider and (ca.mode == "usable" or ca.mode == "notcd") then
            local spellName = dataTbl.displayName or dataTbl.name
            local rem, dur = _AbilityCooldownByName(spellName)

            local wasSliding = SlideMgr.active and SlideMgr.active[key]
            local maxWindow = math.min(3.0, (dur or 0) * 0.6)
            local shouldStart    = (rem and dur and dur > 1.6 and rem > 0 and rem <= maxWindow)
            local shouldContinue = wasSliding and rem and rem > 0

            if shouldStart or shouldContinue then
                local baseX, baseY = 0, 0
                if _GetBaseXY then baseX, baseY = _GetBaseXY(key, dataTbl) end
                SlideMgr:StartOrUpdate(key, (ca.sliderDir or "center"), baseX, baseY, GetTime() + rem)
                startedSlide = (not wasSliding) and true or false   -- NEW: detect start edge
            else
                if wasSliding then stoppedSlide = true end          -- NEW: detect stop edge
                SlideMgr:Stop(key)
            end
        else
            if SlideMgr.active and SlideMgr.active[key] then        -- NEW: detect stop when slider toggled off
                stoppedSlide = true
            end
            SlideMgr:Stop(key)
        end

        -- === NEW: immediate group reflow on slide start/stop ===
        if (startedSlide or stoppedSlide) and DoiteGroup and DoiteGroup.ApplyGroupLayout then
            if type(DoiteAuras) == "table" and type(DoiteAuras.GetAllCandidates) == "function" then
                _G["DoiteGroup_NeedReflow"] = true
            end
        end
    else
        SlideMgr:Stop(key)
    end

	
	    -- Pull the current slide offset/alpha (if sliding)
    local allowSlideShow = false
    do
        local active, sdx, sdy, a = SlideMgr:Get(key)
        slideActive, dx, dy, slideAlpha = active, sdx, sdy, a

        -- ==== Effective flags with OLD-behavior defaults ====
        -- 1) Always allow showing during slide (preview), like OLD code.
        allowSlideShow = false
		if slideActive and dataTbl and dataTbl.conditions and dataTbl.conditions.ability then
			allowSlideShow = (dataTbl.conditions.ability.slider == true)
		end
   -- NOTE: NO 'local' here; write the outer variable

        -- 2) Default suppression during slide UNLESS slider is explicitly enabled.
        local isSliderEnabled = false
        local sliderGlowFlag  = false
        local sliderGreyFlag  = false

        if dataTbl and dataTbl.type == "Ability" and dataTbl.conditions and dataTbl.conditions.ability then
            local ca = dataTbl.conditions.ability
            if ca.slider == true then
                isSliderEnabled = true
                sliderGlowFlag  = (ca.sliderGlow == true)
                sliderGreyFlag  = (ca.sliderGrey == true)
            end
        end

        -- Decide which effects to use this frame:
        --  - Not sliding -> normal glow/greyscale
        --  - Sliding + slider enabled -> sliderGlow/sliderGrey
        --  - Sliding + slider disabled -> suppress both (match OLD code)
        local useGlow, useGrey
        if slideActive then
            if isSliderEnabled then
                useGlow = sliderGlowFlag
                useGrey = sliderGreyFlag
            else
                useGlow = false
                useGrey = false
            end
        else
            useGlow = (glow == true)
            useGrey = (grey == true)
        end

        -- Flags for other systems / change detector
        frame._daSliding      = slideActive and true or false
        frame._daShouldShow   = show and true or false
        frame._daUseGlow      = useGlow and true or false
        frame._daUseGreyscale = useGrey and true or false
    end

	-- Determine baseline anchoring
	local baseX, baseY = 0, 0
	if _GetBaseXY and dataTbl then baseX, baseY = _GetBaseXY(key, dataTbl) end

	 -- If this icon belongs to a group, prefer the latest computed position (for leaders AND followers)
    local isGrouped = (dataTbl and dataTbl.group and dataTbl.group ~= "" and dataTbl.group ~= "no")
	if isGrouped and _G["DoiteGroup_Computed"] and _G["DoiteGroup_Computed"][dataTbl.group] then
		local arr = _G["DoiteGroup_Computed"][dataTbl.group]
		local n = table.getn(arr)
		for idx = 1, n do
			local e = arr[idx]
			if e and e.key == key and e._computedPos then
				baseX = e._computedPos.x or baseX
				baseY = e._computedPos.y or baseY
				break
			end
		end
	end



	if slideActive then SlideMgr:UpdateBase(key, baseX, baseY) end

    -- Show during slide preview even if main conditions would hide,
    -- but ONLY if the slider for this ability explicitly allows it.
    local showForSlide = (show or allowSlideShow)

	-- If this is the key currently being edited, force it visible regardless of conditions/group caps
	if editing then
		showForSlide = true
	end

	-- Group capacity may block this icon unless we are editing this very key
	if frame._daBlockedByGroup and (not editing) then
		showForSlide = false
	end

    -- Apply position and alpha (no stutter: we set exact coordinates each paint)
    do
        local isGrouped = (dataTbl and dataTbl.group and dataTbl.group ~= "" and dataTbl.group ~= "no")
        local isLeader = (dataTbl and dataTbl.isLeader == true)

		-- Apply position and alpha (no stutter: we set exact coordinates each paint)
		do
			-- When sliding: apply transient movement to everyone (leaders + followers),
			-- using the computed/group base for followers (set above).
			if slideActive then
				frame:ClearAllPoints()
				frame:SetPoint("CENTER", UIParent, "CENTER", baseX + dx, baseY + dy)
				frame:SetAlpha(slideAlpha)
			else
				-- When not sliding: do NOT force followers' points here.
				-- Leaders and ungrouped icons still position themselves so they show up when not in a group.
				if not (isGrouped and not isLeader) then
					frame:ClearAllPoints()
					frame:SetPoint("CENTER", UIParent, "CENTER", baseX, baseY)
					frame:SetAlpha((dataTbl and dataTbl.alpha) or 1)
				else
					-- Followers:
					-- If a computed group base was resolved above, we can safely anchor here.
					-- (baseX/baseY were replaced by the computed pos when available)
					if baseX ~= nil and baseY ~= nil then
						frame:ClearAllPoints()
						frame:SetPoint("CENTER", UIParent, "CENTER", baseX, baseY)
					end
					frame:SetAlpha((dataTbl and dataTbl.alpha) or 1)
				end
			end
		end
		-- === Overlay Text: cooldown remaining + stacks (forced above glow) ===
        do
            -- Ensure a dedicated top layer so text always renders above any glow frames
            if not frame._daTextLayer then
                local tl = CreateFrame("Frame", nil, frame)
                frame._daTextLayer = tl
                tl:SetAllPoints(frame)
            end
            -- Keep this child well above siblings (incl. typical glow frames)
            do
                local baseLevel = frame:GetFrameLevel() or 0
                frame._daTextLayer:SetFrameStrata(frame:GetFrameStrata() or "MEDIUM")
                frame._daTextLayer:SetFrameLevel(baseLevel + 50)
            end

            -- Lazy-create fontstrings parented to the text layer
            if not frame._daTextRem then
                local fs = frame._daTextLayer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                fs:SetJustifyH("CENTER"); fs:SetJustifyV("MIDDLE")
                frame._daTextRem = fs
            end
            if not frame._daTextStacks then
                local fs2 = frame._daTextLayer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                fs2:SetJustifyH("RIGHT"); fs2:SetJustifyV("BOTTOM")
                frame._daTextStacks = fs2
				frame._daLastTextSize = 0
            end

			-- Only resize if changed
			local w = frame:GetWidth() or 36
			local last = frame._daLastTextSize or 0
			if math.abs(w - last) >= 1 then
				frame._daLastTextSize = w
				local remSize   = math.max(10, math.floor(w * 0.42))
				local stackSize = math.max(8,  math.floor(w * 0.28))
				frame._daTextRem:SetFont(GameFontHighlight:GetFont(), remSize, "OUTLINE")
				frame._daTextStacks:SetFont(GameFontNormalSmall:GetFont(), stackSize, "OUTLINE")
			end

            -- Anchor (relative to the icon frame; parented to _daTextLayer)
            frame._daTextRem:ClearAllPoints()
            frame._daTextRem:SetPoint("CENTER", frame, "CENTER", 0, 0)

            frame._daTextStacks:ClearAllPoints()
            frame._daTextStacks:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)

            -- Defaults hidden; show when we set content
            frame._daTextRem:SetText("")
            frame._daTextRem:Hide()
            frame._daTextStacks:SetText("")
            frame._daTextStacks:Hide()

            -- ========== Remaining Time ==========
            local wantRem = false
            local remText = nil

            -- Decide if we should show time text for abilities
            local function _ShowAbilityTime(ca, rem, dur, slideActive)
                if not rem or rem <= 0 then return false end
                dur = dur or 0

                -- 1) ON COOLDOWN: always show for the entire real cooldown.
                --    No "last 60%" window; still ignore pure non-cooldown (dur==0).
                if ca.mode == "oncd" then
                    return (dur > 0)  -- allow short cds too; icon itself is already gated by >1.5s in conditions
                end

                -- 2) USABLE / NOTCD with slider: if slide is active,
                --    keep showing even if the remaining time is being postponed by GCD.
                if (ca.mode == "usable" or ca.mode == "notcd") and ca.slider == true then
                    if slideActive then
                        return true  -- ignore the 1.6s/GCD filter while sliding
                    end
                    -- when not sliding: restrict to late window to avoid spam
                    local maxWindow = math.min(3.0, (dur or 0) * 0.6)
                    return rem <= maxWindow and (dur > 1.6)
                end

                -- Default (paranoid): late window + real cooldown
                local maxWindow = math.min(3.0, (dur or 0) * 0.6)
                return (dur > 1.6) and (rem <= maxWindow)
            end

            if dataTbl then
                if dataTbl.type == "Ability" and dataTbl.conditions and dataTbl.conditions.ability then
                    local ca = dataTbl.conditions.ability
                    if ca.textTimeRemaining == true then
                        local spellName = dataTbl.displayName or dataTbl.name
                        local rem, dur  = _AbilityCooldownByName(spellName)

                        -- If we SHOULD show (per rules above), format and display.
                        if _ShowAbilityTime(ca, rem, dur, slideActive) then
                            remText = _FmtRem(rem)
                            wantRem = (remText ~= nil)
                        end
                    end

                elseif (dataTbl.type == "Buff" or dataTbl.type == "Debuff")
                   and dataTbl.conditions and dataTbl.conditions.aura then
                    local ca = dataTbl.conditions.aura
                    if ca.textTimeRemaining == true and ca.targetSelf == true then
                        -- Icon text timer only supported for player-self auras in 1.12
                        local auraName = dataTbl.displayName or dataTbl.name
                        local rem = _PlayerAuraRemainingSeconds(auraName)
                        if rem and rem > 0 then
                            remText = _FmtRem(rem)
                            wantRem = (remText ~= nil)
                        end
                    end
                end
            end

            if wantRem and remText then
                frame._daTextRem:SetText(remText)
                frame._daTextRem:SetTextColor(1, 1, 1, 1) -- white
                frame._daTextRem:Show()
            end

            -- ========== Stack Counter (auras only) ==========
            if dataTbl and (dataTbl.type == "Buff" or dataTbl.type == "Debuff")
               and dataTbl.conditions and dataTbl.conditions.aura then
                local ca = dataTbl.conditions.aura
                if ca.textStackCounter == true then
                    local auraName = dataTbl.displayName or dataTbl.name
                    local wantDebuff = (dataTbl.type == "Debuff")

                    -- Resolve which unit to read stacks from (same logic pattern as in CheckAuraConditions)
                    local unitToCheck = nil
                    if ca.targetSelf == true then
                        unitToCheck = "player"
                    elseif ca.targetHelp == true and UnitExists("target") and UnitIsFriend("player","target") then
                        unitToCheck = "target"
                    elseif ca.targetHarm == true
                       and UnitExists("target")
                       and UnitCanAttack("player","target")
                       and (not UnitIsFriend("player","target")) then
                        unitToCheck = "target"
                    end

                    if unitToCheck then
                        local cnt = _GetAuraStacksOnUnit(unitToCheck, auraName, wantDebuff)
                        if cnt and cnt >= 1 then
                            frame._daTextStacks:SetText(tostring(cnt))
                            frame._daTextStacks:SetTextColor(1, 0.2, 0.2, 1) -- red
                            frame._daTextStacks:Show()
                        end
                    end
                end
            end
        end
    end

	-- === Apply EFFECTS with change detection (don’t restart animations every frame) ===
	do
		-- Decide final show flag (editing & group gating preserved)
		local showForSlide = (show or allowSlideShow)
		if editing then showForSlide = true end
		if frame._daBlockedByGroup and (not editing) then showForSlide = false end

		-- Show/hide only when it actually changes
		if frame._daLastShown ~= showForSlide then
			frame._daLastShown = showForSlide
			if showForSlide then frame:Show() else frame:Hide() end
		end

		-- GREYSCALE — only flip when it changes
		if frame.icon then
			local wantGrey = (frame._daUseGreyscale == true) and showForSlide
			if frame._daLastGrey ~= wantGrey then
				frame._daLastGrey = wantGrey
				if wantGrey then
					frame.icon:SetDesaturated(1)
				else
					frame.icon:SetDesaturated(nil)
				end
			end
		end

		-- GLOW — only start/stop when it changes (preserve animation)
		if DG then
			local wantGlow = (frame._daUseGlow == true) and showForSlide
			if frame._daLastGlow ~= wantGlow then
				frame._daLastGlow = wantGlow
				if wantGlow then
					DG.Start(frame)
				else
					DG.Stop(frame)
				end
			end
		end
	end


    ----------------------------------------------------------------
    -- Reflow groups when this icon’s logical visibility flips.
    -- This covers Buff/Debuff-only groups (no abilities involved).
    ----------------------------------------------------------------
    if DoiteGroup and DoiteGroup.ApplyGroupLayout then
        if frame._lastShowState ~= show then
            frame._lastShowState = show
            if type(DoiteAuras) == "table" and type(DoiteAuras.GetAllCandidates) == "function" then
                _G["DoiteGroup_NeedReflow"] = true
            end
        end
    end
end


function DoiteConditions_RequestEvaluate()
    dirty_ability, dirty_aura, dirty_target, dirty_power = true, true, true, true
end

function DoiteConditions:EvaluateAbilities()
    local source = (DoiteDB and DoiteDB.icons) or (DoiteAurasDB and DoiteAurasDB.spells)
    if not source then return end
    local key, data
    for key, data in pairs(source) do
        if data and data.type == "Ability" then
            local show, glow, grey = CheckAbilityConditions(data)
            DoiteConditions:ApplyVisuals(key, show, glow, grey)
        end
    end
end

function DoiteConditions:EvaluateAuras()
    local source = (DoiteDB and DoiteDB.icons) or (DoiteAurasDB and DoiteAurasDB.spells)
    if not source then return end
    local key, data
    for key, data in pairs(source) do
        if data and (data.type == "Buff" or data.type == "Debuff") then
            local show, glow, grey = CheckAuraConditions(data)
            DoiteConditions:ApplyVisuals(key, show, glow, grey)
        end
    end
end

local _tick = CreateFrame("Frame")
local _acc = 0
local _scanAccum = 0
local _textAccum = 0

_tick:SetScript("OnUpdate", function()
    local dt = arg1
    _acc = _acc + dt
    _scanAccum = _scanAccum + dt
	_textAccum = _textAccum + dt

    -- Refresh player & target auras every 0.2s
    if _scanAccum >= 0.2 then
        _scanAccum = 0

        -- player
        _ScanUnitAuras("player")
        dirty_aura = true

        -- target
        if UnitExists("target") then
            _ScanUnitAuras("target")
            dirty_aura = true
        end
    end
	
	-- Smooth remaining-time updates (abilities + auras) every 0.1s
    -- Keeps overlay text ticking smoothly even on long CDs outside slide.
    if _textAccum >= 0.1 then
        _textAccum = 0
        dirty_ability = true  -- ability rem text
        dirty_aura    = true  -- aura rem text
    end

    -- Render faster while sliding; else ~30fps
    local thresh = (next(SlideMgr.active) ~= nil) and 0.03 or 0.033
    if _acc < thresh then return end
    _acc = 0

	local needAbility = dirty_ability or dirty_power
	local needAura = dirty_aura or dirty_target
	if needAbility then DoiteConditions:EvaluateAbilities() end
	if needAura then DoiteConditions:EvaluateAuras() end
    if needAbility or needAura then
        dirty_aura, dirty_target, dirty_power = false, false, false
		dirty_ability = next(SlideMgr.active) and true or false
    end
end)

-- Prime aura snapshot and trigger initial evaluation
_ScanUnitAuras("player"); if UnitExists("target") then _ScanUnitAuras("target") end
dirty_ability, dirty_aura, dirty_target, dirty_power = true, true, true, true

---------------------------------------------------------------
-- Event handling + smoother updates
---------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("UNIT_MANA")
eventFrame:RegisterEvent("UNIT_ENERGY")
eventFrame:RegisterEvent("UNIT_RAGE")
eventFrame:RegisterEvent("ACTIONBAR_UPDATE_USABLE")
eventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:RegisterEvent("UNIT_HEALTH")
eventFrame:RegisterEvent("PLAYER_COMBO_POINTS")

eventFrame:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" then
        _ScanUnitAuras("player")
        if UnitExists("target") then _ScanUnitAuras("target") end
        dirty_ability, dirty_aura, dirty_target, dirty_power = true, true, true, true
    elseif event == "UNIT_AURA" then
		local now = GetTime()
		if (now - _lastAuraScanAt) > 0.05 then
			if arg1 == "player" then
				_ScanUnitAuras("player")
				dirty_ability = true
			elseif arg1 == "target" then
				_ScanUnitAuras("target")
			end
			dirty_aura = true
			_lastAuraScanAt = now
		end
	elseif event == "SPELLS_CHANGED" then
		for k in pairs(SpellIndexCache) do SpellIndexCache[k] = nil end
		dirty_ability = true
    elseif event == "PLAYER_TARGET_CHANGED" then
        if UnitExists("target") then
            _ScanUnitAuras("target")
        else
            local s = auraSnapshot.target
            if s then
                for k in pairs(s.buffs) do s.buffs[k] = nil end
                for k in pairs(s.debuffs) do s.debuffs[k] = nil end
            end
        end
        dirty_target, dirty_aura = true, true
        dirty_ability = true
    elseif event == "SPELL_UPDATE_COOLDOWN" then
        dirty_ability = true
    elseif event == "ACTIONBAR_UPDATE_USABLE" then
        dirty_ability = true
    elseif event == "UPDATE_SHAPESHIFT_FORM" then
        dirty_ability = true
    elseif event == "ACTIONBAR_UPDATE_COOLDOWN" then
        dirty_ability = true
	elseif event == "UNIT_HEALTH" then
        if arg1 == "player" or arg1 == "target" then
            dirty_ability = true
            dirty_aura    = true
        end
    elseif event == "PLAYER_COMBO_POINTS" then
        dirty_ability = true
        dirty_aura    = true
    elseif event == "UNIT_MANA" or event == "UNIT_RAGE" or event == "UNIT_ENERGY" then
        if arg1 == "player" then dirty_power = true end
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        dirty_ability, dirty_aura = true, true
    end
end)

---------------------------------------------------------------
-- End of DoiteConditions.lua
---------------------------------------------------------------
