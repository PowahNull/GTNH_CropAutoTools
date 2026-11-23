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
  "logAction",
  "targetCrop",
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

local cropstick_reserve = config.reserveCropStickSlots
local inv_size = robot.inventorySize()
local seedbag_storage_reserve = config.targetCropStorageSlots
local max_power = computer.maxEnergy()


local internal_inv = {}
local top_empty_stack = cropstick_reserve + 1

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

-- refill cropsticks in internal inventory
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

-- check for breeding pair
local function isBreedingPair(Xpos, Zpos)
  if (Xpos + Zpos) % 2 ~= 0 then
      return true
  else
      return false
  end
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

-- ranks seeds and to see if this seed is better than the other for planting
local function seedRanking(gain, growth, resist)
  local rank = 0
  rank = rank + gain * 2
  rank = rank - resist * 3
  if growth <= 21 then
    rank = rank + growth * 5
  else
    -- very bad seed for planting as it can spread weeds
    rank = rank - 10000
  end

  return rank
end

-- ranks seed to see if it is good for using in an industrial farm
local function isSeedGood(gain, growth, resist)
  if gain < 31 then return false end
  if growth < 21 or growth > 23 then return false end
  if resist > 2 then return false end
  return true
end

-- scan slot and return true if successfully scanned item
local function scanSlot(slot)
  if robot.count(slot) > 0 then
    local item = invcon.getStackInInternalSlot(slot)
    if item == nil then
      internal_inv[slot] = nil
      return false
    end
    
    if item.name == "IC2:itemCropSeed" then
      local stats = item.crop
      internal_inv[slot] = {
        name = stats.name,
        gain = stats.gain,
        growth = stats.growth,
        resist = stats.resistance
      }
      return true
    else
      -- not a seed
      internal_inv[slot] = item.label
      return true
    end
  end
end

-- scan inventories serially until no more is found
local function rescanSerialInventory()
  while top_empty_stack <= inv_size do
    if scanSlot(top_empty_stack) then
      top_empty_stack = top_empty_stack + 1
    else
      break
    end
  end
end

-- get field worst seed
local function fieldWorstSeed()
  local minimum_value = 1000000
  for X = 1, fieldSize do
    for Z = 1, fieldSize do
      if not isBreedingPair(X, Z) then
        local crop = field[X][Z]
        if crop.name ~= "cropstick" and crop.name ~= "air" then
          local value = seedRanking(crop.gain, crop.growth, crop.resist)
          if value < minimum_value then minimum_value = value end
        end
      end
    end
  end

  return minimum_value
end

-- garbage collection (fairly intensive to run)
local function dumpGarbage()
  local function drop(slot)
    robot.select(slot)
        robot.dropDown()
        internal_inv[slot] = nil
  end

  local field_worst_ranking = fieldWorstSeed()
  for slot, item in pairs(internal_inv) do
    if slot > cropstick_reserve then
      if type(item) ~= "table" then
        -- not a seedbag so drop
        drop(slot)
      elseif item.name ~= config.targetCrop then
        -- not the ideal crop so drop
        drop(slot)
      elseif field_worst_ranking > seedRanking(item.gain, item.growth, item.resist) then
        -- very bad seed compared to field standard
        drop(slot)
      elseif not isSeedGood(item.gain, item.growth, item.resist) then
        -- not worth saving
        drop(slot)
      end
    end
  end

  -- compress items
  local free_slot = cropstick_reserve + 1
  local selected_slot = inv_size
  -- sort inventory
  while selected_slot > 0 and selected_slot > free_slot do
    if robot.count(selected_slot) > 0 then
      robot.select(selected_slot)
      ::unsuccessful::
      if robot.count(free_slot) == 0 then
        -- successful free slot transfer so move to next free slot
        robot.transferTo(free_slot, 64)
        internal_inv[free_slot] = internal_inv[selected_slot]
        internal_inv[selected_slot] = nil
        free_slot = free_slot + 1
      else
        -- unsuccessful free slot so continue to next free slot
        free_slot = free_slot + 1
        if selected_slot > free_slot then
          -- not full yet
          goto unsuccessful
        end
      end
    end
    -- move to next loose item
    selected_slot = selected_slot - 1
  end

  -- transfered all items
  top_empty_stack = cropstick_reserve + 1
  for slot, value in pairs(internal_inv) do
    if slot > top_empty_stack and value ~= nil then
      slot = top_empty_stack
    end
  end
  top_empty_stack = top_empty_stack + 1
