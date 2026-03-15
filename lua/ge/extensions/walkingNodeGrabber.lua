local M = {}

local nodeGrabberActions = {"nodegrabberAction", "nodegrabberGrab", "nodegrabberRender", "nodegrabberStrength"}

local function updateNodeGrabber()
  if not core_input_actionFilter then return end

  local veh = getPlayerVehicle(0)
  if not veh then 
    return 
  end

  local onFoot = veh:getJBeamFilename() == "unicycle"
  core_input_actionFilter.setGroup("walkingNodeGrabberActions", nodeGrabberActions)
  core_input_actionFilter.addAction(0, "walkingNodeGrabberActions", not onFoot)
end

local function onUpdate()
  updateNodeGrabber()
end

M.onUpdate = onUpdate

return M