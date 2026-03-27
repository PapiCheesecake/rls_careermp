-- propCargo.lua
-- Physical prop-based parcel delivery for CareerMP / RLS Career Overhaul.
--
-- Spawning:
--   light parcels (< 30 kg): cardboard_box/small, arranged in 2×2 square layers
--   heavy parcels (>= 30 kg): woodcrate, one per destination (all heavy IDs bundled)
--
-- Labels: onPreRender draws cargo name + destination above each prop via debugDrawer.
--
-- Delivery: props are removed and cargo queued when they arrive at their destination.
--   confirmDropOffData is called one queued entry per tick (re-entry guard safe).

local M = {}

local dParcelManager, dGenerator, dProgress, dGeneral

M.onCareerActivated = function()
  dParcelManager = career_modules_delivery_parcelManager
  dGenerator     = career_modules_delivery_generator
  dProgress      = career_modules_delivery_progress
  dGeneral       = career_modules_delivery_general
end

local PROP_RIGHT_OFFSET  = 3.0    -- metres right of pickup parking spot (group centre)
local BOX_GRID_SPACING   = 0.55   -- metres between box centres in the 2×2 grid
local BOX_LAYER_HEIGHT   = 0.40   -- metres per stacked layer
local BOX_SPAWN_LIFT     = 0.30   -- initial z lift off ground
local CRATE_SPAWN_LIFT   = 0.30
local DELIVERY_RADIUS    = 5.0    -- metres: prop must be this close to destination
local PLAYER_EXIT_RADIUS = 6.0    -- metres: player vehicle must be this far from drop-off
local UPDATE_INTERVAL    = 0.5    -- seconds between proximity checks
local HEAVY_THRESHOLD_KG = 30.0   -- kg: at or above → woodcrate, else cardboard_box

local LABEL_COLOR      = ColorF(1, 1, 1, 1)
local LABEL_BG         = ColorI(0, 0, 0, 180)
local LABEL_BG_BLUE    = ColorI(0, 60, 180, 210)
local LABEL_BG_GREEN   = ColorI(0, 150, 50, 210)
local LABEL_MAX_DIST   = 12.0
local LABEL_FOV_COS    = 0.985
local LABEL_Z_OFFSET   = 0.2

-- Each entry: { propId, cargoIds, destination, destinationPos, label }
local trackedProps  = {}
-- Queue of completed deliveries: { cargoIds, destination }
local deliveryQueue = {}
local updateTimer   = 0

local function getParkingSpotPos(location)
  if location and location.type == "facilityParkingspot" then
    local ps = dGenerator.getParkingSpotByPath(location.psPath)
    if ps then return vec3(ps.pos) end
  end
  return nil
end

local function getObjectPos(id)
  local obj = scenetree.findObjectById(id)
  if obj then return vec3(obj:getPosition()) end
  return nil
end

local function deleteProp(id)
  local obj = scenetree.findObjectById(id)
  if obj then obj:delete() end
end

-- Apply prop cargo multipliers to the actual cargo record so confirmDropOffData pays correctly.
-- Must be called after finalizeParcelItemDistanceAndRewards has already set cargo.rewards.
local function applyPropModifiers(cargoId)
  local cargo = dParcelManager.getCargoById(cargoId)
  if not cargo then return end
  if cargo.rewards and cargo.rewards.money then
    cargo.rewards.money = cargo.rewards.money * 2
  end
  if cargo.modifiers then
    for _, mod in ipairs(cargo.modifiers) do
      if mod.type == "timed" then
        if mod.timeUntilDelayed then mod.timeUntilDelayed = mod.timeUntilDelayed * 3 end
        if mod.timeUntilLate    then mod.timeUntilLate    = mod.timeUntilLate    * 3 end
      end
    end
  end
end

local function destKey(dest)
  return (dest.facId or "") .. "|" .. (dest.psPath or "")
end

-- Returns the world position for box slot i (0-based) in a 2×2 grid stack,
-- centred on groupCentre.
local function boxSlotPos(groupCentre, i)
  local layer = math.floor(i / 4)
  local slot  = i % 4
  local col   = slot % 2          -- 0 or 1
  local row   = math.floor(slot / 2) -- 0 or 1
  local dx = (col - 0.5) * BOX_GRID_SPACING
  local dy = (row - 0.5) * BOX_GRID_SPACING
  local dz = BOX_SPAWN_LIFT + layer * BOX_LAYER_HEIGHT
  return groupCentre + vec3(dx, dy, dz)
end