end

-- check for general interrupt
local function interruptCheck()
  log "checking for interruption params"
  local curr_power = computer.energy()
  if curr_power / max_power < 0.25 then
    log "low power below 25%"
    return true
  end
  if robot.count(1) < 16 then
    log "lower than 16 cropsticks"
    return true
  end

  -- garbage collection
  if invFillExceptCropstick() / (inv_size - cropstick_reserve) > 0.5 then
    log "inventory is 75% full, performing garbage collection"
    dumpGarbage()
    if invFillExceptCropstick() / (inv_size - cropstick_reserve) > 0.75 then
      log "inventory is still 75% full after garbage collection"
      return true
    end
  end

  return false
end

-- replace slot slots after planting seed
local function replaceLostSlot(slot)
  -- replace lost slot
  local top_slot = top_empty_stack - 1
  if top_slot > cropstick_reserve then
    -- inventory is not empty
    robot.select(top_slot)
    if robot.transferTo(slot, 64) then
      -- moved item successfully
      scanSlot(slot)
      scanSlot(top_slot)
      top_empty_stack = top_slot
    end
    -- if this fails then there is a still a seed bag/item there
  end
end

-- plant on empty field
local function plantOnAir(slot)
  robot.select(1)
  invcon.equip() -- cropstick

  robot.useDown(sides.up)
  invcon.equip() -- spade

  robot.select(slot)
  invcon.equip() -- seed bag
  robot.useDown() -- plant seed

  invcon.equip() -- spade

  replaceLostSlot(slot)
end

-- plant on cropstick with seed or doublecropstick
local function plantOnCropstick(slot)
  -- destroy current plant or double cropstick
  robot.useDown()

  -- recheck inventory for picked up items
  rescanSerialInventory()

  robot.select(slot)
  invcon.equip() -- seed bag
  robot.useDown() -- plant seed

  invcon.equip() -- spade

  replaceLostSlot(slot)
end

-- select best seed
local function selectBestSeed()
  local slot_select = 0
  local best_value = -100000
  for slot, item in pairs(internal_inv) do
    if type(item) == "table" then
      -- check if it is a seed
      local rank = seedRanking(item.gain, item.growth, item.resist)
      if rank > best_value and item.name == config.targetCrop then
        -- if it is the target crop and best rank then select
        best_value = rank
        slot_select = slot
      end
    end
  end
  return slot_select, best_value
end

