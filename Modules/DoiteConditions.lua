---------------------------------------------------------------
-- DoiteConditions.lua
-- Evaluates ability and aura conditions to show/hide/update icons
-- WoW 1.12 | Lua 5.0
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
local UnitClass     = UnitClass
local UnitName      = UnitName
local UnitHealth    = UnitHealth
local UnitHealthMax = UnitHealthMax
local UnitMana      = UnitMana
local UnitManaMax   = UnitManaMax
local GetComboPoints = GetComboPoints

local str_find  = string.find
local str_match = string.match
local str_gsub  = string.gsub

-- Spell index cache (must be defined before any usage)
local SpellIndexCache = {}
_G.DoiteConditions_SpellIndexCache = SpellIndexCache

_isWarrior = false

local function _GetSpellIndexByName(spellName)
    if not spellName then return nil end

    local cached = SpellIndexCache[spellName]
    if cached ~= nil then
        return (cached ~= false) and cached or nil
    end

    -- Nampower fast path - GetSpellSlotTypeIdForName(spellName)
    if GetSpellSlotTypeIdForName then
        local slot, bookType = GetSpellSlotTypeIdForName(spellName)
        if slot and slot > 0 and bookType == "spell" then
            SpellIndexCache[spellName] = slot
            return slot
        end
    end

    -- Vanilla scan fallback
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


-- Dirty flags used by the central update loop (kept global so they're not upvalues)
dirty_ability      = false
dirty_aura         = false
dirty_target       = false
dirty_power        = false
dirty_ability_time = false

local DG = _G["DoiteGlow"]
local function _IsKeyUnderEdit(k)
    if not k then return false end
    local cur = _G["DoiteEdit_CurrentKey"]
    if not cur or cur ~= k then return false end
    local f = _G["DoiteEdit_Frame"] or _G["DoiteEditMain"] or _G["DoiteEdit"]
    if f and f.IsShown then
        return f:IsShown() == 1
    end
    return true
end

local function _IsAnyKeyUnderEdit()
    local cur = _G["DoiteEdit_CurrentKey"]
    if not cur then return false end
    local f = _G["DoiteEdit_Frame"] or _G["DoiteEditMain"] or _G["DoiteEdit"]
    if f and f.IsShown then
        return f:IsShown() == 1
    end
    return false
end

local function _MaybeResolveSpellIdForEntry(key, data)
    if not data or type(data) ~= "table" then return end

    -- Only touch entries that look like the temporary "Spell ID: ###" displayName
    local dn = data.displayName
    if not dn or dn == "" then return end
    if not str_find(dn, "^Spell ID") then
        return
    end

    local sidStr = data.spellid
    if not sidStr or sidStr == "" then return end
    local sid = tonumber(sidStr)
    if not sid or sid <= 0 then return end

    local name, tex

    -- SuperWoW: SpellInfo(spellId) -> name, rank, texture, ...
    if SpellInfo then
        local n, _, t = SpellInfo(sid)
        if type(n) == "string" and n ~= "" then
            name = n
        end
        if type(t) == "string" and t ~= "" then
            tex = t
        end
    end

    -- Nampower fallback: GetSpellNameAndRankForId(spellId)
    if (not name) and GetSpellNameAndRankForId then
        local n, rank = GetSpellNameAndRankForId(sid)
        if type(n) == "string" and n ~= "" then
            name = n
        end
    end

    -- If still don’t have a real name, bail out without changing anything
    if not name or name == "" then
        return
    end

    ------------------------------------------------------------
    -- Commit to DB: real name + optional texture
    ------------------------------------------------------------
    data.displayName = name
    if not data.name or data.name == "" then
        data.name = name
    end

    if tex and tex ~= "" then
        data.iconTexture = tex

        if IconCache then
            IconCache[name] = tex
        end
        if DoiteAurasDB and DoiteAurasDB.cache then
            DoiteAurasDB.cache[name] = tex
        end

        -- Update live icon frame if it exists
        if key then
            local f = _G["DoiteIcon_" .. key]
            if f and f.icon and f.icon.SetTexture then
                local cur = f.icon:GetTexture()
                if cur ~= tex then
                    f.icon:SetTexture(tex)
                end
            end
        end
    end
end


local _trackedByName, _trackedBuiltAt = nil, 0
local function _GetTrackedByName()
    local now = GetTime()
    if _trackedByName and (now - _trackedBuiltAt) < 5.0 then
        return _trackedByName
    end

    local t = _trackedByName
    if not t then
        t = {}
    else
        local k, lst
        for k, lst in pairs(t) do
            if type(lst) == "table" then
                local j
                for j in pairs(lst) do
                    lst[j] = nil
                end
            end
            t[k] = nil
        end
    end

    if DoiteAurasDB and DoiteAurasDB.spells then
        local key, data
        for key, data in pairs(DoiteAurasDB.spells) do
            if data and (data.type == "Buff" or data.type == "Debuff") then
                -- If this aura was added via spellid with a temporary "Spell ID: ###"
                -- name, resolve it once here using SuperWoW / Nampower.
                _MaybeResolveSpellIdForEntry(key, data)

                local nm = data.displayName or data.name
                if nm and nm ~= "" then
                    local lst = t[nm]
                    if not lst then
                        lst = {}
                        t[nm] = lst
                    end
                    table.insert(lst, key)
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

local auraSnapshot = {
    player = { buffs = {}, debuffs = {}, buffIds = {}, debuffIds = {} },
    target = { buffs = {}, debuffs = {}, buffIds = {}, debuffIds = {} },
}

_G.DoiteConditions_AuraSnapshot = auraSnapshot
-- Per-name remaining-time cache for player auras (rebuilt on UNIT_AURA "player")
local PlayerAuraTimers = { buffs = {}, debuffs = {} }
_G.DoiteConditions_PlayerAuraTimers = PlayerAuraTimers

-- Create hidden tooltip once; don't re-SetOwner every scan
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

-- SuperWoW: UnitBuff/UnitDebuff return auraId, SpellInfo(auraId) gives name/texture.
local function _GetAuraName(unit, index, isDebuff)
    if not unit or not index or index < 1 then return nil end

    local tex, auraId
    if isDebuff then
        -- SuperWoW: texture, stacks, dtype, spellID
        tex, _, _, auraId = UnitDebuff(unit, index)
    else
        -- SuperWoW: texture, stacks, spellID
        tex, _, auraId = UnitBuff(unit, index)
    end
    if not tex then
        -- No aura at this index: real end-of-list marker
        return nil
    end

    local name

    -- SuperWoW path: auraId -> SpellInfo(id) -> name
    if auraId and SpellInfo then
        local n = SpellInfo(auraId)
        if type(n) == "string" and n ~= "" then
            name = n
        end
    end

    -- Fallback: tooltip name (vanilla / weird auras / bad IDs)
    if not name then
        _EnsureTooltip()
        DoiteConditionsTooltip:ClearLines()

        if isDebuff then
            if DoiteConditionsTooltip.SetUnitDebuff then
                DoiteConditionsTooltip:SetUnitDebuff(unit, index)
            elseif DoiteConditionsTooltip.SetUnitBuff then
                DoiteConditionsTooltip:SetUnitBuff(unit, index, "HARMFUL")
            end
        else
            if DoiteConditionsTooltip.SetUnitBuff then
                DoiteConditionsTooltip:SetUnitBuff(unit, index, "HELPFUL")
            end
        end

        local fs = _G["DoiteConditionsTooltipTextLeft1"]
        if fs and fs.GetText then
            local t = fs:GetText()
            if t and t ~= "" then
                name = t
            end
        end
    end

    -- return a non-nil sentinel so callers don't think the list ended.
    if not name then
        return ""
    end

    return name
end

local function _ScanUnitAuras(unit)
    -- Use cached lookup: auraName -> { list of keys that track this name }
    local trackedByName = _GetTrackedByName()

	local snap = auraSnapshot[unit]
	if not snap then return end
	local buffs,   debuffs   = snap.buffs,   snap.debuffs
	local buffIds, debuffIds = snap.buffIds, snap.debuffIds
	if not buffs or not debuffs then return end

	-- Clear previous snapshot
	for k in pairs(buffs)     do buffs[k]     = nil end
	for k in pairs(debuffs)   do debuffs[k]   = nil end
	if buffIds then
		for k in pairs(buffIds)   do buffIds[k]   = nil end
	end
	if debuffIds then
		for k in pairs(debuffIds) do debuffIds[k] = nil end
	end

    local cache = IconCache

    ----------------------------------------------------------------
    -- BUFFS
    ----------------------------------------------------------------
    local i = 1
	while true do
		-- SuperWoW: texture, stacks, spellID
		local tex, _, auraId = UnitBuff(unit, i)
		if not tex then
			break
		end

		local name
		if auraId and SpellInfo then
			name = SpellInfo(auraId)
		end

		if type(name) == "string" and name ~= "" then
			buffs[name] = true
			if buffIds and auraId then
				buffIds[auraId] = true
			end

			local list = trackedByName and trackedByName[name]
			if list and type(list) == "table" then
				if cache[name] ~= tex then
					cache[name] = tex
					DoiteAurasDB.cache[name] = tex

					local count = table.getn(list)
					for j = 1, count do
						local key = list[j]
						if key and DoiteAurasDB.spells then
							local s = DoiteAurasDB.spells[key]
							if s then
								-- 1) Update DB spell icon
								s.iconTexture = tex

								-- 1b) Auto-fill spellid if it's missing
								if auraId and not s.spellid then
									s.spellid = tostring(auraId)
								end

								-- 1c) Backfill displayName if missing in config
								if (not s.displayName or s.displayName == "") then
									s.displayName = name
								end
							end
						end

						-- 2) Update live icon frame texture
						local f = _G["DoiteIcon_" .. key]
						if f and f.icon and f.icon:GetTexture() ~= tex then
							f.icon:SetTexture(tex)
						end
					end
				end
			end
		end

		i = i + 1
	end

    ----------------------------------------------------------------
    -- DEBUFFS
    ----------------------------------------------------------------
	i = 1
	while true do
		-- SuperWoW: texture, stacks, dtype, spellID
		local tex, _, _, auraId = UnitDebuff(unit, i)
		if not tex then
			break
		end

		local name
		if auraId and SpellInfo then
			name = SpellInfo(auraId)
		end

		if type(name) == "string" and name ~= "" then
			debuffs[name] = true
			if debuffIds and auraId then
				debuffIds[auraId] = true
			end

			local list = trackedByName and trackedByName[name]
			if list and type(list) == "table" then
				if cache[name] ~= tex then
					cache[name] = tex
					DoiteAurasDB.cache[name] = tex

					local count = table.getn(list)
					for j = 1, count do
						local key = list[j]
						if key and DoiteAurasDB.spells then
							local s = DoiteAurasDB.spells[key]
							if s then
								-- 1) Update DB spell icon
								s.iconTexture = tex

								-- 1b) Auto-fill spellid if it's missing
								if auraId and not s.spellid then
									s.spellid = tostring(auraId)
								end

								-- 1c) Backfill displayName if missing
								if (not s.displayName or s.displayName == "") then
									s.displayName = name
								end
							end
						end

						-- 2) Update live icon frame texture
						local f = _G["DoiteIcon_" .. key]
						if f and f.icon and f.icon:GetTexture() ~= tex then
							f.icon:SetTexture(tex)
						end
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

-- Global alias so update loop can call it without capturing the loc
_G.DoiteConditions_ScanUnitAuras = _ScanUnitAuras

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

-- Nampower-accelerated cache: spellName -> spellId (max rank)
local SpellUsableIdCache = {}

