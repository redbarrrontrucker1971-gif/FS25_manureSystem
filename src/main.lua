--
-- main
--
-- Author: Stijn Wopereis
-- Description: loads the mod.
-- Name: main
-- Hide: yes
--
-- Copyright (c) Wopster, 2021

---@type string directory of the mod.
local modDirectory = g_currentModDirectory or ""
---@type string name of the mod.
local modName = g_currentModName or "unknown"
---@type ManureSystem the current loaded mod env.
local modEnvironment

print("[ManureSystem] ===== FS25 conversion build: v24 (Ray custom) loaded =====")

-- FS25: table.copy was removed from the sandboxed Lua environment; provide a shim so
-- the mod's few table.copy() calls keep working. Guarded so we never override a real
-- implementation if the game provides one.
if table.copy == nil then
    function table.copy(src, recursive)
        if src == nil then
            return nil
        end
        local dst = {}
        for k, v in pairs(src) do
            if recursive and type(v) == "table" then
                dst[k] = table.copy(v, recursive)
            else
                dst[k] = v
            end
        end
        return dst
    end
end

-- FS25: MathUtil.clamp was removed from the sandboxed environment (and a couple of
-- vector helpers may be gone too); restore any that are missing so the mod's math
-- keeps working. Guarded so we never override a real engine implementation.
MathUtil = MathUtil or {}
if MathUtil.clamp == nil then
    function MathUtil.clamp(value, minValue, maxValue)
        return math.max(minValue, math.min(maxValue, value))
    end
end
if MathUtil.vector2Length == nil then
    function MathUtil.vector2Length(x, z)
        return math.sqrt(x * x + z * z)
    end
end
if MathUtil.vector2LengthSq == nil then
    function MathUtil.vector2LengthSq(x, z)
        return x * x + z * z
    end
end
if MathUtil.vector3Length == nil then
    function MathUtil.vector3Length(x, y, z)
        return math.sqrt(x * x + y * y + z * z)
    end
end
if MathUtil.vector3Lerp == nil then
    function MathUtil.vector3Lerp(x1, y1, z1, x2, y2, z2, alpha)
        return x1 + (x2 - x1) * alpha, y1 + (y2 - y1) * alpha, z1 + (z2 - z1) * alpha
    end
end

---Loading order should be based on dependency order
---@type table<string> files to source.
local sourceFiles = {
    "src/insertion.lua",
    --Network
    "src/vehicles/events/ManureSystemPumpModeEvent.lua",
    "src/vehicles/events/ManureSystemPumpDirectionEvent.lua",
    "src/vehicles/events/ManureSystemPumpIsRunningEvent.lua",
    "src/vehicles/events/ManureSystemPumpIsAllowedEvent.lua",
    "src/placeables/events/ManureSystemThicknessEvent.lua",
    "src/placeables/events/ManureSystemMixerTurnedOnEvent.lua",
    "src/hose/events/HoseAttachDetachEvent.lua",
    "src/hose/events/HoseGrabDropEvent.lua",
    --Common
    "src/common/events/ManureSystemConnectorIsConnectedEvent.lua",
    "src/common/events/ManureSystemConnectorManureFlowEvent.lua",
    "src/common/strategies/ManureSystemCouplingStrategy.lua",
    "src/common/strategies/ManureSystemDockStrategy.lua",
    "src/common/ManureSystemConnectors.lua",
    "src/common/SharedSet.lua",
    "src/common/physics/FillPlaneRayCast.lua",
    --Misc
    "src/misc/ManureSystemConnectorManager.lua",
    "src/misc/ManureSystemFillArmManager.lua",
    --Hose
    "src/hose/HosePlayer.lua",
    --Utilities
    "src/utilities/NodeExtensions.lua",
    "src/utilities/XMLExtensions.lua",
    --Main
    "src/ManureSystem.lua",
    "src/overwrites.lua",
}

for _, file in ipairs(sourceFiles) do
    source(modDirectory .. file)
end

---Returns true when the current mod env is loaded, false otherwise.
local function isLoaded()
    return modEnvironment ~= nil and g_modIsLoaded[modName]
end

---Load the mod.
local function load(mission)
    assert(modEnvironment == nil)
    modEnvironment = ManureSystem.new(mission, g_inputBinding, g_soundManager, modDirectory, modName)
    mission.manureSystem = modEnvironment
    addModEventListener(modEnvironment)
end