-- main work function
local function collectAndplantSeeds()
  log "collecting and planting seeds"
  robot.forward()
  local Xpos, Zpos = 1, 1
  local moving_backward = false

  for i = 1, fieldSize do
    for j = 1, fieldSize do
      local scanned = scanCrop()
      if isBreedingPair(Xpos, Zpos) then
        -- collect seed
        if scanned.name == "air" then
          if isGoodSpotForChild(Xpos, Zpos) then
            plantDoubleCrop()
          end
        else
          -- collect crop and replant
          robot.useDown(sides.up)
          plantDoubleCrop()
          -- check for picked up item
          rescanSerialInventory()
        end
        field[Xpos][Zpos] = scanCrop()
      else
        -- plant or replace crop
        local slot_select, seed_value = selectBestSeed()
        if scanned.name == "air" and isGoodSpotForParent(Xpos, Zpos) then
          -- if the conditions are good then simply plant the best seed
          if slot_select > 0 then
            -- has available seeds
            plantOnAir(slot_select)
            field[Xpos][Zpos] = scanCrop()
          end
        elseif scanned.name == "cropstick" or scanned.name == "Weed" then
          -- misplaced cropstick, plant seed or weed
          if slot_select > 0 then
            -- has available seeds
            plantOnCropstick(slot_select)
            field[Xpos][Zpos] = scanCrop()
          end
        else
          -- normal plant, must compare before replacing
          if slot_select > 0 then
            local crop_stat = scanCrop()
            local currentCropValue = seedRanking(crop_stat.gain, crop_stat.growth, crop_stat.resist)
            if seed_value > currentCropValue then
              -- worth replacing
              plantOnCropstick(slot_select)
              field[Xpos][Zpos] = scanCrop()
            else
              field[Xpos][Zpos] = crop_stat
            end
          end
        end
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

    sortCropsticks()

    log "checking for interruption params"
    if interruptCheck() then
      log "interrupted by params"
      if moving_backward then
        robot.turnAround()
      end
      goBackEmergency(Xpos, Zpos)
      return true, Xpos, Zpos
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

  -- finished scanning field so do one last garbage collection
  dumpGarbage()

  if moving_backward then
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
end

-- inventory function at the end of every loop
local function manageInventory()
  log "managing inventory"
  -- dump good seeds into above chest
  local needs_removal = {}
  local good_for_output = {}
  local minimum_value = fieldWorstSeed()
  for slot, seed in pairs(internal_inv) do
    if slot > cropstick_reserve then
      -- select the seeds better than other seeds in the field
      local rank = seedRanking(seed.gain, seed.growth, seed.resist)
      if rank > minimum_value then
        -- worth saving
        robot.select(slot)
        robot.dropUp()
        if robot.count(slot) > 0 then
          -- not fully transfered
          good_for_output[slot] = true
        end
      elseif isSeedGood(seed.gain, seed.growth, seed.resist) then
        -- also worth output
        good_for_output[slot] = true
      else
        needs_removal[slot] = true
      end
    end
  end
  log "dumped good seeds into good seeds chest"

  -- stockpile cropstick
  robot.turnLeft()
  robot.forward()

  for slot = 1, cropstick_reserve do
    robot.select(slot)
    invcon.suckFromSlot(sides.down, slot, 64 - robot.count(slot))
  end
  log "stockpiled cropsticks"

  -- dump bad seeds into trash can
  for slot, _ in pairs(needs_removal) do
    robot.select(slot)
    robot.dropUp()
  end
  log "dumped bad seeds into trash can"

  -- dump output seeds into output
  robot.forward()
  local current_storage = 1
  for slot, _ in pairs(good_for_output) do
    robot.select(slot)
    ::retry_seedbag_drop::
    robot.dropDown()
    if robot.count(slot) ~= 0 then
      -- not successfully dropped down, go to next one
      log "current seed storage is full, going to next seed storage"
      if current_storage < seedbag_storage_reserve then
        current_storage = current_storage + 1
        robot.forward()
        goto retry_seedbag_drop
      else
        -- storage is full
        log "all seed storage is full, returning home to dump seeds"
        break
      end
    end
  end
  
  -- finished dumping everything or all storage is full
  robot.turnAround()
  for _ = 1, current_storage do
    robot.forward()
  end
  log "dumped output seeds into output seeds storage"

  -- dump remaining seeds not sorted into output
  for slot = 1, inv_size do
    if robot.count(slot) > 0 then
      robot.select(slot)
      robot.dropUp()
    end
  end
  log "dumped remaining items into trashcan"

  robot.forward()
  robot.turnLeft()
  
  log "finished managing inventory"
end

-- select best seeds for planting
local function selectSeeds()
  log "selecting seeds to plant"
  while robot.suckUp(64) do
    -- nothing
  end
  log "successfully selected all seeds"
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

-- for saving savestate
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

-- init
rescanSerialInventory()

-- main loop
while true do
  collectAndplantSeeds()
  
  recharge()
  manageInventory()
  selectSeeds()

  overwrite_savestate()
end