-- NamPower-safe wrapper around IsSpellUsable.
local function _SafeSpellUsable(spellNameBase, spellIndex, bookType)
    if not IsSpellUsable or not spellNameBase then
        return 1, 0
    end

    ----------------------------------------------------------------
    -- 1) Fast path: Nampower present -> spellId + IsSpellUsable(id)
    ----------------------------------------------------------------
    if GetSpellIdForName then
        local sid = SpellUsableIdCache[spellNameBase]

        if sid == nil then
            sid = GetSpellIdForName(spellNameBase)
            SpellUsableIdCache[spellNameBase] = sid or false
        end

        if sid and sid ~= 0 then
            local ok, u, noMana = pcall(IsSpellUsable, sid)
            if ok and u ~= nil then
                return u, noMana
            end
        end
        -- fall through to legacy if no valid id / pcall fail
    end

    ----------------------------------------------------------------
    -- 2) Legacy fallback: old string-based behaviour (rarely used)
    ----------------------------------------------------------------
    local bt  = bookType or BOOKTYPE_SPELL
    local arg = spellNameBase

    if GetSpellName and spellIndex then
        -- Only build the rank string once per *spellIndex*
        local idxForRank = spellIndex
        local i = spellIndex + 1
        while i <= 200 do
            local n = GetSpellName(i, bt)
            if not n or n ~= spellNameBase then
                break
            end
            idxForRank = i
            i = i + 1
        end

        local n, r = GetSpellName(idxForRank, bt)
        if n and r and r ~= "" then
            arg = n .. "(" .. r .. ")"
        end
    end

    -- 2a) Preferred legacy call
    local ok, u, noMana = pcall(IsSpellUsable, arg)
    if ok and u ~= nil then
        return u, noMana
    end

    -- 2b) Last resort: plain name (old behaviour)
    ok, u, noMana = pcall(IsSpellUsable, spellNameBase)
    if ok and u ~= nil then
        return u, noMana
    end

    -- 3) Ultimate fallback: treat as usable so icon doesn’t die forever
    return 1, 0
end

-- === Item helpers (inventory / bag lookup & cooldown) =======================
local INV_SLOT_TRINKET1 = 13
local INV_SLOT_TRINKET2 = 14
local INV_SLOT_MAINHAND = 16
local INV_SLOT_OFFHAND  = 17
local INV_SLOT_RANGED   = 18

local function _SlotIndexForName(name)
    if name == "TRINKET1"      then return INV_SLOT_TRINKET1 end
    if name == "TRINKET2"      then return INV_SLOT_TRINKET2 end
    if name == "MAINHAND"      then return INV_SLOT_MAINHAND end
    if name == "OFFHAND"       then return INV_SLOT_OFFHAND end
    if name == "RANGED"        then return INV_SLOT_RANGED end
    return nil
end

-- Per-key memory for TRINKET_FIRST: "first ready wins" and stays the winner
local _TrinketFirstMemory = {}

local function _ClearTrinketFirstMemory()
    for k in pairs(_TrinketFirstMemory) do
        _TrinketFirstMemory[k] = nil
    end
end
_G.DoiteConditions_ClearTrinketFirstMemory = _ClearTrinketFirstMemory


-- Parse itemID and [Name] out of a WoW item link
local function _ParseItemLink(link)
    if not link then return nil, nil end
    local itemId = tonumber(str_match(link, "item:(%d+)"))
    local name   = str_match(link, "%[(.+)%]")
    return itemId, name
end

-- Scan player inventory + bags for the configured item
-- Returns: hasEquipped, hasBag, firstEquippedSlot, firstBagLocTableOrNil
local function _ScanPlayerItemInstances(data)
    if not data then return false, false, nil, nil end

    local expectedId   = data.itemId or data.itemID
    if expectedId then expectedId = tonumber(expectedId) end
    local expectedName = data.itemName or data.displayName or data.name

    local hasEquipped, hasBag = false, false
    local firstEquippedSlot   = nil
    local firstBagLoc         = nil

    -- Equipped slots (1..19 is enough; trinkets/weapons are in here)
    local slot = 1
    while slot <= 19 do
        local link = GetInventoryItemLink("player", slot)
        if link then
            local id, name = _ParseItemLink(link)
            local match = false
            if expectedId and id then
                match = (id == expectedId)
            elseif expectedName and name then
                match = (name == expectedName)
            end
            if match then
                hasEquipped = true
                if not firstEquippedSlot then
                    firstEquippedSlot = slot
                end
            end
        end
        slot = slot + 1
    end

    -- Bags 0..4
    local bag = 0
    while bag <= 4 do
        local numSlots = GetContainerNumSlots and GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            local bslot = 1
            while bslot <= numSlots do
                local link = GetContainerItemLink(bag, bslot)
                if link then
                    local id, name = _ParseItemLink(link)
                    local match = false
                    if expectedId and id then
                        match = (id == expectedId)
                    elseif expectedName and name then
                        match = (name == expectedName)
                    end
                    if match then
                        hasBag = true
                        if not firstBagLoc then
                            firstBagLoc = { bag = bag, slot = bslot }
                        end
                    end
                end
                bslot = bslot + 1
            end
        end
        bag = bag + 1
    end

    return hasEquipped, hasBag, firstEquippedSlot, firstBagLoc
end

-- Single inventory slot: does it have an item and is that item on cooldown?
-- Returns: hasItem, onCooldown, rem, dur, isUseItem
local function _GetInventorySlotState(slot)
    if not slot then return false, false, 0, 0, false end
    local link = GetInventoryItemLink("player", slot)
    if not link then return false, false, 0, 0, false end

    local start, dur, enable = GetInventoryItemCooldown("player", slot)
    local rem, onCd = 0, false
    if start and dur and start > 0 and dur > 1.5 then
        rem = (start + dur) - GetTime()
        if rem < 0 then rem = 0 end
        onCd = (rem > 0)
    else
        dur = dur or 0
    end

    -- Detect usable / "Use:"-style items via tooltip text.
    _EnsureTooltip()
    DoiteConditionsTooltip:ClearLines()
    DoiteConditionsTooltip:SetInventoryItem("player", slot)

    local isUse = false
    local i = 1
    while i <= 15 do
        local fs = _G["DoiteConditionsTooltipTextLeft" .. i]
        if not fs or not fs.GetText then break end
        local txt = fs:GetText()
        if txt then
            local lower = string.lower(txt)
            if str_find(lower, "use:") or str_find(lower, "use ")
               or str_find(lower, "consume") then
                isUse = true
                break
            end
        end
        i = i + 1
    end

    return true, onCd, rem, dur or 0, isUse
end

-- Core item state used by both condition checks and text overlays
local _ItemStateScratch = {
    hasItem     = false,
    isMissing   = false,
    passesWhere = true,
    modeMatches = true,
    rem         = nil,
    dur         = nil,
}

local function _ResetItemState(state)
    state.hasItem     = false
    state.isMissing   = false
    state.passesWhere = true
    state.modeMatches = true
    state.rem         = nil
    state.dur         = nil
end

local function _EvaluateItemCoreState(data, c)
    local state = _ItemStateScratch
    _ResetItemState(state)

    if not data or not c then
        return state
    end

    local invSlotName = c.inventorySlot

    -- --------------------------------------------------------------------
    -- 1) Synthetic inventory-slot entries (equipped trinkets / weapons)
    -- --------------------------------------------------------------------
    if invSlotName and invSlotName ~= "" then
        local mode = c.mode or ""
        local key  = data and data.key

        -- Direct 1:1 slot bindings (TRINKET1 / TRINKET2 / MAINHAND / OFFHAND / RANGED)
        if invSlotName == "TRINKET1" or invSlotName == "TRINKET2"
           or invSlotName == "MAINHAND" or invSlotName == "OFFHAND"
           or invSlotName == "RANGED" then

            local idx = _SlotIndexForName(invSlotName)
            local hasItem, onCd, rem, dur = _GetInventorySlotState(idx)
            state.hasItem   = hasItem
            state.isMissing = not hasItem
            state.rem       = rem
            state.dur       = dur

            if mode == "oncd" then
                state.modeMatches = (hasItem and onCd)
            elseif mode == "notcd" then
                state.modeMatches = (hasItem and (not onCd))
            else
                state.modeMatches = true
            end

        -- Composite “equipped trinkets” synthetic entries
        elseif invSlotName == "TRINKET_FIRST" or invSlotName == "TRINKET_BOTH" then
            local has1, on1, rem1, dur1, isUse1 = _GetInventorySlotState(INV_SLOT_TRINKET1)
            local has2, on2, rem2, dur2, isUse2 = _GetInventorySlotState(INV_SLOT_TRINKET2)

            local use1 = has1 and isUse1
            local use2 = has2 and isUse2

            -- If none are usable / have a use-effect, never show
            if not use1 and not use2 then
                state.hasItem     = false
                state.isMissing   = true
                state.modeMatches = false
                state.passesWhere = true
                return state
            end

            state.hasItem   = (use1 or use2)
            state.isMissing = not state.hasItem

            if invSlotName == "TRINKET_FIRST" then
                -- “First ready” semantics with memory per key:
                local prevSlot = key
                                  and _TrinketFirstMemory[key]
                                  and _TrinketFirstMemory[key].slot
                                  or nil
                local winner = prevSlot

                if mode == "notcd" then
                    -- A slot is “ready” if it is a usable trinket and not on cooldown.
                    local function slotReady(useFlag, onCdFlag)
                        return useFlag and (not onCdFlag)
                    end

                    -- Drop previous winner if it stopped being ready/usable.
                    if winner == INV_SLOT_TRINKET1
                       and not slotReady(use1, on1) then
                        winner = nil
                    elseif winner == INV_SLOT_TRINKET2
                       and not slotReady(use2, on2) then
                        winner = nil
                    end

                    if not winner then
                        if slotReady(use1, on1) then
                            winner = INV_SLOT_TRINKET1
                        elseif slotReady(use2, on2) then
                            winner = INV_SLOT_TRINKET2
                        end
                    end

                    if winner == INV_SLOT_TRINKET1 then
                        state.modeMatches = slotReady(use1, on1)
                        state.rem = rem1
                        state.dur = dur1
                    elseif winner == INV_SLOT_TRINKET2 then
                        state.modeMatches = slotReady(use2, on2)
                        state.rem = rem2
                        state.dur = dur2
                    else
                        state.modeMatches = false
                    end

                    if key then
                        if winner then
                            _TrinketFirstMemory[key] = _TrinketFirstMemory[key] or {}
                            _TrinketFirstMemory[key].slot = winner
                        else
                            _TrinketFirstMemory[key] = nil
                        end
                    end

                elseif mode == "oncd" then
                    -- On-CD mode: any usable trinket on cooldown passes; pick the one
                    local found, bestRem, bestDur = false, nil, nil

                    if use1 and on1 then
                        found   = true
                        bestRem = rem1
                        bestDur = dur1
                        winner  = INV_SLOT_TRINKET1
                    end
                    if use2 and on2 then
                        if (not found) or (rem2 < bestRem) then
                            found   = true
                            bestRem = rem2
                            bestDur = dur2
                            winner  = INV_SLOT_TRINKET2
                        end
                    end

                    state.modeMatches = found
                    state.rem = bestRem
                    state.dur = bestDur

                    if key then
                        if winner then
                            _TrinketFirstMemory[key] = _TrinketFirstMemory[key] or {}
                            _TrinketFirstMemory[key].slot = winner
                        else
                            _TrinketFirstMemory[key] = nil
                        end
                    end
                else
                    -- No explicit mode: just report presence of any usable trinket.
                    state.modeMatches = (use1 or use2)
                    state.rem = nil
                    state.dur = nil
                end

            else
                -- TRINKET_BOTH:
                -- Require all equipped use-trinkets to be in the requested state.
                if mode == "oncd" then
                    local ok = true
                    if use1 and not on1 then ok = false end
                    if use2 and not on2 then ok = false end
                    state.modeMatches = ok
                    if ok then
                        local r1 = (use1 and rem1) or 0
                        local r2 = (use2 and rem2) or 0
                        state.rem = (r1 > r2) and r1 or r2
                        state.dur = dur1 or dur2
                    end
                elseif mode == "notcd" then
                    local ok = true
                    if use1 and on1 then ok = false end
                    if use2 and on2 then ok = false end
                    state.modeMatches = ok
                    if ok then
                        state.rem = 0
                        state.dur = dur1 or dur2
                    end
                else
                    state.modeMatches = true
                end
            end
        end

        -- No Whereabouts for synthetic entries; treat as pass
        state.passesWhere = true
        return state
    end

    -- --------------------------------------------------------------------
    -- 2) Normal items (Whereabouts: equipped / bag / missing)
    -- --------------------------------------------------------------------
    local hasEquipped, hasBag, eqSlot, bagLoc = _ScanPlayerItemInstances(data)
    local missing = (not hasEquipped and not hasBag)

    state.hasItem   = not missing
    state.isMissing = missing

    local passWhere = false
    if c.whereEquipped and hasEquipped then passWhere = true end
    if c.whereBag      and hasBag      then passWhere = true end
    if c.whereMissing  and missing     then passWhere = true end
    state.passesWhere = passWhere

    -- If the editor forced at least one Whereabouts
    if not passWhere then
        return state
    end

    -- prefer equipped if present, otherwise first bag occurrence
    local kind, loc = nil, nil
    if eqSlot then
        kind = "inv"
        loc  = eqSlot
    elseif bagLoc then
        kind = "bag"
        loc  = bagLoc
    end

    if kind and loc then
        local hasItem, onCd, rem, dur
        if kind == "inv" then
            local link = GetInventoryItemLink("player", loc)
            hasItem = (link ~= nil)
            local start, dur0, enable = GetInventoryItemCooldown("player", loc)
            if start and dur0 and start > 0 and dur0 > 1.5 then
                rem = (start + dur0) - GetTime()
                if rem < 0 then rem = 0 end
                onCd = (rem > 0)
                dur  = dur0
            else
                onCd = false
                rem  = 0
                dur  = dur0 or 0
            end
        else
            local link = GetContainerItemLink(loc.bag, loc.slot)
            hasItem = (link ~= nil)
            local start, dur0, enable = GetContainerItemCooldown(loc.bag, loc.slot)
            if start and dur0 and start > 0 and dur0 > 1.5 then
                rem = (start + dur0) - GetTime()
                if rem < 0 then rem = 0 end
                onCd = (rem > 0)
                dur  = dur0
            else
                onCd = false
                rem  = 0
                dur  = dur0 or 0
            end
        end

        if not state.hasItem and hasItem then
            state.hasItem   = true
            state.isMissing = false
        end

        state.rem = rem
        state.dur = dur

        local mode = c.mode or ""
        if mode == "oncd" then
            state.modeMatches = (hasItem and onCd)
        elseif mode == "notcd" then
            state.modeMatches = (hasItem and (not onCd))
        else
            state.modeMatches = true
        end
    else
        -- No instance at all (no eqSlot/bagLoc)
        local mode = c.mode or ""
        if mode == "oncd" or mode == "notcd" then
            state.modeMatches = false
        end
    end

    return state
