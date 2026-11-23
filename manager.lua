-- initialisation
local robot = require "robot"
local component = require "component"
local computer = require "computer"
local geolyzer = component.geolyzer
local invcon = component.inventory_controller
local sides = require "sides"

-- read config
local config_file = io.open("config.txt", "r")
if not config_file then 
  print "error opening config.txt"
  os.exit()
end

local config = {}

for line in io.lines("config.txt") do
  local type, option, value = line:match("(%w+):(%w+):([%w%s_,{}]+)")
  if type == nil or option == nil or value == nil then goto continue end
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
  ::continue::
end
config_file:close()

local logging = config.logAction
local function log(msg)
  if logging then print(msg) end
end

log "loaded configurations"

local requiredConfig = {
  "fieldSize",
  "reserveCropStickSlots",
  "targetCropStorageSlots",
  "debugPlant",
  "usingCabinet",
  "logAction",
  "targetCrop",
  "Byproduct",
}

for _, v in pairs(requiredConfig) do
  if config[v] == nil then
    print("detected missing config param: "..v)
    os.exit()
  end
end

-- read savestate
local savestate_file_init = io.open("savestate.txt", "r") 
if not savestate_file_init then
  print "error opening savestate.txt"
  os.exit()
end
savestate_file_init:close()

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

for line in io.lines("savestate.txt") do
  local Xpos, Zpos, name, gain, growth, resist = string.match(line, "(%d+),(%d+):([%w ]+)|(%d+)|(%d+)|(%d+)")
  field[tonumber(Xpos)][tonumber(Zpos)] = {
    name = name,
    gain = tonumber(gain),
    growth = tonumber(growth),
    resist = tonumber(resist)
  }
end

log "loaded savestate"

local goodCrops = {}
goodCrops[config.targetCrop] = true
goodCrops["Crop"] = true -- for the crop item
for _, v in pairs(config.Byproduct) do
    goodCrops[v] = true
end

log "loaded crops configuration"

local cropstick_reserve = config.reserveCropStickSlots
local inv_size = robot.inventorySize()
local seedbag_storage_reserve = config.targetCropStorageSlots
local max_power = computer.maxEnergy()
local plant_seed_bypass = config.plantBypass or false

-- drop item in slot
local function dropSlot(slot)
  robot.select(slot)
  robot.dropDown()
end

-- fill of inventory except cropsticks
local function invFillExceptCropstick()
  local amt = 0
  for slot = cropstick_reserve, inv_size do
    if robot.count(slot) > 0 then
      amt = amt + 1
    end
  end
  return amt
end

-- refill cropsticks
local function sortCropsticks()
  local main_slot_count = robot.count(1)
  if main_slot_count < 64 then
    for slot = cropstick_reserve, 1, -1 do
      local can_move = robot.count(slot) - 1
      if can_move > 0 then
        robot.select(slot)
        robot.transferTo(1, can_move)
        main_slot_count = math.min(main_slot_count + can_move, 64)
      end

      if main_slot_count == 64 then break end
    end
  end
end

-- plant double cropsticks
local function plantDoubleCrop()
  -- replace with cropstick item then rightclick twice then replace with spade again
  robot.select(1)
  invcon.equip()

  robot.useDown(sides.up)
  robot.useDown(sides.up)

  invcon.equip()
end

