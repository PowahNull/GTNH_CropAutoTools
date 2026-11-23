local robot = require "robot"
local component = require "component"
local sides = require "sides"
local geolyzer = component.geolyzer

-- initialisation
local config_file = io.open("config.txt", "r")
if not config_file then 
  print "error opening config.txt"
  os.exit()
end

local config = {}

for line in io.lines("config.txt") do
  local type, option, value = line:match("(%w+):(%w+):([%w%s_,{}]+)")
  if type == "int" then
    config[option] = math.tointeger(tonumber(value))
  elseif type == "bin" then
    if value == "true" then
      config[option] = true
    else
      config[option] = false
    end
  elseif type == "str" then
    config[option] = value
  elseif type == "arr" then
    local arr = {}
    for split in value:gsub("^{", ""):gsub("}$", ""):gmatch("[^,]+") do
        table.insert(arr, split)
    end
    config[option] = arr
  end
end
config_file:close()

local logging = config.logAction
local function log(msg)
  if logging then print(msg) end
end

local requiredConfig = {
  "fieldSize",
  "logAction"
}

for _, v in pairs(requiredConfig) do
  if config[v] == nil then
    print("detected missing config param: "..v)
    os.exit()
  end
end

log "loaded configurations"

local savestate_file = io.open("savestate.txt", "w") 
if not savestate_file then
  print "error opening savestate.txt"
  os.exit()
end

log "opened savestate file"

local scanned = {}
local fieldSize = config.fieldSize

local field = {}
for x = 1, fieldSize do
  field[x] = {}
  for z = 1, fieldSize do
    field[x][z] = {
        name = "air",
        gain = "0",
        growth = "0",
        resist = "0"
      }
  end
end

local function scanCrop()
  local info = geolyzer.analyze(sides.down)
  local crop_type = info["crop:name"]
  local block_type = info["name"]

  if not crop_type then
    if block_type == "IC2:blockCrop" then
        return {
          name = "cropstick",
          gain = "0",
          growth = "0",
          resist = "0"
        }
    else
        return {
          name = "air",
          gain = "0",
          growth = "0",
          resist = "0"
        }
    end
  else
    return {
      name = crop_type,
      gain = info["crop:gain"],
      growth = info["crop:growth"],
      resist = info["crop:resistance"]
    }
  end
end

log "scanning field"

-- move to 1,1
robot.forward()

local moving_backward = false
local Xpos = 1
local Zpos = 1

for i = 1, fieldSize do
  for j = 1, fieldSize do
    scanned[Xpos][Zpos] = scanCrop()
    if j < fieldSize then
      robot.forward()
      if moving_backward then
        Xpos = Xpos - 1
      else
        Xpos = Xpos + 1
      end
    end  
  end

  -- scan next row in reverse
  if i < fieldSize then
    if moving_backward then
      robot.turnRight()
      robot.forward()
      robot.turnRight()
    else
      robot.turnLeft()
      robot.forward()
      robot.turnLeft()
    end
  end

  Zpos = Zpos + 1
  moving_backward = not moving_backward
end

if not moving_backward then
  robot.turnAround()
end

for _ = 1, fieldSize - 1  do
  robot.forward()
end

robot.turnLeft()

for _ = 1, fieldSize - 1 do
  robot.forward()
end

robot.turnLeft()
robot.back()

log "finished scanning field"

local append_str = ""
for X, Zarr in ipairs(scanned) do
  for Z, value in ipairs(Zarr) do
    local crop_str = value.name.."|"..value.gain.."|"..value.growth.."|"..value.resist
    append_str = append_str..X..","..Z..":"..crop_str.."\n"
  end
end

savestate_file:write(append_str)
savestate_file:close()
log "finished saving scan to savestate"
