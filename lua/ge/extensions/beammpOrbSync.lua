local M = {}

local active = false
local timer = 0
local delayBeforeStart = 8
local interval = 6
local duration = 60
local nextTick = 0
local stopAt = 0
local restoredPlayers = {}

local function resetState()
  active = false
  timer = 0
  nextTick = 0
  stopAt = 0
  restoredPlayers = {}
end

local function canRun()
  return MPCoreNetwork and MPCoreNetwork.isMPSession and MPCoreNetwork.isMPSession() and MPVehicleGE and MPVehicleGE.getPlayers and MPVehicleGE.restorePlayerVehicle and MPVehicleGE.applyPlayerQueues
end

local function tryRestoreAllPlayers()
  local players = MPVehicleGE.getPlayers() or {}
  local myName = MPConfig and MPConfig.getNickname and MPConfig.getNickname() or nil

  for playerName, playerData in pairs(players) do
    if playerName ~= myName and type(playerData) == 'table' then
      local playerID = playerData.id or playerData.playerID or playerData.ID
      pcall(MPVehicleGE.restorePlayerVehicle, playerName)
      if playerID ~= nil then
        pcall(MPVehicleGE.applyPlayerQueues, playerID)
      end
      restoredPlayers[playerName] = true
    end
  end
end

local function startJoinResync()
  if not canRun() then return end
  active = true
  timer = 0
  nextTick = delayBeforeStart
  stopAt = delayBeforeStart + duration
  restoredPlayers = {}
  log('I', 'beammpOrbSync', 'Scheduled post-join orb resync')
end

local function runPostJoin()
  startJoinResync()
end

local function onServerLeave()
  resetState()
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not active then return end
  if not canRun() then return end

  timer = timer + (dtReal or 0)

  if timer >= nextTick then
    tryRestoreAllPlayers()
    nextTick = nextTick + interval
  end

  if timer >= stopAt then
    active = false
    log('I', 'beammpOrbSyncStandalone', 'Finished post-join orb resync window')
  end
end

local function onExtensionLoaded()
  resetState()
  log('I', 'beammpOrbSyncStandalone', 'Loaded standalone BeamMP orb sync extension')
end

local function onExtensionUnloaded()
  resetState()
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate
M.runPostJoin = runPostJoin
M.onServerLeave = onServerLeave

return M