-- scan crops
local function scanCrop()
  local info = geolyzer.analyze(sides.down)
  local crop_type = info["crop:name"]
  local block_type = info["name"]

  if not crop_type then
    if block_type == "IC2:blockCrop" then
        return {
          name = "cropstick",
          gain = 0,
          growth = 0,
          resist = 0
        }
    else
        return {
          name = "air",
          gain = 0,
          growth = 0,
          resist = 0
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

-- collect seeds
local function collectSeed()
  robot.useDown(sides.up)
end

-- dump useless items
local function dumpUseless()
  for slot = 1, inv_size do
    local slot_info = invcon.getStackInInternalSlot(slot)
    if slot_info then
      if slot_info.name == "IC2:itemCropSeed" or slot_info.name == "IC2:blockCrop" then
        local name = slot_info.label
        if name then
          local stripped = string.gsub(name, " Seeds", "")
          if not goodCrops[stripped] then
            -- remove crops not whitelisted
            dropSlot(slot)
          end
        else
          -- remove items with no name
          dropSlot(slot)
        end
      else
        -- remove non seed bags
        dropSlot(slot)
      end
    end
  end
  log "collected garbage"
end

-- check for breeding pair
local function isBreedingPair(Xpos, Zpos)
  if (Xpos + Zpos) % 2 ~= 0 then
      return true
  else
      return false
  end
end

-- check of seed planting can cease
local function plantSeedsBypassCheck()
  -- check if all possible seeds have been planted from savestate
  for X = 1, fieldSize do
    for Z = 1, fieldSize do
      if not isBreedingPair(X, Z) then
        local crop = field[X][Z]
        if crop.name == "cropstick" or crop.name == "air" then
          return false
        end
      end
    end
  end
  log "planting seeds bypassed"
  return true
end

-- check if this tile is a crop
local function isCrop(Xpos, Zpos)
  if Xpos < 1 or Xpos > fieldSize then return false end
  if Zpos < 1 or Zpos > fieldSize then return false end

  local crop = field[Xpos][Zpos]
  if crop.name ~= "air" and crop.name ~= "cropstick" then return true end
end

-- check if this spot can host a parent
local function isGoodSpotForParent(Xpos, Zpos)
  if isCrop(Xpos + 1, Zpos + 1) then return true end
  if isCrop(Xpos - 1, Zpos + 1) then return true end
  if isCrop(Xpos + 1, Zpos - 1) then return true end
  if isCrop(Xpos - 1, Zpos - 1) then return true end
  return false
end

-- check if this spot can host a child
local function isGoodSpotForChild(Xpos, Zpos)
  local Count = 0
  if isCrop(Xpos + 1, Zpos) then Count = Count + 1 end
  if isCrop(Xpos - 1, Zpos) then Count = Count + 1 end
  if isCrop(Xpos, Zpos - 1) then Count = Count + 1 end
  if isCrop(Xpos, Zpos + 1) then Count = Count + 1 end

  if Count >= 2 then return true end
  return false
end

-- return home
local function goBackEmergency(Xpos, Zpos)
  for X = Xpos, 2, -1 do
    robot.forward()
  end

  robot.turnLeft()

  for Z = Zpos, 2, -1 do
    robot.forward()
  end

  robot.turnLeft()
  robot.back()

  log "returned back to base"
end

-- check for collection interrupt params
local function collectInterruptCheck()
  log "checking for collection interruption"
  if invFillExceptCropstick() / (inv_size - cropstick_reserve) > 0.7 then
    -- garbage collection
    dumpUseless()
  end

  local curr_power = computer.energy()

  if curr_power / max_power < 0.25 then
    log "low power below 25%"
    return true
  end
  if robot.count(1) < 16 then
    log "lower than 16 cropsticks"
    return true
  end
  if invFillExceptCropstick() / (inv_size - cropstick_reserve) > 0.9 then
    log "inventory is 90% full"
    return true
  end

  return false
end

-- check for planting interrupt params
local function plantInterruptCheck()
  log "checking for planting interruption"
  local curr_power = computer.energy()
  if curr_power / max_power < 0.25 then
    log "low power below 25%"
    return true
  end
  if robot.count(1) < 16 then
    log "lower than 16 cropsticks"
    return true
  end

  return false
end

-- collect seed state
local function collectSeeds()
  log "collecting seeds"
  local Xpos, Zpos = 1, 1
  local moving_backward = false

  for i = 1, fieldSize do
    for j = 1, fieldSize do
      local scanned = scanCrop()
      if isBreedingPair(i, j) then
        -- collect seed
        if scanned.name == "air" then
          -- check if it is possible to plant if there are adjacent parents
          if isGoodSpotForChild(Xpos, Zpos) then
            plantDoubleCrop()
            field[Xpos][Zpos] = {
              name = "cropstick",
              gain = "0",
              growth = "0",
              resist = "0"
            }
          else
            field[Xpos][Zpos] = {
              name = "air",
              gain = "0",
              growth = "0",
              resist = "0"
            }
          end
        elseif scanned.name ~= "cropstick" then
          field[Xpos][Zpos] = {
            name = "cropstick",
            gain = "0",
            growth = "0",
            resist = "0"
          }

          collectSeed()
          plantDoubleCrop()
        end
      else
        field[Xpos][Zpos] = scanned
      end
      
      if j < fieldSize then
        robot.forward()
        if moving_backward then
          Xpos = Xpos - 1
        else
          Xpos = Xpos + 1
        end
      end
    end

    if collectInterruptCheck() then
      log "collection interrupted by params"
      if not moving_backward then
        robot.turnAround()
      end
      return true, Xpos, Zpos
    end

    sortCropsticks()

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

  robot.turnAround()
  for _ = 1, fieldSize - 1  do
    robot.forward()
  end

  robot.turnLeft()

  for _ = 1, fieldSize - 1 do
    robot.forward()
  end

  robot.turnLeft()
  robot.back()

  return false, 1, 1
end

-- plant seed state
local function plantSeeds()
  log "planting seeds"
  local Xpos, Zpos = 1, 1
  local moving_backward = false

  for i = 1, fieldSize do
    for j = 1, fieldSize do
      local scanned = scanCrop()
      if not isBreedingPair(i, j) and scanned.name == "air" and isGoodSpotForParent(Xpos, Zpos) then
        -- if the conditions are good then plant seeds
        local slot_select = 0
        local isthereanotherseed = false
        for slot = cropstick_reserve + 1, inv_size do
          if robot.count(slot) > 0 then
            slot_select = slot
            if not isthereanotherseed and slot_select ~= 0 then
              isthereanotherseed = true
              break
            end
          end
        end

        if slot_select > 0 then
          robot.select(1)
          invcon.equip() -- cropstick

          robot.useDown(sides.up)
          invcon.equip() -- spade

          robot.select(slot_select)
          invcon.equip() -- seed bag
          robot.useDown(sides.up)

          invcon.equip() -- spade
        end

        field[Xpos][Zpos] = scanCrop()

        if not isthereanotherseed then
          -- go back since there are no more seeds
          log "ran out of seeds, returning to base"
          if not moving_backward then
            robot.turnAround()
          end
          return true, Xpos, Zpos
        end
      else
        field[Xpos][Zpos] = scanned
      end

      if j < fieldSize then
        robot.forward()
        if moving_backward then
          Xpos = Xpos - 1
        else
          Xpos = Xpos + 1
        end
      end
    end

    if plantInterruptCheck() then
      log "planting seeds interrupted by params"
      if not moving_backward then
        robot.turnAround()
      end
      return true, Xpos, Zpos
    end

    sortCropsticks()

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

  robot.turnAround()
  for _ = 1, fieldSize - 1  do
    robot.forward()
  end

  robot.turnLeft()

  for _ = 1, fieldSize - 1 do
    robot.forward()
  end

  robot.turnLeft()
  robot.back()

  return false, 1, 1
end

-- inventory function at the end of every loop
local function manageInventory()
  log "managing inventory"
  -- stockpile cropstick
  robot.turnLeft()
  robot.forward()

  for slot = 1, cropstick_reserve do
    robot.select(slot)
    invcon.suckFromSlot(sides.down, slot, 64 - robot.count(slot))
  end

  log "collected cropsticks"
  
  -- dump useful seeds into chest
  robot.forward()
  local current_storage = 1
  local select_slot = cropstick_reserve + 1
  while select_slot <= inv_size do
    local item = invcon.getStackInInternalSlot(select_slot)
    if item then
      if item.name == "IC2:itemCropSeed" then
        if item.label == config.targetCrop.." Seeds" then
          -- useful seed
          robot.select(select_slot)
          if not robot.dropDown() then
            -- storage reserve is full, continue to next storage
            log "current storage reserve full"
            if current_storage == seedbag_storage_reserve then
              log "all storage reserves full"
              break
            else
              select_slot = select_slot - 1
              robot.forward()
              current_storage = current_storage + 1
              log "moved to next storage reserve"
            end
          end
        elseif current_storage == 1 then -- byproduct storage is above the robot
          -- check if byproduct
          local stripped = string.gsub(item.label, " Seeds", "")
          if goodCrops[stripped] then
            -- byproduct and not byproduct's own product
            robot.select(select_slot)
            if not robot.dropUp() then
              log "byproduct seeds storage reserve full"
            end
          end
        end
      end
    end

    select_slot = select_slot + 1
  end

  -- dump remaining items into trashcan above cropstick reserve
  robot.turnAround()
  for _ = 1, current_storage do
    robot.forward()
  end

  log "dumping items into trashcan"
  for slot = cropstick_reserve + 1, inv_size do
    robot.select(slot)
    robot.dropUp()
  end

  robot.forward()
  robot.turnLeft()
  
  log "finished managing inventory"
end

-- select the best seeds
local function selectSeedsInPattern()
  log "selecting seeds to plant"
  robot.turnLeft()
  robot.forward()

  local emptySlot = cropstick_reserve + 1
  local current_storage = 0
  for _ = 1, seedbag_storage_reserve do
    current_storage = current_storage + 1
    robot.forward()

    local size = invcon.getInventorySize(sides.down)
    local start, finish, inc = 1, size, 1
    if config.usingCabinet then
      start, finish, inc = size, 1, -1
    end

    for slot = start, finish, inc do
      local item = invcon.getStackInSlot(sides.down, slot)
      if item then
        if item.label == config.targetCrop.." Seeds" then
          robot.select(emptySlot)
          if invcon.suckFromSlot(sides.down, slot, 64) then
            emptySlot = emptySlot + 1
          end
        end
      end

      if emptySlot > inv_size then
        goto done
      end
    end
  end

  ::done::

  robot.turnAround()
  for _ = 1, current_storage + 1 do
    robot.forward()
  end

  robot.turnLeft()

  log "successfully selected seeds"
end

-- charge delay loop
local function recharge()
  log "recharging"
  -- max delay is 100 seconds
  for i = 0, 100 do
    local curr_power = computer.energy()
    if curr_power / max_power < 0.95 then
      os.sleep(1)
    else
      log "fully recharged"
      return
    end
  end
end

local function overwrite_savestate()
  local savestate_file = io.open("savestate.txt", "w") 
  if not savestate_file then
    print "error overwriting savestate.txt"
    os.exit()
  end
  
  local append_str = ""
  for X, Zarr in ipairs(field) do
    for Z, value in ipairs(Zarr) do
      local crop_str = value.name.."|"..value.gain.."|"..value.growth.."|"..value.resist
      append_str = append_str..X..","..Z..":"..crop_str.."\n"
    end
  end

  savestate_file:write(append_str)
  savestate_file:close()
  log "savestate overwritten"
end

-- main loop
while true do
  if not config.debugPlant then
    log "performing seed collection"
    robot.forward()
    local interrupted, Xpos, Zpos = collectSeeds()
    if interrupted then
      -- emergency go back
      goBackEmergency(Xpos, Zpos)
    end
  end

  recharge()
  manageInventory()

  if not plant_seed_bypass then
    -- perform seed planting
    log "performing seed planting"

    selectSeedsInPattern()
    robot.forward()
    local interrupted, Xpos, Zpos = plantSeeds()
    if interrupted then
      -- emergency go back
      goBackEmergency(Xpos, Zpos)
    end

    recharge()
    manageInventory()

    -- only check once per cycle if all fields with seeds are full
    if plantSeedsBypassCheck() then
      log "seed planting bypassed"
      plant_seed_bypass = true
    end
  end
  -- remember savestate
  overwrite_savestate()
end

-- MAIN SEQUENCE
-- collect seeds from field and replace copsticks
-- refill cropsticks / unload seeds / recharge
-- plant seeds on field (if necessary) and cropsticks (if necessary)
-- refill cropsticks / unload seeds / recharge
-- repeat