end

-- =================================================================
-- Lightweight Combat Log Watcher
-- =================================================================

-- For slider gating: which spells have we actually seen cast?
_G["Doite_SliderSeen"] = _G["Doite_SliderSeen"] or {}
local _SliderSeen = _G["Doite_SliderSeen"]

local function _MarkSliderSeen(spellName)
    if not spellName or spellName == "" then return end
    _SliderSeen[spellName] = GetTime() or 0
end

local _OP_until, _OP_target = 0, nil
local _REV_until            = 0

local function _Now() return GetTime() or 0 end

-- Canonical ability name resolver (spellbook name preferred)
local function _GetCanonicalSpellNameFromData(data)
    if not data or type(data) ~= "table" then return nil end
    if data.name and data.name ~= "" then
        -- This is the canonical spellbook name (what GetSpellName sees)
        return data.name
    end
    if data.displayName and data.displayName ~= "" then
        return data.displayName
    end
    return nil
end

-- =================================================================
-- SuperWoW: UNIT_CASTEVENT -> last used spell + cooldown ownership
-- =================================================================
local _playerGUID_cached = nil
local _GetUnitGuid -- forward declaration so _GetPlayerGUID sees the local

local function _GetPlayerGUID()
    if _playerGUID_cached then
        return _playerGUID_cached
    end

    local guid = _GetUnitGuid and _GetUnitGuid("player") or nil
    if guid and guid ~= "" then
        _playerGUID_cached = guid
        return guid
    end
    return nil
end

local _daCast = CreateFrame("Frame")
_daCast:RegisterEvent("UNIT_CASTEVENT")
_daCast:SetScript("OnEvent", function()
    local casterGUID = arg1
    local targetGUID = arg2
    local evType     = arg3
    local spellId    = arg4
    local duration   = arg5

    local pGUID = _GetPlayerGUID()
    if not pGUID or casterGUID ~= pGUID then
        return
    end

    -- Only care about completed casts / swings for "last used spell".
    if evType ~= "CAST" and evType ~= "MAINHAND" and evType ~= "OFFHAND" then
        return
    end

    if not spellId or not SpellInfo then
        return
    end

    local name = SpellInfo(spellId)
    if type(name) ~= "string" or name == "" then
        return
    end

    local now = _Now() or 0

    -- Slider gating: only allow sliders for spells actually seen cast.
    if evType == "CAST" then
        _MarkSliderSeen(name)
    end
end)

local function _CL_Parse(msg)
    -- Warrior-only reactive proc parsing (Overpower / Revenge)
    if _isWarrior then
        do
            local tgt =
                str_match(msg, "You attack%.%s+(.+)%s+dodges")
                or str_match(msg, "Your%s+.+%s+was%s+dodged%s+by%s+(.+)")
            if tgt then
                _OP_target = tgt
                _OP_until  = _Now() + 4.0
                dirty_ability = true
            end
        end

        -- Revenge proc: you dodge/parry/block or take a partially blocked hit
        if str_find(msg, "You dodge")
           or str_find(msg, "You parry")
           or str_find(msg, "You block")
           or ((str_find(msg, " hits you for ") or str_find(msg, " crits you for "))
               and str_find(msg, " blocked)")) then
            _REV_until = _Now() + 4.0
            dirty_ability = true
        end
    end
end

-- SuperWoW: RAW_COMBATLOG gives the original event name + raw text
local _daRawCL = CreateFrame("Frame")

-- SuperWoW: RAW_COMBATLOG fires for all combat lines
_daRawCL:RegisterEvent("RAW_COMBATLOG")
_daRawCL:RegisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")
_daRawCL:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES")
_daRawCL:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS")
_daRawCL:RegisterEvent("CHAT_MSG_SPELL_SELF_MISSES")
_daRawCL:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
_daRawCL:RegisterEvent("CHAT_MSG_SPELL_SELF_BUFF")
_daRawCL:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS")
_daRawCL:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE")

_daRawCL:SetScript("OnEvent", function()
    local line

    if event == "RAW_COMBATLOG" then
        -- SuperWoW: arg1 = original event name, arg2 = text with GUIDs
        line = arg2
    else
        -- Classic CHAT_MSG_* events: arg1 is the human-readable line
        line = arg1
    end

    if not line or line == "" then return end

    -- Fast pre-filter: only care about lines involving the player
    if not str_find(line, "You ") and not str_find(line, "Your ") then
        return
    end

    _CL_Parse(line)
end)

-- Helpers consumed by ability-usable override
function _Warrior_Overpower_OK()
    if (_Now() > _OP_until) then return false end
    if not UnitExists("target") then return false end
    local tname = UnitName("target")
    return (tname ~= nil and _OP_target ~= nil and tname == _OP_target)
end

function _Warrior_Revenge_OK()
    return _Now() <= _REV_until
end

-- Remaining proc-window time for Overpower / Revenge (seconds), or nil if no proc
local function _WarriorProcRemainingForSpell(spellName)
    if not _isWarrior or not spellName then return nil end
    local now = _Now()

    if spellName == "Overpower" then
        local rem = _OP_until - now
        if rem and rem > 0 then return rem end

    elseif spellName == "Revenge" then
        local rem = _REV_until - now
        if rem and rem > 0 then return rem end
    end

    return nil
end


----------------------------------------------------------------
-- DoiteAuras Slide Manager (buttery-smooth 60fps animator)
----------------------------------------------------------------
local SlideMgr = {
    active = {},
}
_G.DoiteConditions_SlideMgr = SlideMgr

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
local function _PlayerAuraRemainingSeconds(auraName)
    if not auraName then return nil end
    if not PlayerAuraTimers then return nil end

    local now = GetTime()
    local t = PlayerAuraTimers.buffs[auraName] or PlayerAuraTimers.debuffs[auraName]
    if not t then
        return nil
    end

    local rem = t - now
    if rem > 0 then
        return rem
    end
    return nil
end

-- === Cursive integration: curse ownership + remaining time ===
local function _HasCursive()
    return (Cursive and Cursive.curses
            and Cursive.curses.GetCurseData
            and Cursive.curses.TimeRemaining) and true or false
end

_GetUnitGuid = function(unit)
    if not unit or type(UnitExists) ~= "function" then
        return nil
    end

    -- UnitExists(unit) returns existsFlag, guid
    local exists, guid = UnitExists(unit)
    if exists and guid and guid ~= "" then
        return guid
    end

    -- Other clients where UnitExists doesn't return a GUID but UnitGUID exists
    if type(UnitGUID) == "function" then
        local g = UnitGUID(unit)
        if g and g ~= "" then
            return g
        end
    end

    return nil
end

local function _CursiveGetCurseData(spellName, unit)
    if not spellName or not _HasCursive() then return nil end
    local guid = _GetUnitGuid(unit)
    if not guid then return nil end

    -- Try name as-is first, then lowercase (API wants lowercase key)
    local data = Cursive.curses:GetCurseData(spellName, guid)
    if not data then
        data = Cursive.curses:GetCurseData(string.lower(spellName), guid)
    end
    return data
end

local function _CursiveAuraRemainingSeconds(spellName, unit)
    local data = _CursiveGetCurseData(spellName, unit)
    if not data then return nil end

    local rem = Cursive.curses:TimeRemaining(data)
    if rem and rem > 0 then
        return rem
    end
    return nil
end

-- Use Cursive: to evaluate a remaining-time comparison on a unit.
local function _CursiveRemainingPass(spellName, unit, comp, threshold)
    if not spellName or not unit or not comp or threshold == nil then
        return nil
    end
    if not _HasCursive() then
        return nil
    end

    local data = _CursiveGetCurseData(spellName, unit)
    if not data then
        return nil
    end

    local rem = Cursive.curses:TimeRemaining(data)
    if not rem or rem <= 0 then
        return nil
    end

    return _RemainingPasses(rem, comp, threshold)
end

local function _AuraConditions_UnitHasAura(unit, auraName, wantDebuff)
    if not unit or not auraName then return false end
    if unit == "target" and (not UnitExists("target")) then
        return false
    end

    local snap = auraSnapshot[unit]
    if not snap then return false end

    if wantDebuff then
        local d = snap.debuffs
        return d and d[auraName] == true
    else
        local b = snap.buffs
        return b and b[auraName] == true
    end
end

local function _AuraConditions_CheckEntry(entry)
    if not entry or not entry.buffType or not entry.mode then
        return true
    end
    local name = entry.name
    if not name or name == "" then
        return true
    end

    -- ABILITY branch: use cooldown by spell name
    if entry.buffType == "ABILITY" then
        if entry.mode == "notcd" or entry.mode == "oncd" then
            local rem, dur = _AbilityCooldownByName(name)
            if not rem then
                -- Ability not in spellbook => cannot satisfy this condition
                return false
            end
            local onCd = (rem > 0)
            if entry.mode == "notcd" then
                return (not onCd)
            else -- "oncd"
                return onCd
            end
        else
            -- Unsupported mode for ABILITY; ignore rather than fail
            return true
        end
    end

    -- BUFF / DEBUFF branch: check unit auras
    local unit = entry.unit or "player"
    if unit ~= "player" and unit ~= "target" then
        unit = "player"
    end

    -- If explicitly target "target" but have no target, do not pass
    if unit == "target" and (not UnitExists("target")) then
        return false
    end

    local wantDebuff = (entry.buffType == "DEBUFF")
    local hasAura    = _AuraConditions_UnitHasAura(unit, name, wantDebuff)

    if entry.mode == "found" then
        return hasAura
    elseif entry.mode == "missing" then
        return (not hasAura)
    end

    -- Unknown mode => do not fail the whole list
    return true
