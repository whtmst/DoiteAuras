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


local dirty_ability = false
local dirty_aura    = false
local dirty_target  = false
local dirty_power   = false

local DG = _G["DoiteGlow"]

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

    -- Build a quick lookup: auraName -> { list of keys that track this name }
    local trackedByName = {}
    if DoiteAurasDB and DoiteAurasDB.spells then
        for key, data in pairs(DoiteAurasDB.spells) do
            if data and (data.type == "Buff" or data.type == "Debuff") then
                local nm = data.displayName or data.name
                if nm and nm ~= "" then
                    if not trackedByName[nm] then trackedByName[nm] = {} end
                    table.insert(trackedByName[nm], { key = key, typ = data.type })
                end
            end
        end
    end

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

        -- If we track this aura, cache/use the real texture now (1.12-safe)
        local list = trackedByName[tn]
        if list then
			local tex = UnitBuff(unit, i)
			if tex and tn and IconCache[tn] ~= tex then
				IconCache[tn] = tex
				DoiteAurasDB.cache[tn] = tex
				if DoiteAurasDB.spells then
					for _, info in ipairs(list) do
						local s = DoiteAurasDB.spells[info.key]
						if s then s.iconTexture = tex end
					end
				end
				for _, info in ipairs(list) do
					local f = _G["DoiteIcon_" .. info.key]
					if f and f.icon and (f.icon:GetTexture() ~= tex) then
						f.icon:SetTexture(tex)
					end
				end
				-- don't set dirty_aura here; it's already set after the scan
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

        -- If we track this aura, cache/use the real texture now (1.12-safe)
        local list = trackedByName[tn]
        if list then
            local tex = UnitDebuff(unit, i)
			if tex and tn then
				IconCache[tn] = tex
				DoiteAurasDB.cache[tn] = tex
				if DoiteAurasDB.spells then
					for _, info in ipairs(list) do
						local s = DoiteAurasDB.spells[info.key]
						if s then s.iconTexture = tex end
					end
				end
				for _, info in ipairs(list) do
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
    -- mark DB dirty so SavedVariables flush includes cache
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
    local i = 1
    while i <= 200 do
        local s = GetSpellName(i, BOOKTYPE_SPELL)
        if not s then break end
        if s == spellName then
            return _AbilityRemainingSeconds(i, BOOKTYPE_SPELL)
        end
        i = i + 1
    end
    return nil
end

-- Cooldown (remaining, totalDuration) by spell name; nil,nil if not in book
local function _AbilityCooldownByName(spellName)
    if not spellName then return nil, nil end
    local i = 1
    while i <= 200 do
        local s = GetSpellName(i, BOOKTYPE_SPELL)
        if not s then break end
        if s == spellName then
            local start, dur = GetSpellCooldown(i, BOOKTYPE_SPELL)
            if start and dur and start > 0 and dur > 0 then
                local rem = (start + dur) - GetTime()
                if rem < 0 then rem = 0 end
                return rem, dur
            else
                -- not on cooldown
                return 0, dur or 0
            end
        end
        i = i + 1
    end
    return nil, nil
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
    local t = (st.endTime - now) / 3.0  -- remaining / 3s window
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