---Unload the mod when the mod is unselected and savegame is (re)loaded or game is closed.
local function unload()
    if not isLoaded() then
        return
    end

    manureSystem_overwrite.resetOriginalFunctions()

    if modEnvironment ~= nil then
        removeModEventListener(modEnvironment)
        modEnvironment:delete()
        modEnvironment = nil -- GC

        if g_currentMission ~= nil then
            g_currentMission.manureSystem = nil
        end
    else
        ManureSystem.removeModTranslations(g_i18n)
    end
end

local function loadedMission(mission, node)
    if not isLoaded() then
        return
    end

    if mission.cancelLoading then
        return
    end

    mission.manureSystem:onMissionLoaded(mission)
end

local function loadFromXMLFile(mission)
    print(("[MS-LOAD-DIAG] loadFromXMLFile fired: isLoaded=%s isServer=%s"):format(tostring(isLoaded()), tostring(mission ~= nil and mission:getIsServer())))
    if isLoaded() and mission:getIsServer() then
        local missionInfo = mission.missionInfo
        if missionInfo.isValid then
            local xmlFilename = missionInfo.savegameDirectory .. "/manureSystem.xml"
            print(("[MS-LOAD-DIAG]   savegameDir=%s fileExists=%s"):format(tostring(missionInfo.savegameDirectory), tostring(fileExists(xmlFilename))))
            if missionInfo.savegameDirectory ~= nil and fileExists(xmlFilename) then
                -- FS25: items/placeables load asynchronously AFTER loadItemsFinished, so
                -- connectors are not registered yet here. Defer the reconnect into
                -- ManureSystem:update until connector registration has settled.
                modEnvironment.pendingLoadXmlFilename = xmlFilename
                modEnvironment.pendingLoadElapsed = 0
                modEnvironment.pendingLoadStableMs = 0
                modEnvironment.pendingLoadLastCount = -1
                print(("[MS-LOAD-DIAG]   deferring reconnect to update loop (file=%s)"):format(xmlFilename))
            end
        else
            print("[MS-LOAD-DIAG]   missionInfo not valid")
        end
    end
end

local function saveToXMLFile(missionInfo)
    if isLoaded() and missionInfo.isValid then
        modEnvironment:save(missionInfo.savegameDirectory .. "/manureSystem.xml")
    end
end

local function validateVehicleTypes(typeManager)
    if g_modIsLoaded[modName] then
        ManureSystem.addModTranslations(g_i18n)

        if typeManager.typeName == "vehicle" then
            ManureSystem.installVehicleSpecializations(typeManager, typeManager.specializationManager, modDirectory, modName)
        end

        if typeManager.typeName == "placeable" then
            ManureSystem.installPlaceableSpecializations(typeManager, typeManager.specializationManager, modDirectory, modName)
        end
    end
end

local function addFillTypeToCategory(fillTypeName, categoryName)
    local fillType = g_fillTypeManager:getFillTypeByName(fillTypeName:upper())
    local categoryIndex = g_fillTypeManager.nameToCategoryIndex[categoryName:upper()]
    if fillType ~= nil and categoryIndex ~= nil then
        if not g_fillTypeManager:addFillTypeToCategory(fillType.index, categoryIndex) then
            log(("Error: failed to add %s to %s"):format(fillTypeName, categoryName))
        end
    end
end

local function registerFillTypes()
    addFillTypeToCategory("water", "slurryTank")
end

--- Init the mod.
local function init()
    print(("[MS-LOAD-DIAG] init: Mission00.load=%s loadMission00Finished=%s loadItemsFinished=%s FSCareerMissionInfo.saveToXMLFile=%s"):format(tostring(Mission00.load ~= nil), tostring(Mission00.loadMission00Finished ~= nil), tostring(Mission00.loadItemsFinished ~= nil), tostring(FSCareerMissionInfo.saveToXMLFile ~= nil)))
    FSBaseMission.delete = Utils.appendedFunction(FSBaseMission.delete, unload)
    Mission00.load = Utils.prependedFunction(Mission00.load, load)
    Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, loadedMission)
    Mission00.loadItemsFinished = Utils.appendedFunction(Mission00.loadItemsFinished, loadFromXMLFile)
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, saveToXMLFile)
    TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, validateVehicleTypes)
    FillTypeManager.loadMapData = Utils.appendedFunction(FillTypeManager.loadMapData, registerFillTypes)

    manureSystem_overwrite.init()
end

init()

---Make modName globally available
g_manureSystemModName = modName -- Todo: look for better solution..