end

local function _EvaluateAuraConditionsList(list)
    if not list then return true end
    local n = table.getn(list)
    if n == 0 then return true end

    local i = 1
    while i <= n do
        if not _AuraConditions_CheckEntry(list[i]) then
            return false
        end
        i = i + 1
    end
    return true
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

-- Get stack count for a named aura on a unit (works for player/target)
local function _GetAuraStacksOnUnit(unit, auraName, wantDebuff)
    if not unit or not auraName then return nil end

    local i = 1
    while i <= 40 do
        local tex, applications, auraId
        if wantDebuff then
            -- texture, stacks, dtype, spellID
            tex, applications, _, auraId = UnitDebuff(unit, i)
        else
            -- texture, stacks, spellID
            tex, applications, auraId = UnitBuff(unit, i)
        end
        if not tex then
            break
        end

        local name
        if auraId and SpellInfo then
            name = SpellInfo(auraId)
        end

        if name == auraName then
            return applications or 1
        end

        i = i + 1
    end
    return nil
end

-- Fast check: does unit have ANY of the named buffs?
local function _UnitHasAnyBuffName(unit, names)
    if not unit or not names then return false end

    local snap = auraSnapshot[unit]
    local b = snap and snap.buffs
    if not b then return false end

    local n = table.getn(names)
    for i = 1, n do
        if b[names[i]] then
            return true
        end
    end
    return false
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

-- Combo points reader
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
        return string.format("%d+h", math.floor(remSec / 3600))
    elseif remSec >= 60 then
        return string.format("%d+m", math.floor(remSec / 60))
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
    s = str_gsub(s, "^%s+", "")
    s = str_gsub(s, "%s+$", "")
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
    -- Hard guards: must have a real frame, real icon, real data
    if not frame or type(frame) ~= "table" then return end
    local icon = frame.icon
    if not icon or type(icon) ~= "table" or not icon.GetTexture or not icon.SetTexture then
        return
    end
    if not data or type(data) ~= "table" then return end

    local c    = data.conditions and data.conditions.aura
    local name = data.displayName or data.name
    if not c or not name or name == "" then return end

    -- 0a) If config already has a spellid, trust SpellInfo(spellid) first.
    if data.spellid and SpellInfo then
        local sid = tonumber(data.spellid)
        if sid and sid > 0 then
            local _, _, tex = SpellInfo(sid)
            if tex and tex ~= "" then
                local cur = icon:GetTexture()
                if cur ~= tex then
                    icon:SetTexture(tex)
                end

                IconCache[name] = tex
                if DoiteAurasDB and DoiteAurasDB.cache then
                    DoiteAurasDB.cache[name] = tex
                end
                if DoiteAurasDB and DoiteAurasDB.spells and data.key and DoiteAurasDB.spells[data.key] then
                    DoiteAurasDB.spells[data.key].iconTexture = tex
                end
                return
            end
        end
    end

    -- 0b) If Nampower is present and this spell exists in player spellbook, resolve name -> spellId -> texture even if no one has the aura up.
    if GetSpellIdForName and SpellInfo then
        local sid = GetSpellIdForName(name)
        if sid and sid > 0 then
            local _, _, tex = SpellInfo(sid)
            if tex and tex ~= "" then
                local cur = icon:GetTexture()
                if cur ~= tex then
                    icon:SetTexture(tex)
                end

                IconCache[name] = tex
                if DoiteAurasDB and DoiteAurasDB.cache then
                    DoiteAurasDB.cache[name] = tex
                end
                if DoiteAurasDB and DoiteAurasDB.spells and data.key and DoiteAurasDB.spells[data.key] then
                    local s = DoiteAurasDB.spells[data.key]
                    s.iconTexture = tex
                    if not s.spellid then
                        s.spellid = tostring(sid)
                    end
                end
                return
            end
        end
    end

    -- 1) Existing cache / placeholder logic (unchanged)
    local curTex  = icon:GetTexture()
    local cached  = IconCache and IconCache[name] or nil
    local isPlaceholder = (curTex == nil)
                        or (type(curTex) == "string" and str_find(curTex, "INV_Misc_QuestionMark"))

    -- If already have a cached real texture for this aura name, just use it.
    if cached and (not curTex or curTex ~= cached) then
        icon:SetTexture(cached)
        return
    end

    -- If the icon already has a non-placeholder texture and nothing cached,
    if (not isPlaceholder) and curTex then
        return
    end

    -- 2) Existing live aura + spellbook scan (your old code)
    local tgt = c.target or (c.targetSelf and "self") or (c.targetTarget and "target") or "self"
    local checkSelf, checkTarget = false, false
    if tgt == "self" then
        checkSelf = true
    elseif tgt == "target" then
        checkTarget = true
    elseif tgt == "both" then
        checkSelf  = true
        checkTarget = true
    else
        checkSelf = true
    end

    local function tryUnit(unit)
        -- 1) BUFFS: confirm NAME via SpellInfo/tooltip, then take TEXTURE from UnitBuff
        local i = 1
        while i <= 40 do
            local n = _GetAuraName(unit, i, false)
            if n == nil then
                break
            end
            if n ~= "" and n == name then
                local tex = UnitBuff(unit, i)
                if tex and (isPlaceholder or curTex ~= tex) then
                    icon:SetTexture(tex)
                    IconCache[name] = tex
                    if DoiteAurasDB and DoiteAurasDB.cache then
                        DoiteAurasDB.cache[name] = tex
                    end
                end
                return true
            end
            i = i + 1
        end

        -- 2) DEBUFFS: confirm NAME via SpellInfo/tooltip, then take TEXTURE from UnitDebuff
        i = 1
        while i <= 40 do
            local n = _GetAuraName(unit, i, true)
            if n == nil then
                break
            end
            if n ~= "" and n == name then
                local tex = UnitDebuff(unit, i)
                if tex and (isPlaceholder or curTex ~= tex) then
                    icon:SetTexture(tex)
                    IconCache[name] = tex
                    if DoiteAurasDB and DoiteAurasDB.cache then
                        DoiteAurasDB.cache[name] = tex
                    end
                end
                return true
            end
            i = i + 1
        end

        return false
    end

    local got = false
    if checkSelf then
        got = tryUnit("player")
    end
    if (not got) and checkTarget and UnitExists("target") then
        got = tryUnit("target")
    end

    -- Fallback to spellbook texture
    if not got then
        local i = 1
        while i <= 200 do
            local s = GetSpellName(i, BOOKTYPE_SPELL)
            if not s then break end
            if s == name then
                local tex = GetSpellTexture(i, BOOKTYPE_SPELL)
                if tex and (isPlaceholder or curTex ~= tex) then
                    icon:SetTexture(tex)
                    IconCache[name] = tex
                    if DoiteAurasDB and DoiteAurasDB.cache then
                        DoiteAurasDB.cache[name] = tex
                    end
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

-- Ensure a synthetic Item slot icon (equipped trinkets / weapons) has a real texture
local function _EnsureItemTexture(frame, data)
    if not frame or not frame.icon or not data then return end
    if not data.conditions or not data.conditions.item then return end

    local c           = data.conditions.item
    local invSlotName = c.inventorySlot
    if not invSlotName or invSlotName == "" then return end

    local nameKey = data.displayName or data.name
    if not nameKey or nameKey == "" then return end

    local slot = nil

    if invSlotName == "TRINKET1" or invSlotName == "TRINKET2"
       or invSlotName == "MAINHAND" or invSlotName == "OFFHAND"
       or invSlotName == "RANGED" then

        slot = _SlotIndexForName(invSlotName)

    elseif invSlotName == "TRINKET_FIRST" then
        -- Prefer the remembered winner for this key if exist
        if data.key and _TrinketFirstMemory[data.key]
           and _TrinketFirstMemory[data.key].slot then
            slot = _TrinketFirstMemory[data.key].slot
        else
            -- Fallback: whichever trinket slot currently has an item (1, then 2)
            local has1 = GetInventoryItemLink("player", INV_SLOT_TRINKET1) ~= nil
            local has2 = GetInventoryItemLink("player", INV_SLOT_TRINKET2) ~= nil
            if has1 then
                slot = INV_SLOT_TRINKET1
            elseif has2 then
                slot = INV_SLOT_TRINKET2
            end
        end

    elseif invSlotName == "TRINKET_BOTH" then
        -- Cosmetic choice: prefer trinket #1's icon if present, else trinket #2
        local has1 = GetInventoryItemLink("player", INV_SLOT_TRINKET1) ~= nil
        local has2 = GetInventoryItemLink("player", INV_SLOT_TRINKET2) ~= nil
        if has1 then
            slot = INV_SLOT_TRINKET1
        elseif has2 then
            slot = INV_SLOT_TRINKET2
        end
    end

    if not slot then return end

    local tex = GetInventoryItemTexture and GetInventoryItemTexture("player", slot)
    if not tex then return end

    local curTex = frame.icon:GetTexture()
    if curTex ~= tex then
        frame.icon:SetTexture(tex)
    end

    IconCache[nameKey] = tex
    DoiteAurasDB.cache[nameKey] = tex
    if DoiteAurasDB.spells and data.key and DoiteAurasDB.spells[data.key] then
        DoiteAurasDB.spells[data.key].iconTexture = tex
    end
end

-- === Time-logic helpers (for heartbeat pruning) =================

-- Does an Ability icon use any time-based features?
local function _IconHasTimeLogic_Ability(data)
    if not data or not data.conditions or not data.conditions.ability then
        return false
    end
    local c = data.conditions.ability
    if c.textTimeRemaining == true then
        return true
    end
    if c.remainingEnabled == true then
        return true
    end
    return false
end

-- Does an Item icon use any time-based features?
local function _IconHasTimeLogic_Item(data)
    if not data or not data.conditions or not data.conditions.item then
        return false
    end
    local c = data.conditions.item
    if c.textTimeRemaining == true then
        return true
    end
    if c.remainingEnabled == true then
        return true
    end
    return false
end

-- Does a Buff/Debuff icon use any time-based features?
local function _IconHasTimeLogic_Aura(data)
    if not data or not data.conditions or not data.conditions.aura then
        return false
    end
    local c = data.conditions.aura
    if c.textTimeRemaining == true then
        return true
    end
    if c.remainingEnabled == true then
        return true
    end
    return false
end

-- Global flag: have ANY ability/item icons that need the 0.5s heartbeat?
_hasAnyAbilityTimeLogic = false
-- Global flag: have ANY aura icons that need the 0.5s heartbeat?
_hasAnyAuraTimeLogic    = false
-- Global flag: do we have ANY reason to track target auras at all?
_hasAnyTargetAuraUsage  = true

local function _RebuildAbilityTimeHeartbeatFlag()
    _hasAnyAbilityTimeLogic = false

    -- 1) Runtime icons
    if DoiteAurasDB and DoiteAurasDB.spells then
        local key, data
        for key, data in pairs(DoiteAurasDB.spells) do
            if type(data) == "table" and data.type then
                if data.type == "Ability" and _IconHasTimeLogic_Ability(data) then
                    _hasAnyAbilityTimeLogic = true
                    return
                elseif data.type == "Item" and _IconHasTimeLogic_Item(data) then
                    _hasAnyAbilityTimeLogic = true
                    return
                end
            end
        end
    end

    -- 2) Editor-only icons (not in live set)
    if DoiteDB and DoiteDB.icons then
        local key, data
        for key, data in pairs(DoiteDB.icons) do
            if type(data) == "table" and data.type then
                if data.type == "Ability" and _IconHasTimeLogic_Ability(data) then
                    _hasAnyAbilityTimeLogic = true
                    return
                elseif data.type == "Item" and _IconHasTimeLogic_Item(data) then
                    _hasAnyAbilityTimeLogic = true
                    return
                end
            end
        end
    end
