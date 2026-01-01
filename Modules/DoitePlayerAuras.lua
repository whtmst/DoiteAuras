local DoitePlayerAuras = {
  buffs = {},
  debuffs = {},

  spellIdToNameCache = {},
  spellNameToIdCache = {},

  activeBuffs = {},
  activeDebuffs = {}
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

local function MarkActive(spellId, activeTable)
  -- cache spell name if not already cached
  if not DoitePlayerAuras.spellIdToNameCache[spellId] then
    local spellName = GetSpellNameAndRankForId(spellId)
    if spellName then
      DoitePlayerAuras.spellIdToNameCache[spellId] = spellName
      DoitePlayerAuras.spellNameToIdCache[spellName] = spellId
      activeTable[spellName] = true
    end
  else
    -- mark as active
    local spellName = DoitePlayerAuras.spellIdToNameCache[spellId]
    if spellName then
      activeTable[spellName] = true
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
      MarkActive(spellId, DoitePlayerAuras.activeBuffs)
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
    local _, stacks, spellId = UnitDebuff("player", i)
    if spellId then
      DoitePlayerAuras.debuffs[i].spellId = spellId
      DoitePlayerAuras.debuffs[i].stacks = stacks
      MarkActive(spellId, DoitePlayerAuras.activeDebuffs)
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

function DoitePlayerAuras.GetBuffInfo(spellName)
  -- check if spell is active
  if not DoitePlayerAuras.activeBuffs[spellName] then
    return nil, nil
  end

  local spellId = DoitePlayerAuras.spellNameToIdCache[spellName]
  if not spellId then
    return nil, nil
  end

  -- search through buffs for matching spell ID
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
  -- check if active
  if not DoitePlayerAuras.activeDebuffs[spellName] then
    return nil, nil
  end

  local spellId = DoitePlayerAuras.spellNameToIdCache[spellName]
  if not spellId then
    return nil, nil
  end

  -- search through debuffs for matching spell ID
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

PlayerAurasFrame:SetScript("OnEvent", function()
  if event == "PLAYER_ENTERING_WORLD" then
    UpdateBuffs()
    UpdateDebuffs()
  else
    -- BUFF_ADDED_SELF, BUFF_REMOVED_SELF, DEBUFF_ADDED_SELF, DEBUFF_REMOVED_SELF
    -- event slot is 1 indexed, need to convert to zero index for use with GetPlayerBuff functions
    local guid, slot, spellId, stacks = arg1, arg2, arg3, arg4
    if event == "BUFF_ADDED_SELF" then
      DoitePlayerAuras.buffs[slot].spellId = spellId
      DoitePlayerAuras.buffs[slot].stacks = stacks
      MarkActive(spellId, DoitePlayerAuras.activeBuffs)
    elseif event == "BUFF_REMOVED_SELF" then
      -- probably could just shift down buffs a slot but not sure what happens when 2 get removed at the exact same time
      UpdateBuffs()
      MarkInactive(spellId, DoitePlayerAuras.activeBuffs)
    elseif event == "DEBUFF_ADDED_SELF" then
      DoitePlayerAuras.debuffs[slot].spellId = spellId
      DoitePlayerAuras.debuffs[slot].stacks = stacks
      MarkActive(spellId, DoitePlayerAuras.activeDebuffs)
    elseif event == "DEBUFF_REMOVED_SELF" then
      -- probably could just shift down buffs a slot but not sure what happens when 2 get removed at the exact same time
      UpdateDebuffs()
      MarkInactive(spellId, DoitePlayerAuras.activeDebuffs)
    end
  end
end)