M.spawnPropsForCargo = function(batch, facId, psPath)
  if not batch or #batch == 0 then return end

  local ps = dGenerator.getParkingSpotByPath(psPath)
  if not ps then
    log("W", "propCargo", "Cannot find parking spot: " .. tostring(psPath))
    return
  end

  if not dGeneral.isDeliveryModeActive() then
    dGeneral.startDeliveryMode()
  end

  local basePos = vec3(ps.pos)
  local baseRot = quat(ps.rot) or quatFromDir(vec3(0, 1, 0))

  -- Group centre for all boxes: 3 m to the right of the parking spot
  local boxGroupCentre = basePos + (baseRot * vec3(1, 0, 0)) * PROP_RIGHT_OFFSET

  -- Crate positions stagger further right so they don't overlap the box pile
  local crateIdx = 0

  local lightItems    = {}
  local heavyByDest   = {}
  local heavyDestOrder = {}

  for _, cargo in ipairs(batch) do
    if (cargo.weight or 0) >= HEAVY_THRESHOLD_KG then
      local k = destKey(cargo.destination)
      if not heavyByDest[k] then
        heavyByDest[k] = { cargoIds = {}, destination = cargo.destination, name = cargo.name }
        table.insert(heavyDestOrder, k)
      end
      table.insert(heavyByDest[k].cargoIds, cargo.id)
    else
      table.insert(lightItems, cargo)
    end
  end

  local function spawnOne(model, config, spawnPos, cargoIds, destination, label)
    local obj = core_vehicles.spawnNewVehicle(model, {
      pos              = spawnPos,
      rot              = quatFromDir(vec3(0, 1, 0)),
      config           = config,
      autoEnterVehicle = false,
    })
    if obj then
      local propId = obj:getID()
      obj.playerUsable = false  -- belt-and-suspenders; general.lua also skips vehId=-1

      for _, cargoId in ipairs(cargoIds) do
        dParcelManager.changeCargoLocation(cargoId, {
          type        = "vehicle",
          vehId       = -1,   -- never in activeVehiclesIterator; general.lua skips unknown ids
          containerId = 0,
        })
        applyPropModifiers(cargoId)
      end

      table.insert(trackedProps, {
        propId         = propId,
        cargoIds       = cargoIds,
        destination    = destination,
        destinationPos = getParkingSpotPos(destination),
        label          = label,
      })

      log("I", "propCargo", string.format(
        "Spawned %s (id=%d, %d cargo) -> %s/%s",
        model, propId, #cargoIds, destination.facId, destination.psPath))
    else
      log("W", "propCargo", string.format(
        "Failed to spawn %s for dest %s/%s", model, destination.facId, destination.psPath))
    end
  end

  -- Spawn light parcels in 2×2 grid formation centred on boxGroupCentre
  for i, cargo in ipairs(lightItems) do
    local spawnPos = boxSlotPos(boxGroupCentre, i - 1)
    local destShort = dParcelManager.getLocationLabelShort(cargo.destination)
    local label = cargo.name .. "\n\xe2\x86\x92 " .. destShort  -- → arrow
    spawnOne("cardboard_box", "small", spawnPos, {cargo.id}, cargo.destination, label)
  end

  -- Spawn heavy crates in a line to the right of the box pile
  local crateLineStart = boxGroupCentre + (baseRot * vec3(1, 0, 0)) * 1.5
  for _, k in ipairs(heavyDestOrder) do
    local group = heavyByDest[k]
    crateIdx = crateIdx + 1
    local spawnPos = crateLineStart
      + (baseRot * vec3(1, 0, 0)) * (crateIdx - 1) * 1.8
      + vec3(0, 0, CRATE_SPAWN_LIFT)
    local destShort = dParcelManager.getLocationLabelShort(group.destination)
    local label = group.name .. " (" .. #group.cargoIds .. "x)\n\xe2\x86\x92 " .. destShort
    spawnOne("woodcrate", nil, spawnPos, group.cargoIds, group.destination, label)
  end

  if career_modules_delivery_cargoScreen and career_modules_delivery_cargoScreen.setBestRoute then
    career_modules_delivery_cargoScreen.setBestRoute()
  end
end

-- ── render loop: draw labels when player looks at a prop ─────────────────────
M.onPreRender = function()
  if #trackedProps == 0 then return end
  if not gameplay_walk.isWalking() then return end

  local camPos  = core_camera.getPosition()
  local camQuat = core_camera.getQuat()
  if not camPos or not camQuat then return end
  local camForward = camQuat * vec3(0, 1, 0)

  -- Find which destination is the current route target (closest prop destination to player).
  -- This mirrors the logic in setBestRoute.
  local playerVeh = be:getPlayerVehicleID(0) and scenetree.findObjectById(be:getPlayerVehicleID(0))
  local playerPos = playerVeh and vec3(playerVeh:getPosition()) or camPos
  local closestDestKey = nil
  local closestDist    = math.huge
  for _, entry in ipairs(trackedProps) do
    if entry.destinationPos then
      local d = (entry.destinationPos - playerPos):length()
      if d < closestDist then
        closestDist    = d
        closestDestKey = destKey(entry.destination)
      end
    end
  end

  for _, entry in ipairs(trackedProps) do
    local propPos = getObjectPos(entry.propId)
    if propPos and entry.label then
      local toVec = propPos - camPos
      local dist  = toVec:length()
      if dist > 0 and dist <= LABEL_MAX_DIST then
        local dot = toVec:normalized():dot(camForward)
        if dot >= LABEL_FOV_COS then
          -- Pick background colour based on state
          local bg = LABEL_BG
          if entry.destinationPos then
            local distToDest = (propPos - entry.destinationPos):length()
            if distToDest <= DELIVERY_RADIUS then
              bg = LABEL_BG_GREEN
            elseif destKey(entry.destination) == closestDestKey then
              bg = LABEL_BG_BLUE
            end
          end
          debugDrawer:drawTextAdvanced(
            propPos + vec3(0, 0, LABEL_Z_OFFSET),
            String(entry.label),
            LABEL_COLOR,
            true,
            false,
            bg
          )
        end
      end
    end
  end
end

-- ── update loop ───────────────────────────────────────────────────────────────
M.onUpdate = function(dt)
  if #trackedProps == 0 and #deliveryQueue == 0 then return end

  updateTimer = updateTimer - dt
  if updateTimer > 0 then return end
  updateTimer = UPDATE_INTERVAL

  local playerVehId = be:getPlayerVehicleID(0)
  local playerVeh   = playerVehId and scenetree.findObjectById(playerVehId)
  local playerPos   = playerVeh and vec3(playerVeh:getPosition())

  -- Step 1: detect arrived props, delete them, queue cargo
  for idx = #trackedProps, 1, -1 do
    local entry = trackedProps[idx]
    local propPos = getObjectPos(entry.propId)

    if not propPos then
      table.remove(trackedProps, idx)
    else
      if not entry.destinationPos then
        entry.destinationPos = getParkingSpotPos(entry.destination)
      end

      if entry.destinationPos then
        local distToDest = (propPos - entry.destinationPos):length()
        local inVehicle  = not gameplay_walk.isWalking()
        local playerGone = not playerPos
          or (playerPos - entry.destinationPos):length() > PLAYER_EXIT_RADIUS

        if distToDest <= DELIVERY_RADIUS and playerGone and inVehicle then
          log("I", "propCargo", string.format(
            "Prop %d arrived (dist=%.1fm), queuing %d cargo",
            entry.propId, distToDest, #entry.cargoIds))

          deleteProp(entry.propId)
          table.remove(trackedProps, idx)

          table.insert(deliveryQueue, {
            cargoIds    = entry.cargoIds,
            destination = entry.destination,
          })
        end
      end
    end
  end

  -- Step 2: process one queued delivery per tick (confirmDropOffData has re-entry guard)
  if #deliveryQueue > 0 then
    local item = table.remove(deliveryQueue, 1)
    local confirmedCargoIds = {}
    for _, id in ipairs(item.cargoIds) do
      table.insert(confirmedCargoIds, {id = id})
    end
    log("I", "propCargo", string.format(
      "Confirming %d cargo to %s/%s",
      #item.cargoIds, item.destination.facId, item.destination.psPath))
    dProgress.confirmDropOffData(
      { confirmedCargoIds = confirmedCargoIds, confirmedOfferIds = {} },
      item.destination.facId,
      item.destination.psPath
    )
  end
end

-- ── lifecycle ─────────────────────────────────────────────────────────────────
M.onDeliveryModeStopped = function()
  for _, entry in ipairs(trackedProps) do
    deleteProp(entry.propId)
  end
  table.clear(trackedProps)
  table.clear(deliveryQueue)
  updateTimer = 0
  log("I", "propCargo", "Delivery mode stopped - all props removed.")
end

M.getPropTasks = function()
  return deepcopy(trackedProps)
end

return M