end

local function _RebuildAuraTimeHeartbeatFlag()
    _hasAnyAuraTimeLogic = false

    -- 1) Runtime icons
    if DoiteAurasDB and DoiteAurasDB.spells then
        local key, data
        for key, data in pairs(DoiteAurasDB.spells) do
            if type(data) == "table" and (data.type == "Buff" or data.type == "Debuff") then
                if _IconHasTimeLogic_Aura(data) then
                    _hasAnyAuraTimeLogic = true
                    return
                end
            end
        end
    end

    -- 2) Editor-only icons
    if DoiteDB and DoiteDB.icons then
        local key, data
        for key, data in pairs(DoiteDB.icons) do
            if type(data) == "table" and (data.type == "Buff" or data.type == "Debuff") then
                if _IconHasTimeLogic_Aura(data) then
                    _hasAnyAuraTimeLogic = true
                    return
                end
            end
        end
    end
end

local function _RebuildAuraUsageFlags()
    _hasAnyTargetAuraUsage = false

    -- 1) Live icons
    if DoiteAurasDB and DoiteAurasDB.spells then
        local key, data
        for key, data in pairs(DoiteAurasDB.spells) do
            if type(data) == "table" then
                -- Any explicit Buff/Debuff icon that can ever point at target?
                if data.type == "Buff" or data.type == "Debuff" then
                    local c = data.conditions and data.conditions.aura
                    if c and (c.targetHarm or c.targetHelp) then
                        _hasAnyTargetAuraUsage = true
                        return
                    end
                end

                -- Any ability auraConditions that can check target?
                local ca = data.conditions and data.conditions.ability
                if ca and ca.auraConditions and (ca.targetHarm or ca.targetHelp) then
                    _hasAnyTargetAuraUsage = true
                    return
                end

                -- Any item auraConditions that can check target?
                local ci = data.conditions and data.conditions.item
                if ci and ci.auraConditions and (ci.targetHarm or ci.targetHelp) then
                    _hasAnyTargetAuraUsage = true
                    return
                end
            end
        end
    end

    -- 2) Editor-only icons
    if DoiteDB and DoiteDB.icons then
        local key, data
        for key, data in pairs(DoiteDB.icons) do
            if type(data) == "table" then
                if data.type == "Buff" or data.type == "Debuff" then
                    local c = data.conditions and data.conditions.aura
                    if c and (c.targetHarm or c.targetHelp) then
                        _hasAnyTargetAuraUsage = true
                        return
                    end
                end

                local ca = data.conditions and data.conditions.ability
                if ca and ca.auraConditions and (ca.targetHarm or ca.targetHelp) then
                    _hasAnyTargetAuraUsage = true
                    return
                end

                local ci = data.conditions and data.conditions.item
                if ci and ci.auraConditions and (ci.targetHarm or ci.targetHelp) then
                    _hasAnyTargetAuraUsage = true
                    return
                end
            end
        end
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
	    -- Precompute target flags (used by Swiftmend guard and generic target gating)
    local allowHelp = (c.targetHelp == true)
    local allowHarm = (c.targetHarm == true)
    local allowSelf = (c.targetSelf == true)

	    -- While editing this key, force conditions to pass (always show).
    -- Keeps group reflow and any "show"-based logic consistent.
    if _IsKeyUnderEdit(data.key) then
        local glow = (c.glow and true) or false
        local grey = (c.greyscale and true) or false
        return true, glow, grey
    end

    local show = true

    -- === 1. Cooldown / usability ===
    local spellName  = _GetCanonicalSpellNameFromData(data)
    local spellIndex = _GetSpellIndexByName(spellName)
    local bookType = BOOKTYPE_SPELL
    local foundInBook = (spellIndex ~= nil)

    if not foundInBook then
        return false
    end

    local function IsOnCooldown(idx)
        if not idx then return false end
        local start, dur = GetSpellCooldown(idx, bookType)
        return (start and start > 0 and dur and dur > 1.5)
    end

    if c.mode == "usable" and spellIndex then
        local _, cls = UnitClass("player"); cls = cls and string.upper(cls) or ""
        local onCooldown = IsOnCooldown(spellIndex)

        -- === WARRIOR override for Overpower/Revenge ===
        if cls == "WARRIOR" and (spellName == "Overpower" or spellName == "Revenge") then
            if onCooldown then
                show = false
            else
                local rage = UnitMana("player") or 0
                if rage < 5 then
                    show = false
                else
                    if spellName == "Overpower" then
                        -- Require current target to be the dodger, window <= 5s
                        show = _Warrior_Overpower_OK()
                    else -- "Revenge"
                        -- Any target OK, window <= 5s
                        show = _Warrior_Revenge_OK()
                    end
                end
            end
        else
            -- ===== Normal usable logic (all other classes/spells) =====
            local usable, noMana = _SafeSpellUsable(spellName, spellIndex, bookType)

            if (usable ~= 1) or onCooldown then
                show = false
            else
                -- === Usable special cases (guards) ===
                if cls == "DRUID" and spellName == "Swiftmend" then
                    local needs = { "Rejuvenation", "Regrowth" }
                    local ok = false

                    if allowHelp and not allowSelf then
                        if UnitExists("target")
                           and UnitIsFriend("player","target")
                           and (not UnitIsUnit("player","target")) then
                            ok = _UnitHasAnyBuffName("target", needs)
                        else
                            ok = false
                        end

                    elseif allowSelf and not (allowHelp or allowHarm) then
                        ok = _UnitHasAnyBuffName("player", needs)

                    else
                        if UnitExists("target") then
                            if UnitIsUnit("player","target") then
                                ok = _UnitHasAnyBuffName("player", needs)
                            elseif UnitIsFriend("player","target") then
                                ok = _UnitHasAnyBuffName("target", needs)
                            else
                                ok = false
                            end
                        else
                            ok = false
                        end
                    end

                    if not ok then
                        show = false
                    end
                end
            end
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

	-- If nothing selected, do NOT gate on target at all.
	local ok = true
	if allowHelp or allowHarm or allowSelf then
		ok = false

		-- Self: must be explicitly targeting player
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
    if c.remainingEnabled
       and c.remainingComp and c.remainingComp ~= ""
       and c.remainingVal  ~= nil and c.remainingVal  ~= "" then

        local threshold = tonumber(c.remainingVal)
        if threshold then
            local rem = _AbilityRemainingSeconds(spellIndex, bookType)

            -- the real remaining cooldown for this spellbook entry.
            if rem and rem > 0 then
                if not _RemainingPasses(rem, c.remainingComp, threshold) then
                    show = false
                end
            end
        end
    end

    -- === Aura Conditions (extra ability gating) ===========================
    if show and c.auraConditions and table.getn(c.auraConditions) > 0 then
        if not _EvaluateAuraConditionsList(c.auraConditions) then
            show = false
        end
    end

    local glow = c.glow and true or false
    local grey = c.greyscale and true or false

    return show, glow, grey
end


