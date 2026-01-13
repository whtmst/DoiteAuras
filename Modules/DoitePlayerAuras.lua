---------------------------------------------------------------
-- DoitePlayerAuras.lua
-- Player aura cache + lookup helpers (buffs/debuffs, slot + stack counts)
-- Please respect license note: Ask permission
-- WoW 1.12 | Lua 5.0
---------------------------------------------------------------
local DoitePlayerAuras = {
  buffs = {},
  debuffs = {},

  spellIdToNameCache = {},
  spellNameToIdCache = {},

  activeBuffs = {},
  activeDebuffs = {},

  playerBuffIndexCache = {}
}
-- initialize all buff/debuff indexes
for i = 1, 32 do
  table.insert(DoitePlayerAuras.buffs, {
    spellId = nil,
    stackCount = nil
  })
end
for i = 1, 16 do
  table.insert(DoitePlayerAuras.debuffs, {
    spellId = nil,
    stackCount = nil
  })
end

_G["DoitePlayerAuras"] = DoitePlayerAuras

local PlayerAurasFrame = CreateFrame("Frame", "DoitePlayerAuras")

PlayerAurasFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
PlayerAurasFrame:RegisterEvent("BUFF_ADDED_SELF")
PlayerAurasFrame:RegisterEvent("BUFF_REMOVED_SELF")
PlayerAurasFrame:RegisterEvent("DEBUFF_ADDED_SELF")
PlayerAurasFrame:RegisterEvent("DEBUFF_REMOVED_SELF")

local function MarkActive(spellId, activeTable, slot)
  -- cache spell name if not already cached
  if not DoitePlayerAuras.spellIdToNameCache[spellId] then
    local spellName = GetSpellRecField(spellId, "name")
    if spellName then
      DoitePlayerAuras.spellIdToNameCache[spellId] = spellName
      DoitePlayerAuras.spellNameToIdCache[spellName] = spellId
      activeTable[spellName] = slot
    end
  else
    -- mark as active with slot
    local spellName = DoitePlayerAuras.spellIdToNameCache[spellId]
    if spellName then
      activeTable[spellName] = slot
    end
  end
end

local function MarkInactive(spellId, activeTable)
  local spellName = DoitePlayerAuras.spellIdToNameCache[spellId]
  if spellName then
    activeTable[spellName] = false
  end
end

local function UpdateBuffs()
  -- clear active buffs
  DoitePlayerAuras.activeBuffs = {}

  -- update existing buffs/debuffs
  for i = 1, 32 do
    local _, stacks, spellId = UnitBuff("player", i)
    if spellId then
      DoitePlayerAuras.buffs[i].spellId = spellId
      DoitePlayerAuras.buffs[i].stacks = stacks
      MarkActive(spellId, DoitePlayerAuras.activeBuffs, i)
    else
      -- once we hit nil, all remaining will be nil, so clear them and break
      for j = i, 32 do
        DoitePlayerAuras.buffs[j].spellId = nil
        DoitePlayerAuras.buffs[j].stacks = nil
      end
      break
    end
  end
end

local function UpdateDebuffs()
  -- clear active debuffs
  DoitePlayerAuras.activeDebuffs = {}

  for i = 1, 16 do
    local _, stacks, _, spellId = UnitDebuff("player", i)
    if spellId then
      DoitePlayerAuras.debuffs[i].spellId = spellId
      DoitePlayerAuras.debuffs[i].stacks = stacks
      MarkActive(spellId, DoitePlayerAuras.activeDebuffs, i)
    else
      -- once we hit nil, all remaining will be nil, so clear them and break
      for j = i, 16 do
        DoitePlayerAuras.debuffs[j].spellId = nil
        DoitePlayerAuras.debuffs[j].stacks = nil
      end
      break
    end
  end
end

function DoitePlayerAuras.IsActive(spellName)
  return DoitePlayerAuras.activeBuffs[spellName] or DoitePlayerAuras.activeDebuffs[spellName] or false
end

function DoitePlayerAuras.HasBuff(spellName)
  return DoitePlayerAuras.activeBuffs[spellName] or false
end

function DoitePlayerAuras.HasDebuff(spellName)
  return DoitePlayerAuras.activeDebuffs[spellName] or false
end

