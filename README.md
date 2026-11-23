# GTNH_CropAutoTools
Tools for managing crops in GTNH 2.8

scanner.lua: initialise the robot's savestate memory (not necessary)\
manager.lua: mainly for farming and mutating selective seeds if you do not care about stats\
statmaxxing.lua: automatically get the best stats of a specific crop and dispose all byproducts

config.txt: configure the robot
format: <type>(bin/int/arr/str):<name>:<value>(or {<value1>,<value2>,<value3>,...} in case of arr type)
savestate.txt: permanent memory automatically managed to recover more easily after shutdown