---------------------------------------------------------------
-- Item condition evaluation
---------------------------------------------------------------
local function CheckItemConditions(data)
    if not data or not data.conditions or not data.conditions.item then
        return true, false, false
    end
    local c = data.conditions.item

    -- While editing this key, force conditions to pass (always show)
    if _IsKeyUnderEdit(data.key) then
        local glow = (c.glow and true) or false
        local grey = (c.greyscale and true) or false
        return true, glow, grey
    end

    local show = true

    -- Shared target flags
    local allowHelp = (c.targetHelp == true)
    local allowHarm = (c.targetHarm == true)
    local allowSelf = (c.targetSelf == true)

    -- --------------------------------------------------------------------
    -- 1. Core item state (Whereabouts / inventorySlot + mode / cooldown)
    -- --------------------------------------------------------------------
    local state = _EvaluateItemCoreState(data, c)

    -- Whereabouts / inventorySlot gating
    if not state.passesWhere then
        local glow = c.glow and true or false
        local grey = c.greyscale and true or false
        return false, glow, grey
    end

    -- Mode ("oncd" / "notcd") gating
    if state.modeMatches == false then
        local glow = c.glow and true or false
        local grey = c.greyscale and true or false
        return false, glow, grey
    end

    -- --------------------------------------------------------------------
    -- 2. Combat state
    -- --------------------------------------------------------------------
    local inCombatFlag  = (c.inCombat == true)
    local outCombatFlag = (c.outCombat == true)

    if not (inCombatFlag and outCombatFlag) then
        if inCombatFlag and not InCombat() then show = false end
        if outCombatFlag and InCombat() then show = false end
    end

    -- --------------------------------------------------------------------
    -- 3. Target gating (same semantics as abilities)
    -- --------------------------------------------------------------------
    if show and (allowHelp or allowHarm or allowSelf) then
        local ok = false

        -- Self: must explicitly be targeting player
        if allowSelf and UnitExists("target") and UnitIsUnit("player", "target") then
            ok = true
        end

        -- Help: friendly target (excluding self)
        if (not ok) and allowHelp and UnitExists("target")
           and UnitIsFriend("player", "target")
           and (not UnitIsUnit("player", "target")) then
            ok = true
        end

        -- Harm: hostile and not friendly
        if (not ok) and allowHarm and UnitExists("target")
           and UnitCanAttack("player", "target")
           and (not UnitIsFriend("player", "target")) then
            ok = true
        end

        if not ok then
            show = false
        end
    end

    -- --------------------------------------------------------------------
    -- 4. Form / stance requirement
    -- --------------------------------------------------------------------
    if show and c.form and c.form ~= "All" then
        if not _PassesFormRequirement(c.form, auraSnapshot) then
            show = false
        end
    end

    -- --------------------------------------------------------------------
    -- 5. HP threshold (my / target) – same logic as abilities
    -- --------------------------------------------------------------------
    if show and c.hpComp and c.hpVal and c.hpMode and c.hpMode ~= "" then
        local hpTarget = nil
        if c.hpMode == "my" then
            hpTarget = "player"
        elseif c.hpMode == "target" then
            if UnitExists("target") then
                if allowSelf then
                    if UnitIsUnit("player", "target") then
                        hpTarget = "target"
                    end
                elseif allowHelp and allowHarm then
                    if not UnitIsUnit("player", "target") then
                        hpTarget = "target"
                    end
                elseif allowHelp then
                    if UnitIsFriend("player", "target")
                       and (not UnitIsUnit("player", "target")) then
                        hpTarget = "target"
                    end
                elseif allowHarm then
                    if UnitCanAttack("player", "target")
                       and (not UnitIsFriend("player", "target")) then
                        hpTarget = "target"
                    end
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

    -- --------------------------------------------------------------------
    -- 6. Combo points (Rogue/Druid only) – same as abilities
    -- --------------------------------------------------------------------
    if show and c.cpEnabled == true and _PlayerUsesComboPoints() then
        local cp  = _GetComboPointsSafe()
        local thr = tonumber(c.cpVal)
        if thr and c.cpComp and c.cpComp ~= "" then
            if not _ValuePasses(cp, c.cpComp, thr) then
                show = false
            end
        end
    end

    -- --------------------------------------------------------------------
    -- 7. Power (resource) threshold – same semantics as abilities
    -- --------------------------------------------------------------------
    if show and c.powerEnabled
       and c.powerComp ~= nil and c.powerComp ~= ""
       and c.powerVal  ~= nil and c.powerVal  ~= "" then

        local valPct    = GetPowerPercent()
        local targetPct = tonumber(c.powerVal) or 0
        local comp      = c.powerComp

        if not _ValuePasses(valPct, comp, targetPct) then
            show = false
        end
    end

    -- --------------------------------------------------------------------
    -- 8. Remaining (item cooldown time left)
    --     Editor only allows this when mode == "oncd" and not whereMissing.
    -- --------------------------------------------------------------------
    if show and c.remainingEnabled
       and c.remainingComp and c.remainingComp ~= ""
       and c.remainingVal  ~= nil and c.remainingVal  ~= "" then

        local threshold = tonumber(c.remainingVal)
        if threshold and state.rem and state.rem > 0 then
            if not _RemainingPasses(state.rem, c.remainingComp, threshold) then
                show = false
            end
        end
    end

    -- === Aura Conditions (extra item gating) ==============================
    if show and c.auraConditions and table.getn(c.auraConditions) > 0 then
        if not _EvaluateAuraConditionsList(c.auraConditions) then
            show = false
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

    -- While editing this key, force conditions to pass (always show).
    if _IsKeyUnderEdit(data.key) then
        local glow = (c.glow and true) or false
        local grey = (c.greyscale and true) or false
        return true, glow, grey
    end

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
	
    local ownerFilter = nil
    local onlyMine = (wantDebuff and c.onlyMine == true) or false

    -- Only activate ownership logic when explicitly looking at a real target.
    if onlyMine and (not allowSelf) and (allowHelp or allowHarm) then
        ownerFilter = "mine"
    end

    -- === Target gating (OR semantics for help/harm) ===
    local requiresTarget = (allowHelp or allowHarm) and (not allowSelf)
    if requiresTarget then
        if not UnitExists("target") then
            return false, false, false
        end

        local isFriend  = UnitIsFriend("player", "target")
        local canAttack = UnitCanAttack("player", "target")

        local matchesAny = false

		if allowHelp then
			if isFriend then
				-- allow friendly targets including self
				matchesAny = true
			end
		end

        if (not matchesAny) and allowHarm then
            if canAttack and (not isFriend) then
                matchesAny = true
            end
        end

        if not matchesAny then
            return false, false, false
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
                    local n = _GetAuraName("player", i, false)
                    if n == nil then
                        break  -- real end of list
                    end
                    if n ~= "" and n == name then
                        hit = true
                        break
                    end
                    i = i + 1
                end
            end
            if (not hit) and wantDebuff then
                i = 1
                while i <= 40 do
                    local n = _GetAuraName("player", i, true)
                    if n == nil then
                        break
                    end
                    if n ~= "" and n == name then
                        hit = true
                        break
                    end
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

    -- === Cursive aura owner filter ("My Aura" / "Others Aura") ===
    if found and ownerFilter and _HasCursive() then
        local ownerUnit = nil
        if (not allowSelf) and (allowHelp or allowHarm) then
            ownerUnit = "target"
        end

        if ownerUnit then
            local dataCurse = _CursiveGetCurseData(name, ownerUnit)
            if dataCurse and dataCurse.currentPlayer ~= nil then
                local isMine = (dataCurse.currentPlayer == true)
                if ownerFilter == "mine" and not isMine then
                    found = false
                elseif ownerFilter == "others" and isMine then
                    found = false
                end
            else
                if ownerFilter == "mine" then
                    found = false
                end
            end
        end
    end

    -- Decide show based on mode first
    local show
    if c.mode == "missing" then
        show = (not found)
    else -- default and "found"
        show = found
    end

    -- Combat state
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
            local allowHelp = (c.targetHelp == true)
            local allowHarm = (c.targetHarm == true)
            local allowSelf = (c.targetSelf == true)

            if UnitExists("target") then
                if allowSelf then
                    if UnitIsUnit("player","target") then
                        hpTarget = "target"
                    end
                elseif allowHelp and allowHarm then
                    -- Both: any non-self target (friendly or hostile)
                    if not UnitIsUnit("player","target") then
                        hpTarget = "target"
                    end
                elseif allowHelp then
                    if UnitIsFriend("player","target")
                       and (not UnitIsUnit("player","target")) then
                        hpTarget = "target"
                    end
                elseif allowHarm then
                    if UnitCanAttack("player","target")
                       and (not UnitIsFriend("player","target")) then
                        hpTarget = "target"
                    end
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

    -- === Remaining-time condition ==========================================
    if c.remainingEnabled
       and c.remainingComp and c.remainingComp ~= ""
       and c.remainingVal  ~= nil and c.remainingVal  ~= "" then

        if c.mode ~= "missing" and show then
            local unitForRem
            if c.targetSelf == true then
                unitForRem = "player"
            else
                local hasHelp = (c.targetHelp == true)
                local hasHarm = (c.targetHarm == true)

                if UnitExists("target") and (hasHelp or hasHarm) then
                    if hasHelp and hasHarm then
                        -- Both: any non-self target (friendly or hostile)
                        if not UnitIsUnit("player","target") then
                            unitForRem = "target"
                        end
                    elseif hasHelp then
                        -- Friendly target, excluding self
                        if UnitIsFriend("player","target")
                           and (not UnitIsUnit("player","target")) then
                            unitForRem = "target"
                        end
                    elseif hasHarm then
                        -- Hostile target
                        if UnitCanAttack("player","target")
                           and (not UnitIsFriend("player","target")) then
                            unitForRem = "target"
                        end
                    end
                end
            end

            local threshold = tonumber(c.remainingVal)
            if unitForRem and threshold then
                local comp = c.remainingComp
                local pass = true

                if unitForRem == "player" then
                    -- Only use the real player aura API here.
                    local rem = _PlayerAuraRemainingSeconds(name)
                    if rem and rem > 0 then
                        pass = _RemainingPasses(rem, comp, threshold)
                    else
                        -- No timer info: do NOT kill the icon on that basis.
                        pass = true
                    end
                else
                    if ownerFilter == "mine" and _HasCursive() then
                        local rpass = _CursiveRemainingPass(name, unitForRem, comp, threshold)
                        if rpass == false then
                            pass = false
                        else
                            pass = true
                        end
                    else
                        pass = true
                    end
                end

                if not pass then
                    show = false
                end
            end
        end
    end


    -- === Stacks (aura applications) ===
    if c.stacksEnabled
       and c.stacksComp and c.stacksComp ~= ""
       and c.stacksVal  ~= nil and c.stacksVal  ~= ""
       and c.mode ~= "missing"
       and show then

        local threshold = tonumber(c.stacksVal)
        if threshold then
            local unitToCheck = nil

            -- Use the same target semantics as main aura gating
            local allowHelp = (c.targetHelp == true)
            local allowHarm = (c.targetHarm == true)
            local allowSelf = (c.targetSelf == true)

            -- If none selected, default to Self
            if (not allowHelp) and (not allowHarm) and (not allowSelf) then
                allowSelf = true
            end

            if allowSelf then
                -- Explicit or implied self: always read stacks from player
                unitToCheck = "player"
            elseif UnitExists("target") and (allowHelp or allowHarm) then
                local isFriend  = UnitIsFriend("player","target")
                local canAttack = UnitCanAttack("player","target")

                -- Help: friendly targets including self
                if allowHelp and isFriend then
                    unitToCheck = "target"
                -- Harm: hostile, non-friendly targets
                elseif allowHarm and canAttack and (not isFriend) then
                    unitToCheck = "target"
                end
            end

            if unitToCheck then
                local cnt = _GetAuraStacksOnUnit(unitToCheck, name, wantDebuff)
                if cnt and (not _StacksPasses(cnt, c.stacksComp, threshold)) then
                    show = false
                end
            end
        end
    end

    -- === Aura Conditions (extra aura-icon gating) =========================
    if show and c.auraConditions and table.getn(c.auraConditions) > 0 then
        if not _EvaluateAuraConditionsList(c.auraConditions) then
            show = false
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
	local editingAny = _IsAnyKeyUnderEdit()
    local live = DoiteAurasDB and DoiteAurasDB.spells
    local edit = DoiteDB and DoiteDB.icons
    if not live and not edit then return end

    local key, data

    -- 1) Live icons (runtime set)
    if live then
        for key, data in pairs(live) do
            -- Defensive: skip and clean up any corrupted entries so they
            -- can't break the evaluation loop.
            if type(data) ~= "table" then
                live[key] = nil
            elseif data.type then
                data.key = key

                if data.type == "Ability" or data.type == "Item" then
                    local show, glow, grey
                    if data.type == "Ability" then
                        show, glow, grey = CheckAbilityConditions(data)
                    else
                        show, glow, grey = CheckItemConditions(data)
                    end
                    DoiteConditions:ApplyVisuals(key, show, glow, grey)

                elseif data.type == "Buff" or data.type == "Debuff" then
                    local show, glow, grey = CheckAuraConditions(data)
                    DoiteConditions:ApplyVisuals(key, show, glow, grey)
                end
            end
        end
    end

    -- 2) Any extra editor-only icons (keys not in live)
    if edit then
        for key, data in pairs(edit) do
            if (not live) or (not live[key]) then
                if type(data) ~= "table" then
                    edit[key] = nil
                elseif data.type then
                    data.key = key

                    if data.type == "Ability" or data.type == "Item" then
                        local show, glow, grey
                        if data.type == "Ability" then
                            show, glow, grey = CheckAbilityConditions(data)
                        else
                            show, glow, grey = CheckItemConditions(data)
                        end
                        DoiteConditions:ApplyVisuals(key, show, glow, grey)

                    elseif data.type == "Buff" or data.type == "Debuff" then
                        local show, glow, grey = CheckAuraConditions(data)
                        DoiteConditions:ApplyVisuals(key, show, glow, grey)
                    end
                end
            end
        end
    end
end