function DoitePlayerAuras.GetBuffInfo(spellName)
  -- check if spell is active and get cached slot
  local cachedSlot = DoitePlayerAuras.activeBuffs[spellName]
  if not cachedSlot then
    return nil, nil
  end

  local spellId = DoitePlayerAuras.spellNameToIdCache[spellName]
  if not spellId then
    return nil, nil
  end

  -- check cached slot first
  if DoitePlayerAuras.buffs[cachedSlot] and DoitePlayerAuras.buffs[cachedSlot].spellId == spellId then
    return cachedSlot, DoitePlayerAuras.buffs[cachedSlot]
  end

  -- fallback: search through buffs for matching spell ID
  for i = 1, 32 do
    if not DoitePlayerAuras.buffs[i].spellId then
      break
    end

    if DoitePlayerAuras.buffs[i].spellId == spellId then
      return i, DoitePlayerAuras.buffs[i]
    end
  end

  return nil, nil
end

function DoitePlayerAuras.GetDebuffInfo(spellName)
  -- check if active and get cached slot
  local cachedSlot = DoitePlayerAuras.activeDebuffs[spellName]
  if not cachedSlot then
    return nil, nil
  end

  local spellId = DoitePlayerAuras.spellNameToIdCache[spellName]
  if not spellId then
    return nil, nil
  end

  -- check cached slot first
  if DoitePlayerAuras.debuffs[cachedSlot] and DoitePlayerAuras.debuffs[cachedSlot].spellId == spellId then
    return cachedSlot, DoitePlayerAuras.debuffs[cachedSlot]
  end

  -- fallback: search through debuffs for matching spell ID
  for i = 1, 16 do
    if not DoitePlayerAuras.debuffs[i].spellId then
      break
    end

    if DoitePlayerAuras.debuffs[i].spellId == spellId then
      return i, DoitePlayerAuras.debuffs[i]
    end
  end

  return nil, nil
end

-- returns the player buff index (buffs and debuffs are mixed together) for use with GetPlayerBuffX functions
function DoitePlayerAuras.GetBuffBarSlot(spellName)
  -- convert spellName to spellId using cache
  local spellId = DoitePlayerAuras.spellNameToIdCache[spellName]
  if not spellId then
    return nil
  end

  -- check cached index first
  local cachedIndex = DoitePlayerAuras.playerBuffIndexCache[spellName]
  if cachedIndex then
    local buffSpellId = GetPlayerBuffID(cachedIndex) -- superwow function that returns spellId at player buff index
    if buffSpellId == spellId then
      return cachedIndex
    end
  end

  -- loop through 0-47 to find the buff/debuff index
  for i = 0, 47 do
    local buffSpellId = GetPlayerBuffID(i)

    if not buffSpellId then
      break
    end

    if buffSpellId == spellId then
      -- cache the index
      DoitePlayerAuras.playerBuffIndexCache[spellName] = i
      return i
    end
  end

  return nil
end

PlayerAurasFrame:SetScript("OnEvent", function()
  if event == "PLAYER_ENTERING_WORLD" then
    UpdateBuffs()
    UpdateDebuffs()
  else
    -- BUFF_ADDED_SELF, BUFF_REMOVED_SELF, DEBUFF_ADDED_SELF, DEBUFF_REMOVED_SELF
    -- unitSlot is the 1 indexed slot with empty slots removed for use with UnitBuff/UnitDebuff
    local guid, unitSlot, spellId, stacks = arg1, arg2, arg3, arg4
    if event == "BUFF_ADDED_SELF" then
      DoitePlayerAuras.buffs[unitSlot].spellId = spellId
      DoitePlayerAuras.buffs[unitSlot].stacks = stacks
      MarkActive(spellId, DoitePlayerAuras.activeBuffs, unitSlot)
    elseif event == "BUFF_REMOVED_SELF" then
      -- probably could just shift down buffs a slot but not sure what happens when 2 get removed at the exact same time
      UpdateBuffs()
      MarkInactive(spellId, DoitePlayerAuras.activeBuffs)
    elseif event == "DEBUFF_ADDED_SELF" then
      DoitePlayerAuras.debuffs[unitSlot].spellId = spellId
      DoitePlayerAuras.debuffs[unitSlot].stacks = stacks
      MarkActive(spellId, DoitePlayerAuras.activeDebuffs, unitSlot)
    elseif event == "DEBUFF_REMOVED_SELF" then
      -- probably could just shift down buffs a slot but not sure what happens when 2 get removed at the exact same time
      UpdateDebuffs()
      MarkInactive(spellId, DoitePlayerAuras.activeDebuffs)
    end
  end
end)