local function _PassesFormRequirement(formStr, auraSnap)
    if not formStr or formStr == "All" then return true end

    local _, cls = UnitClass("player")
    cls = cls and string.upper(cls) or ""
    local map = _ActiveFormMap()

    if cls == "WARRIOR" then
        if formStr == "1. Battle"    then return map["Battle Stance"]    == true end
        if formStr == "2. Defensive" then return map["Defensive Stance"] == true end
        if formStr == "3. Berserker" then return map["Berserker Stance"] == true end
        if formStr == "Multi: 1+2"   then return _AnyActive(map, {"Battle Stance","Defensive Stance"}) end
        if formStr == "Multi: 1+3"   then return _AnyActive(map, {"Battle Stance","Berserker Stance"}) end
        if formStr == "Multi: 2+3"   then return _AnyActive(map, {"Defensive Stance","Berserker Stance"}) end
        return true
    elseif cls == "ROGUE" then
        if formStr == "1. Stealth"     then return map["Stealth"] == true end
        if formStr == "0. No Stealth"  then return map["Stealth"] ~= true end
        return true
    elseif cls == "PRIEST" then
        if formStr == "1. Shadowform"  then return map["Shadowform"] == true end
        if formStr == "0. No form"     then return map["Shadowform"] ~= true end
        return true
    elseif cls == "DRUID" then
        if formStr == "0. No form"     then return _DruidNoForm(map) end
        if formStr == "1. Bear"        then return _AnyActive(map, {"Dire Bear Form","Bear Form"}) end
        if formStr == "2. Aquatic"     then return map["Aquatic Form"] == true end
        if formStr == "3. Cat"         then return map["Cat Form"] == true end
        if formStr == "4. Travel"      then return _AnyActive(map, {"Travel Form","Swift Travel Form"}) end
        if formStr == "5. Moonkin"     then return map["Moonkin Form"] == true end
        if formStr == "6. Tree"        then return map["Tree of Life Form"] == true end
        if formStr == "7. Stealth"     then return _DruidStealth(auraSnap) end
        if formStr == "8. No Stealth"  then return not _DruidStealth(auraSnap) end

        -- Multis
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

    return true
end

local function _EnsureAbilityTexture(frame, data)
    if not frame or not frame.icon or not data then return end
    if frame.icon:GetTexture() then return end

    local spellName = data.displayName or data.name
    if not spellName then return end

    local bookType = BOOKTYPE_SPELL
    local i = 1
    while i <= 200 do
        local s = GetSpellName(i, bookType)
        if not s then break end
        if s == spellName then
            local tex = GetSpellTexture(i, bookType)
            if tex then
                frame.icon:SetTexture(tex)
                IconCache[spellName] = tex -- cache the spellbook texture too (so it persists)
            end
            break
        end
        i = i + 1
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
    local spellIndex
    local bookType = BOOKTYPE_SPELL
    local foundInBook = false
    for i = 1, 200 do
        local name = GetSpellName(i, bookType)
        if not name then break end
        if name == spellName then
            spellIndex = i
            foundInBook = true
            break
        end
    end

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
	local allowHelp = (c.targetHelp == true)  -- default false
	local allowHarm = (c.targetHarm == true)  -- default false
	local allowSelf = (c.targetSelf == true)  -- default false

	local ok = true
	if allowHelp or allowHarm or allowSelf then
		ok = false
		if allowSelf and UnitExists("target") and UnitIsUnit("player","target") then
			ok = true
		end
		if (not ok) and allowHelp and UnitExists("target") and UnitIsFriend("player","target")
		   and (not UnitIsUnit("player","target")) then
			ok = true
		end
		if (not ok) and allowHarm and UnitExists("target") and UnitCanAttack("player","target")
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

    -- Self is exclusive with Help/Harm
    if allowSelf then
        allowHelp, allowHarm = false, false
    end

    -- If all three somehow false, default to Self
    if (not allowHelp) and (not allowHarm) and (not allowSelf) then
        allowSelf = true
    end

    local found = false

    -- Self auras — aura on player, regardless of target
    if (not found) and allowSelf then
        local s = auraSnapshot.player
        if s and ((wantBuff and s.buffs[name]) or (wantDebuff and s.debuffs[name])) then
            found = true
        else
            -- light live probe if snapshot missed it
            local i = 1; local hit = false
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
            if hit then
                found = true
            end
        end
    end

    -- Target (help) auras — friendly target (player counts as friendly too)
    if (not found)
       and allowHelp
       and UnitExists("target")
       and UnitIsFriend("player","target") then
        local s = auraSnapshot.target
        if s and ((wantBuff and s.buffs[name]) or (wantDebuff and s.debuffs[name])) then
            found = true
        end
    end

    -- Target (harm) auras — hostile target
    if (not found)
       and allowHarm
       and UnitExists("target")
       and UnitCanAttack("player","target")
       and (not UnitIsFriend("player","target")) then
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

    -- load textures only when showing
    if show then
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
        if ca.slider and (ca.mode == "usable" or ca.mode == "notcd") then
            local spellName = dataTbl.displayName or dataTbl.name
            local rem, dur = _AbilityCooldownByName(spellName)
            -- Only slide in last 3s of a real CD (dur > 1.6 to skip GCD)
            if rem and dur and dur > 1.6 and rem > 0 and rem <= 3.0 then
                local baseX, baseY = 0, 0
                if _GetBaseXY then baseX, baseY = _GetBaseXY(key, dataTbl) end
                SlideMgr:StartOrUpdate(key, (ca.sliderDir or "center"), baseX, baseY, GetTime() + rem)
            else
                SlideMgr:Stop(key)
            end
        else
            SlideMgr:Stop(key)
        end
    else
        SlideMgr:Stop(key)
    end

    -- Pull the current slide offset/alpha (if sliding)
    do
        local active, sdx, sdy, a, sg, sg2 = SlideMgr:Get(key)
        slideActive, dx, dy, slideAlpha, supGlow, supGrey = active, sdx, sdy, a, sg, sg2
    end

    -- Determine baseline anchoring
    local baseX, baseY = 0, 0
    if _GetBaseXY and dataTbl then baseX, baseY = _GetBaseXY(key, dataTbl) end
    if slideActive then SlideMgr:UpdateBase(key, baseX, baseY) end

    -- Show during slide preview even if main conditions would hide
    local showForSlide = show or slideActive

    -- Apply position and alpha (no stutter: we set exact coordinates each paint)
    do
        frame:ClearAllPoints()
        if slideActive then
            frame:SetPoint("CENTER", UIParent, "CENTER", baseX + dx, baseY + dy)
            frame:SetAlpha(slideAlpha)
        else
            frame:SetPoint("CENTER", UIParent, "CENTER", baseX, baseY)
            frame:SetAlpha((dataTbl and dataTbl.alpha) or 1)
        end
    end

    if showForSlide then frame:Show() else frame:Hide() end

    -- Greyscale (suppressed while sliding)
    if frame.icon then
        if (grey and (not supGrey)) then frame.icon:SetDesaturated(1) else frame.icon:SetDesaturated(nil) end
    end

    -- Glow (suppressed while sliding; fully restored after)
    if DG then
        if showForSlide and glow and (not supGlow) then DG.Start(frame) else DG.Stop(frame) end
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
-- place near your other locals
local _scanAccum = 0