-- Centralized overlay updater: remaining-time text + stacks.
-- Used by both ApplyVisuals (logic passes) and the light timer ticker.
local function _Doite_UpdateOverlayForFrame(frame, key, dataTbl, slideActive)
    if not frame or not dataTbl then return end

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
        fs:SetJustifyH("CENTER")
        fs:SetJustifyV("MIDDLE")
        frame._daTextRem = fs
    end
    if not frame._daTextStacks then
        local fs2 = frame._daTextLayer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs2:SetJustifyH("RIGHT")
        fs2:SetJustifyV("BOTTOM")
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

    -- Defaults hidden
    frame._daTextRem:SetText("")
    frame._daTextRem:Hide()
    frame._daTextStacks:SetText("")
    frame._daTextStacks:Hide()

    -- Reset per-evaluation sort remaining time (used by group "time" mode)
    frame._daSortRem = nil

    -- ========== Remaining Time ==========
    local wantRem = false
    local remText = nil

    -- Decide if show time text for abilities
    local function _ShowAbilityTime(ca, rem, dur, slide)
        if not rem or rem <= 0 then return false end
        dur = dur or 0

        -- 1) ON COOLDOWN: always show for the entire real cooldown.
        if ca.mode == "oncd" then
            return (dur > 0)
        end

        -- 2) USABLE / NOTCD with slider: slide can override the 1.6s/GCD filter
        if (ca.mode == "usable" or ca.mode == "notcd") and ca.slider == true then
            if slide then
                return true
            end
            local maxWindow = math.min(3.0, (dur or 0) * 0.6)
            return rem <= maxWindow and (dur > 1.6)
        end

        -- Default (paranoid): late window + real cooldown
        local maxWindow = math.min(3.0, (dur or 0) * 0.6)
        return (dur > 1.6) and (rem <= maxWindow)
    end

    if dataTbl then
        ----------------------------------------------------------------
        -- Ability remaining-time text
        ----------------------------------------------------------------
        if dataTbl.type == "Ability"
           and dataTbl.conditions
           and dataTbl.conditions.ability then

            local ca = dataTbl.conditions.ability
            if ca.textTimeRemaining == true then
                local spellName  = _GetCanonicalSpellNameFromData(dataTbl)
                local remCD, durCD  = _AbilityCooldownByName(spellName)
                local isWarriorProc = _isWarrior
                                      and (spellName == "Overpower" or spellName == "Revenge")
                local remShown, durShown

                -- 1) Normal CD text (on cooldown)
                if remCD and remCD > 0 and _ShowAbilityTime(ca, remCD, durCD, slideActive) then
                    remShown = remCD
                    durShown = durCD
                -- 2) Warrior proc window text when NOT on cooldown
                elseif isWarriorProc and (not remCD or remCD <= 0) then
                    local remProc = _WarriorProcRemainingForSpell(spellName)
                    if remProc and remProc > 0 then
                        remShown = remProc
                        durShown = 4.0
                    end
                end

                if remShown and remShown > 0 then
                    remText = _FmtRem(remShown)
                    wantRem = (remText ~= nil)
                end

                -- For group "time" sorting: use whatevershowing
                if remShown and remShown > 0 then
                    local usesTimeForLogic =
                        (ca.mode == "oncd") or (ca.remainingEnabled == true)
                    if usesTimeForLogic then
                        frame._daSortRem = remShown
                    end
                end
            end

        ----------------------------------------------------------------
        -- Item remaining-time text (trinkets, usable items)
        ----------------------------------------------------------------
        elseif dataTbl.type == "Item"
           and dataTbl.conditions
           and dataTbl.conditions.item then

            local ci = dataTbl.conditions.item
            if ci.textTimeRemaining == true then
                -- Reuse the same core state CheckItemConditions uses
                local state = _EvaluateItemCoreState(dataTbl, ci)
                if state and state.rem and state.rem > 0 then
                    remText = _FmtRem(state.rem)
                    wantRem = (remText ~= nil)

                    -- Let group “time” sort by this remaining
                    frame._daSortRem = state.rem
                end
            end
			
        ----------------------------------------------------------------
        -- Aura remaining-time text (player via cached timers, target via Cursive)
        ----------------------------------------------------------------
        elseif (dataTbl.type == "Buff" or dataTbl.type == "Debuff")
           and dataTbl.conditions
           and dataTbl.conditions.aura then

            local ca = dataTbl.conditions.aura
            if ca.textTimeRemaining == true then
                local auraName = dataTbl.displayName or dataTbl.name
                local rem      = nil

                -- Decide unit: mostly mirrors CheckAuraConditions target logic
                local unitForRem = nil
                if ca.targetSelf == true then
                    unitForRem = "player"
                else
                    local hasHelp = (ca.targetHelp == true)
                    local hasHarm = (ca.targetHarm == true)

                    if UnitExists("target") and (hasHelp or hasHarm) then
                        if hasHelp and hasHarm then
                            if not UnitIsUnit("player","target") then
                                unitForRem = "target"
                            end
                        elseif hasHelp then
                            if UnitIsFriend("player","target")
                               and (not UnitIsUnit("player","target")) then
                                unitForRem = "target"
                            end
                        elseif hasHarm then
                            if UnitCanAttack("player","target")
                               and (not UnitIsFriend("player","target")) then
                                unitForRem = "target"
                            end
                        end
                    end
                end

                if unitForRem == "player" then
                    rem = _PlayerAuraRemainingSeconds(auraName)
                elseif unitForRem == "target" then
                    -- Only player own debuffs will have timings via Cursive.
                    rem = _CursiveAuraRemainingSeconds(auraName, "target")
                end

                if rem and rem > 0 then
                    remText = _FmtRem(rem)
                    wantRem = (remText ~= nil)

                    -- For group "time" sorting: timed buff/debuff
                    frame._daSortRem = rem
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
    if dataTbl
       and (dataTbl.type == "Buff" or dataTbl.type == "Debuff")
       and dataTbl.conditions
       and dataTbl.conditions.aura then

        local ca = dataTbl.conditions.aura
        if ca.textStackCounter == true then
            local auraName   = dataTbl.displayName or dataTbl.name
            local wantDebuff = (dataTbl.type == "Debuff")

            -- Resolve which unit to read stacks from (same semantics as CheckAuraConditions)
            local unitToCheck = nil
            local allowHelp   = (ca.targetHelp == true)
            local allowHarm   = (ca.targetHarm == true)
            local allowSelf   = (ca.targetSelf == true)

            -- If nothing selected, default to Self
            if (not allowHelp) and (not allowHarm) and (not allowSelf) then
                allowSelf = true
            end

            if allowSelf then
                unitToCheck = "player"
            elseif UnitExists("target") and (allowHelp or allowHarm) then
                local isFriend  = UnitIsFriend("player","target")
                local canAttack = UnitCanAttack("player","target")

                -- Help: friendly targets including self
                if allowHelp and isFriend then
                    unitToCheck = "target"
                -- Harm: hostile, non-friendly targets
                elseif allowHarm and canAttack and (not isFriend) then
                    unitToCheck = "target"
                end
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
			if cached then
				frame.icon:SetTexture(cached)
			else
				frame.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
			end
		end
		if dataTbl then
			if dataTbl.type == "Ability" then
				_EnsureAbilityTexture(frame, dataTbl)
			elseif dataTbl.type == "Buff" or dataTbl.type == "Debuff" then
				_EnsureAuraTexture(frame, dataTbl)
			elseif dataTbl.type == "Item" then
				_EnsureItemTexture(frame, dataTbl)
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
        local stoppedSlide = false

        -- Slider only ever makes sense for usable/notcd modes
        if ca.slider and (ca.mode == "usable" or ca.mode == "notcd") then
            local spellName  = _GetCanonicalSpellNameFromData(dataTbl)
            local rem, dur   = _AbilityCooldownByName(spellName)
            local wasSliding = SlideMgr.active and SlideMgr.active[key]
            local maxWindow  = math.min(3.0, (dur or 0) * 0.6)

            -- Last time *this* spell was actually cast (UNIT_CASTEVENT -> _MarkSliderSeen)
            local lastSeen = spellName and _SliderSeen and _SliderSeen[spellName] or nil


            local hasSeenForThisCD = false
            if lastSeen and rem and dur and dur > 0 then
                local now   = GetTime()
                -- reconstruct approximate cooldown start from (now, rem, dur)
                local start = now + rem - dur
                -- small epsilon because lastSeen and start are sampled in
                if lastSeen + 0.25 >= start then
                    hasSeenForThisCD = true
                end
            end

            local shouldStart    = hasSeenForThisCD and rem and dur and dur > 1.6 and rem > 0 and rem <= maxWindow
            local shouldContinue = hasSeenForThisCD and wasSliding and rem and rem > 0

            if shouldStart or shouldContinue then
                local baseX, baseY = 0, 0
                if _GetBaseXY then baseX, baseY = _GetBaseXY(key, dataTbl) end
                SlideMgr:StartOrUpdate(key, (ca.sliderDir or "center"), baseX, baseY, GetTime() + rem)
                startedSlide = (not wasSliding) and true or false
            else
                if wasSliding then
                    stoppedSlide = true
                end
                SlideMgr:Stop(key)
            end
        else
            if SlideMgr.active and SlideMgr.active[key] then
                stoppedSlide = true
            end
            SlideMgr:Stop(key)
        end

        -- === immediate group reflow on slide start/stop ===
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
		frame._daShouldShow   = ((show == true) or editing) and true or false
		frame._daUseGlow      = useGlow and true or false
		frame._daUseGreyscale = useGrey and true or false
    end

	-- Determine baseline anchoring
	local baseX, baseY = 0, 0
	if _GetBaseXY and dataTbl then baseX, baseY = _GetBaseXY(key, dataTbl) end

	-- If this icon belongs to a group, prefer the latest computed position (for leaders AND followers)
	local isGrouped = (dataTbl and dataTbl.group and dataTbl.group ~= "" and dataTbl.group ~= "no")
	local hasGroupPos = false
	if isGrouped and _G["DoiteGroup_Computed"] and _G["DoiteGroup_Computed"][dataTbl.group] then
		local arr = _G["DoiteGroup_Computed"][dataTbl.group]
		local n = table.getn(arr)
		for idx = 1, n do
			local e = arr[idx]
			if e and e.key == key and e._computedPos then
				baseX = e._computedPos.x
				baseY = e._computedPos.y
				hasGroupPos = true
				break
			end
		end
	end

	if slideActive then SlideMgr:UpdateBase(key, baseX, baseY) end

    -- Show during slide preview even if main conditions would hide
    local showForSlide = (show or allowSlideShow)

	-- If this is the key currently being edited, force it visible regardless of conditions/group caps
	if editing then
		showForSlide = true
	end

	-- Group capacity may block this icon unless editing this very key
	if frame._daBlockedByGroup and (not editing) then
		showForSlide = false
	end

    -- Apply position and alpha (no stutter: set exact coordinates each paint)
    do
        local isGrouped = (dataTbl and dataTbl.group and dataTbl.group ~= "" and dataTbl.group ~= "no")
        local isLeader = (dataTbl and dataTbl.isLeader == true)

		-- Apply position and alpha (no stutter:set exact coordinates each paint)
		do
			-- When sliding: apply transient movement to everyone (leaders + followers)
			if slideActive then
				frame:ClearAllPoints()
				frame:SetPoint("CENTER", UIParent, "CENTER", baseX + dx, baseY + dy)
				frame:SetAlpha(slideAlpha)
			else
				-- When not sliding: do NOT force followers' points here.
				if not (isGrouped and not isLeader) then
					frame:ClearAllPoints()
					frame:SetPoint("CENTER", UIParent, "CENTER", baseX, baseY)
					frame:SetAlpha((dataTbl and dataTbl.alpha) or 1)
				else
					-- Followers:
					-- Only re-anchor having a computed group position for this key.
					if hasGroupPos then
						frame:ClearAllPoints()
						frame:SetPoint("CENTER", UIParent, "CENTER", baseX, baseY)
					end
					-- If !hasGroupPos: do not touch points this tick; avoid snapping back to original x/y.
					frame:SetAlpha((dataTbl and dataTbl.alpha) or 1)
				end
			end
		end
        -- === Overlay Text: cooldown remaining + stacks (forced above glow) ===
        _Doite_UpdateOverlayForFrame(frame, key, dataTbl, slideActive)
    end

	-- === Apply EFFECTS with change detection (don’t restart animations every frame) ===
	do
		-- Decide final show flag (editing & group gating preserved)
		local showForSlide = (show or allowSlideShow)
		if editing then
			showForSlide = true
		end

		-- Never suppress the edited icon because of group capacity while editing
		if frame._daBlockedByGroup and (not editing) then
			showForSlide = false
		end

		-- Apply visibility only on change
		if frame._daLastShown ~= showForSlide then
			frame._daLastShown = showForSlide
			if showForSlide then
				frame:Show()
				frame:SetAlpha(1)  -- avoid transient fade-outs during edit drags
			else
				frame:Hide()
			end
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
    -- Re-scan icons if anyone still needs the time heartbeat
    if _RebuildAbilityTimeHeartbeatFlag then
        _RebuildAbilityTimeHeartbeatFlag()
    end
    if _RebuildAuraTimeHeartbeatFlag then
        _RebuildAuraTimeHeartbeatFlag()
    end
    if _RebuildAuraUsageFlags then
        _RebuildAuraUsageFlags()
    end
    dirty_ability, dirty_aura, dirty_target, dirty_power = true, true, true, true
end