_tick:SetScript("OnUpdate", function()
    local dt = arg1
    _acc = _acc + dt
    _scanAccum = _scanAccum + dt

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

	-- Render faster while sliding (feels smooth), default to ~30fps otherwise
	local thresh = (next(SlideMgr.active) ~= nil) and 0.016 or 0.033
	if _acc < thresh then return end
	_acc = 0

    local needAbility = dirty_ability or dirty_power
    local needAura    = dirty_aura or dirty_target
    if needAbility then DoiteConditions:EvaluateAbilities() end
    if needAura then DoiteConditions:EvaluateAuras() end
    if needAbility or needAura then
        dirty_ability, dirty_aura, dirty_target, dirty_power = false, false, false, false
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

eventFrame:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" then
        _ScanUnitAuras("player")
        if UnitExists("target") then _ScanUnitAuras("target") end
        dirty_ability, dirty_aura, dirty_target, dirty_power = true, true, true, true
    elseif event == "UNIT_AURA" then
        if arg1 == "player" then
            _ScanUnitAuras("player")
            dirty_ability = true
        elseif arg1 == "target" then
            _ScanUnitAuras("target")
        end
        dirty_aura = true
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
    elseif event == "UNIT_MANA" or event == "UNIT_RAGE" or event == "UNIT_ENERGY" then
        if arg1 == "player" then dirty_power = true end
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        dirty_ability, dirty_aura = true, true
    end
end)

---------------------------------------------------------------
-- End of DoiteConditions.lua
---------------------------------------------------------------