function DoiteConditions:EvaluateAbilities(doLogic, doTime)
    local editingAny = _IsAnyKeyUnderEdit()
    -- Default behaviour (no args): full logic + time, as before.
    if doLogic == nil and doTime == nil then
        doLogic, doTime = true, true
    else
        if doLogic == nil then doLogic = true end
        if doTime  == nil then doTime  = false end
    end

    local live = DoiteAurasDB and DoiteAurasDB.spells
    local edit = DoiteDB and DoiteDB.icons
    if not live and not edit then return end

    local key, data

    -- 1) Live icons (runtime set)
    if live then
        for key, data in pairs(live) do
            if data and (data.type == "Ability" or data.type == "Item") then
                -- Decide whether this icon should be touched in this pass
                local wantsTime = false
                if doTime then
                    if data.type == "Ability" then
                        wantsTime = _IconHasTimeLogic_Ability(data)
                    else -- "Item"
                        wantsTime = _IconHasTimeLogic_Item(data)
                    end
                end

                local wantsLogic = doLogic

                if wantsLogic or wantsTime then
                    data.key = key
                    local show, glow, grey
                    if data.type == "Ability" then
                        show, glow, grey = CheckAbilityConditions(data)
                    else
                        show, glow, grey = CheckItemConditions(data)
                    end
                    DoiteConditions:ApplyVisuals(key, show, glow, grey)
                end
            end
        end
    end

    -- 2) Any extra editor-only icons (keys not in live)
    if edit then
        for key, data in pairs(edit) do
            if (not live) or (not live[key]) then
                if data and (data.type == "Ability" or data.type == "Item") then
                    local wantsTime = false
                    if doTime then
                        if data.type == "Ability" then
                            wantsTime = _IconHasTimeLogic_Ability(data)
                        else
                            wantsTime = _IconHasTimeLogic_Item(data)
                        end
                    end

                    local wantsLogic = doLogic

                    if wantsLogic or wantsTime then
                        data.key = key
                        local show, glow, grey
                        if data.type == "Ability" then
                            show, glow, grey = CheckAbilityConditions(data)
                        else
                            show, glow, grey = CheckItemConditions(data)
                        end
                        DoiteConditions:ApplyVisuals(key, show, glow, grey)
                    end
                end
            end
        end
    end
end

function DoiteConditions:EvaluateAuras()
    local editingAny = _IsAnyKeyUnderEdit()
    local live = DoiteAurasDB and DoiteAurasDB.spells
    local edit = DoiteDB and DoiteDB.icons
    if not live and not edit then return end

    local key, data

    -- 1) Live icons (runtime set)
    if live then
        for key, data in pairs(live) do
            if type(data) ~= "table" then
                live[key] = nil
            elseif data.type == "Buff" or data.type == "Debuff" then
                local show, glow, grey = CheckAuraConditions(data)
                DoiteConditions:ApplyVisuals(key, show, glow, grey)
            end
        end
    end

	-- 2) Any extra editor-only icons (keys not in live)
    if edit and editingAny then
        for key, data in pairs(edit) do
            if (not live) or (not live[key]) then
                if type(data) ~= "table" then
                    edit[key] = nil
                elseif data.type == "Buff" or data.type == "Debuff" then
                    local show, glow, grey = CheckAuraConditions(data)
                    DoiteConditions:ApplyVisuals(key, show, glow, grey)
                end
            end
        end
    end
end

-- Small helper: keep warrior Overpower/Revenge proc windows in sync
local function _WarriorProcTick()
    if not _isWarrior then return end
    if _REV_until <= 0 and _OP_until <= 0 then return end

    local nowAbs = GetTime()

    if _REV_until > 0 and nowAbs > _REV_until then
        _REV_until = 0
        dirty_ability = true
    end

    if _OP_until > 0 and nowAbs > _OP_until then
        _OP_until = 0
        dirty_ability = true
    end
end

_G.DoiteConditions_WarriorProcTick = _WarriorProcTick

-- Lightweight pass that ONLY refreshes remaining-time text / stacks.
-- No condition logic, no aura scanning – uses existing cached data.
local function DoiteConditions_UpdateTimeText()
    local live = DoiteAurasDB and DoiteAurasDB.spells
    local edit = DoiteDB and DoiteDB.icons
    if not live and not edit then return end

	local function hasTimeLogicForData(data)
		if not data or not data.type then return false end
		if data.type == "Ability" then
			return _IconHasTimeLogic_Ability(data)
		elseif data.type == "Buff" or data.type == "Debuff" then
			return _IconHasTimeLogic_Aura(data)
		elseif data.type == "Item" then
			return _IconHasTimeLogic_Item(data)
		end
		return false
	end

    local function processSet(set, skipKeys)
        if not set then return end
        for key, data in pairs(set) do
            if type(data) == "table" and data.type then
                if not skipKeys or not skipKeys[key] then
                    -- Skip icons that never use time text / remaining logic.
                    if hasTimeLogicForData(data) then
                        local frame = _G["DoiteIcon_" .. key]
                        if frame and frame:IsShown() then
                            local dataTbl =
                                (DoiteDB and DoiteDB.icons and DoiteDB.icons[key])
                                or (DoiteAurasDB and DoiteAurasDB.spells and DoiteAurasDB.spells[key])
                            if dataTbl then
                                _Doite_UpdateOverlayForFrame(
                                    frame,
                                    key,
                                    dataTbl,
                                    frame._daSliding == true
                                )
                            end
                        end
                    end
                end
            end
        end
    end

    -- Runtime icons
    processSet(live, nil)

    -- Editor-only icons (keys not in live)
    if edit then
        processSet(edit, live or {})
    end
end

local _tick = CreateFrame("Frame")

-- Keep these as globals so the OnUpdate script doesn't capture them as upvalues
_acc        = 0
_textAccum  = 0

-- Lift the body into a real function
local function DoiteConditions_OnUpdate(dt)
    _acc       = _acc + dt
    _textAccum = _textAccum + dt

    -- Keep warrior Overpower/Revenge procs in sync even if no other events fire
    DoiteConditions_WarriorProcTick()

    -- Smooth remaining-time text (abilities/items/auras) on a cheap path
    if _textAccum >= 0.1 then
        _textAccum = 0

        if _hasAnyAbilityTimeLogic or _hasAnyAuraTimeLogic then
            DoiteConditions_UpdateTimeText()
        end
    end

    -- Render faster while sliding; else ~30fps
    local thresh = (next(DoiteConditions_SlideMgr.active) ~= nil) and 0.03 or 0.033
    if _acc < thresh then return end
    _acc = 0

    local needAbilityLogic = dirty_ability or dirty_power
    local needAbilityTime  = dirty_ability_time
    local needAura         = dirty_aura or dirty_target

    if needAbilityLogic or needAbilityTime then
        _G.DoiteConditions:EvaluateAbilities(needAbilityLogic, needAbilityTime)
    end
    if needAura then
        _G.DoiteConditions:EvaluateAuras()
    end

    if needAbilityLogic or needAbilityTime or needAura then
        dirty_aura, dirty_target, dirty_power = false, false, false
        dirty_ability_time = false
        -- While sliding, ability icons updating each frame
        dirty_ability = next(DoiteConditions_SlideMgr.active) and true or false
    end
end

_tick:SetScript("OnUpdate", function()
    local dt = arg1 or 0
    local ok, err = pcall(DoiteConditions_OnUpdate, dt)
    if not ok and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cffff0000[DoiteAuras] OnUpdate error:|r " .. tostring(err)
        )
    end
end)

-- Prime aura snapshot and trigger initial evaluation
DoiteConditions_ScanUnitAuras("player")
if _G.UnitExists and _G.UnitExists("target") then
    DoiteConditions_ScanUnitAuras("target")
end
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
eventFrame:RegisterEvent("UNIT_MANA")
eventFrame:RegisterEvent("UNIT_ENERGY")
eventFrame:RegisterEvent("UNIT_RAGE")
eventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:RegisterEvent("UNIT_HEALTH")
eventFrame:RegisterEvent("PLAYER_COMBO_POINTS")
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")

eventFrame:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" then
        -- Initial aura scan
        DoiteConditions_ScanUnitAuras("player")
        if _G.UnitExists and _G.UnitExists("target") then
            DoiteConditions_ScanUnitAuras("target")
        end
        dirty_ability, dirty_aura, dirty_target, dirty_power = true, true, true, true

        -- Cache player class for lightweight warrior-specific logic
        local _, cls = UnitClass("player")
        cls = cls and string.upper(cls) or ""
        _isWarrior = (cls == "WARRIOR")

        -- Prime time-heartbeat flags
        if _RebuildAbilityTimeHeartbeatFlag then
            _RebuildAbilityTimeHeartbeatFlag()
        end
        if _RebuildAuraTimeHeartbeatFlag then
            _RebuildAuraTimeHeartbeatFlag()
        end

	elseif event == "UNIT_AURA" then
		if arg1 == "player" then
			-- Player auras changed: rebuild snapshot once
			DoiteConditions_ScanUnitAuras("player")

			-- Only rebuild per-name timer cache if any aura icon actually uses time logic.
			if _hasAnyAuraTimeLogic then
				local timers = PlayerAuraTimers
				if timers then
					for k in pairs(timers.buffs)   do timers.buffs[k]   = nil end
					for k in pairs(timers.debuffs) do timers.debuffs[k] = nil end

					if GetPlayerBuff and GetPlayerBuffTimeLeft
					   and DoiteConditionsTooltip
					   and DoiteConditionsTooltip.SetPlayerBuff then

						-- HELPFUL (buffs)
						for i = 0, 31 do
							local idx = GetPlayerBuff(i, "HELPFUL")
							if not idx or idx < 0 then break end

							DoiteConditionsTooltip:ClearLines()
							DoiteConditionsTooltip:SetPlayerBuff(idx)
							local tn = DoiteConditionsTooltipTextLeft1
									   and DoiteConditionsTooltipTextLeft1:GetText()
							if tn and tn ~= "" then
								local tl = GetPlayerBuffTimeLeft(idx)
								if tl and tl > 0 then
									timers.buffs[tn] = GetTime() + tl
								end
							end
						end

						-- HARMFUL (debuffs)
						for i = 0, 31 do
							local idx = GetPlayerBuff(i, "HARMFUL")
							if not idx or idx < 0 then break end

							DoiteConditionsTooltip:ClearLines()
							DoiteConditionsTooltip:SetPlayerBuff(idx)
							local tn = DoiteConditionsTooltipTextLeft1
									   and DoiteConditionsTooltipTextLeft1:GetText()
							if tn and tn ~= "" then
								local tl = GetPlayerBuffTimeLeft(idx)
								if tl and tl > 0 then
									timers.debuffs[tn] = GetTime() + tl
								end
							end
						end
					end
				end
			end

			dirty_aura    = true
			dirty_ability = true

    elseif arg1 == "target" then
        -- Only bother if *any* config ever looks at target auras.
        if _hasAnyTargetAuraUsage then
            if _G.UnitExists and _G.UnitExists("target") then
                DoiteConditions_ScanUnitAuras("target")
            else
                local snap = _G.DoiteConditions_AuraSnapshot
                local s = snap and snap.target
                if s then
                    local b, d = s.buffs, s.debuffs
                    if b then for k in pairs(b) do b[k] = nil end end
                    if d then for k in pairs(d) do d[k] = nil end end
                end
            end
            dirty_aura    = true
            dirty_ability = true
        end
    end

    elseif event == "SPELLS_CHANGED" then
        local cache = _G.DoiteConditions_SpellIndexCache
        if cache then
            for k in pairs(cache) do cache[k] = nil end
        end
        dirty_ability = true

    elseif event == "PLAYER_TARGET_CHANGED" then
        if _G.UnitExists and _G.UnitExists("target") then
            DoiteConditions_ScanUnitAuras("target")
        else
            local snap = _G.DoiteConditions_AuraSnapshot
            local s = snap and snap.target
            if s then
                for k in pairs(s.buffs) do s.buffs[k] = nil end
                for k in pairs(s.debuffs) do s.debuffs[k] = nil end
            end
        end
        dirty_target, dirty_aura = true, true
        dirty_ability = true

    elseif event == "SPELL_UPDATE_COOLDOWN"
        or event == "UPDATE_SHAPESHIFT_FORM" then

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
        if arg1 == "player" then
            dirty_power = true
        end

    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        dirty_ability, dirty_aura = true, true

    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        if _G.DoiteConditions_ClearTrinketFirstMemory then
            _G.DoiteConditions_ClearTrinketFirstMemory()
        end
        dirty_ability = true
        dirty_aura    = true
    end
end)