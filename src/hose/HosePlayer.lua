--
-- HosePlayer
--
-- Author: Stijn Wopereis
-- Description: Injection class to handle all the hose interactions with the player.
-- Name: HosePlayer
-- Hide: yes
--
-- Copyright (c) Wopster, 2019 - 2023

---@class HosePlayer
HosePlayer = {}

local HosePlayer_mt = Class(HosePlayer)

-- Master feature flag for the FS25 on-foot hose interaction. Set to false (or set a
-- global g_manureSystemDisableFS25Hose = true before load) to fully skip the FS25
-- install so the mod still loads cleanly if this prototype misbehaves.
HosePlayer.FS25_HOSE_ENABLED = true

function HosePlayer.new(isClient, isServer, mission, input)
    local self = setmetatable({}, HosePlayer_mt)

    self.isClient = isClient
    self.isServer = isServer
    self.mission = mission
    self.input = input

    -- Prefer the FS25 component API when it is available. FS25 still exposes
    -- several legacy-looking Player/PlayerState symbols, so testing the old API
    -- first can incorrectly select the FS22 path and silently disable all on-foot
    -- hose prompts.
    local hasFS25PlayerApi = Player ~= nil
        and Player.update ~= nil
        and PlayerInputComponent ~= nil
        and PlayerInputComponent.registerActionEvents ~= nil

    if hasFS25PlayerApi then
        if HosePlayer.FS25_HOSE_ENABLED == false or g_manureSystemDisableFS25Hose == true then
            print("[MS-HOSE-FS25] FS25 player API detected but on-foot hose interaction is DISABLED via feature flag; skipping install (build v23).")
            return self
        end
        print("[MS-HOSE-FS25] FS25 player API detected; installing on-foot hose interaction prototype (build v23).")
        HosePlayer.installFS25(self)
        return self
    end

    -- Fall back to the original FS22 hooks only when the FS25 component API is
    -- absent and the complete legacy API is present.
    local hasLegacyPlayerApi = Player ~= nil
        and PlayerStateThrow ~= nil and PlayerStatePickup ~= nil
        and PlayerStateWalk ~= nil and PlayerStateRun ~= nil
        and Player.pickUpObject ~= nil and Player.checkObjectInRange ~= nil

    if not hasLegacyPlayerApi then
        print("[MS-HOSE-FS25] No supported player interaction API found; on-foot hose interaction is unavailable.")
        return self
    end

    Player.readUpdateStream = Utils.appendedFunction(Player.readUpdateStream, HosePlayer.inj_player_readUpdateStream)
    Player.writeUpdateStream = Utils.appendedFunction(Player.writeUpdateStream, HosePlayer.inj_player_writeUpdateStream)
    Player.update = Utils.appendedFunction(Player.update, HosePlayer.inj_player_update)
    Player.onLeave = Utils.appendedFunction(Player.onLeave, HosePlayer.inj_player_onLeave)

    Player.updateActionEvents = Utils.appendedFunction(Player.updateActionEvents, HosePlayer.inj_player_updateActionEvents)
    Player.registerActionEvents = Utils.prependedFunction(Player.registerActionEvents, HosePlayer.inj_player_registerActionEvents)

    Player.pickUpObject = Utils.overwrittenFunction(Player.pickUpObject, HosePlayer.inj_player_pickUpObject)

    Player.checkObjectInRange = Utils.overwrittenFunction(Player.checkObjectInRange, HosePlayer.inj_player_checkObjectInRange)
    PlayerStateThrow.isAvailable = Utils.overwrittenFunction(PlayerStateThrow.isAvailable, HosePlayer.inj_playerStateThrow_isAvailable)
    PlayerStatePickup.isAvailable = Utils.overwrittenFunction(PlayerStatePickup.isAvailable, HosePlayer.inj_playerStatePickup_isAvailable)

    PlayerStateWalk.isAvailable = Utils.overwrittenFunction(PlayerStateWalk.isAvailable, HosePlayer.inj_playerStateWalk_isAvailable)
    PlayerStateRun.isAvailable = Utils.overwrittenFunction(PlayerStateRun.isAvailable, HosePlayer.inj_playerStateWalk_isAvailable)

    return self
end

function HosePlayer:delete()
end

function HosePlayer.inj_player_readUpdateStream(player, streamId, timestamp, connection)
    if connection:getIsServer() then
        player.lastFoundObjectIsHose = streamReadBool(streamId)
        player.lastFoundHoseIsConnected = streamReadBool(streamId)

        if player.lastFoundObjectIsHose then
            player.lastFoundHose = NetworkUtil.readNodeObjectId(streamId)
            player.lastFoundGradNodeId = streamReadUIntN(streamId, Hose.GRAB_NODES_SEND_NUM_BITS) + 1
        end
    end

end
function HosePlayer.inj_player_writeUpdateStream(player, streamId, connection, dirtyMask)
    if not connection:getIsServer() then
        streamWriteBool(streamId, player.lastFoundObjectIsHose)
        streamWriteBool(streamId, player.lastFoundHoseIsConnected)

        if player.lastFoundObjectIsHose then
            NetworkUtil.writeNodeObjectId(streamId, player.lastFoundHose)
            streamWriteUIntN(streamId, player.lastFoundGradNodeId - 1, Hose.GRAB_NODES_SEND_NUM_BITS)
        end
    end
end

function HosePlayer.inj_player_update(player, dt)
    if player.isServer then
        if player.hoseGrabNodeId ~= nil then
            local hose = NetworkUtil.getObject(player.lastFoundHose)
            hose:findConnector(player.hoseGrabNodeId)
            player.hoseIsRestricting = hose:restrictPlayerMovement(player.hoseGrabNodeId, player)

            if player.hoseIsRestricting then
                player.playerStateMachine:deactivateState("walk")
                player.playerStateMachine:deactivateState("run")
                player.playerStateMachine:activateState("idle")
            end
        end
    end
end

function HosePlayer.inj_player_onLeave(player)
    if player.isServer and player.lastFoundObjectIsHose then
        local hose = NetworkUtil.getObject(player.lastFoundHose)
        if player.hoseGrabNodeId ~= nil then
            hose:drop(player.hoseGrabNodeId, player)
        end
    end
end

function HosePlayer.inj_player_updateActionEvents(player)
    local eventList = player.inputInformation.registrationList
    local function disableInput(inputAction)
        -- Check if the input exists in order to prevent callstacks with mods that load dummy players (e.g. ContractorMod).
        if eventList[inputAction] ~= nil then
            local event = eventList[inputAction]
            local id = event.eventId
            g_inputBinding:setActionEventActive(id, false)
            g_inputBinding:setActionEventTextVisibility(id, false)
        end
    end

    local function enableInput(inputAction, forcePriority)
        local event = eventList[inputAction]
        local id = event.eventId
        g_inputBinding:setActionEventActive(id, true)
        g_inputBinding:setActionEventTextVisibility(id, event.textVisibility)

        if forcePriority then
            g_inputBinding:setActionEventTextPriority(id, GS_PRIO_HIGH)
        end
    end

    disableInput(InputAction.MS_ATTACH_HOSE)
    disableInput(InputAction.MS_DETACH_HOSE)
    disableInput(InputAction.MS_TOGGLE_FLOW)

    if player.hoseIsRestricting then
        disableInput(InputAction.AXIS_MOVE_FORWARD_PLAYER)
        disableInput(InputAction.AXIS_RUN)
    else
        enableInput(InputAction.AXIS_MOVE_FORWARD_PLAYER)
        enableInput(InputAction.AXIS_RUN)
    end

    if player.lastFoundObjectIsHose then
        local hose = NetworkUtil.getObject(player.lastFoundHose)

        if hose ~= nil then
            local spec = hose.spec_hose
            local grabNode = hose:getGrabNodeById(player.lastFoundGradNodeId)

            if hose:isAttached(grabNode) and spec.foundConnectorId ~= 0 and not spec.foundConnectorIsConnected then
                enableInput(InputAction.MS_ATTACH_HOSE, true)
                local event = eventList[InputAction.MS_ATTACH_HOSE]
                local text = spec.foundConnectorIsParkPlace and g_i18n:getText("action_storeHose") or event.text
                g_inputBinding:setActionEventText(event.eventId, text)
            elseif hose:isConnected(grabNode) then
                local desc = spec.grabNodesToObjects[grabNode.id]
                if desc ~= nil then
                    local object = desc.vehicle
                    local connector = object:getConnectorById(desc.connectorId)
                    local hasManureFlowControl = connector.manureFlowAnimationName ~= nil or connector.manureFlowAnimationIndex ~= nil
                    local animationName = connector.manureFlowAnimationName ~= nil and connector.manureFlowAnimationName or connector.manureFlowAnimationIndex

                    if hasManureFlowControl then
                        enableInput(InputAction.MS_TOGGLE_FLOW, true)
                        local state = object:getAnimationTime(animationName) == 0
                        local text = state and g_i18n:getText("action_toggleManureFlowStateOpen") or g_i18n:getText("action_toggleManureFlowStateClose")
                        local id = eventList[InputAction.MS_TOGGLE_FLOW].eventId

                        g_inputBinding:setActionEventText(id, g_i18n:getText("action_toggleManureFlow"):format(text))
                    end

                    if not hasManureFlowControl or not connector.hasOpenManureFlow then
                        enableInput(InputAction.MS_DETACH_HOSE, true)
                    end
                end
            end
        end
    end
end

function HosePlayer.inj_player_registerActionEvents(player)
    player.inputInformation.registrationList[InputAction.MS_ATTACH_HOSE] = { eventId = "", callback = Player.actionEventOnAttachHose, triggerUp = false, triggerDown = true, triggerAlways = false, activeType = Player.INPUT_ACTIVE_TYPE.STARTS_DISABLED, callbackState = nil, text = g_i18n:getText("input_MS_ATTACH_HOSE"), textVisibility = true }
    player.inputInformation.registrationList[InputAction.MS_DETACH_HOSE] = { eventId = "", callback = Player.actionEventOnDetachHose, triggerUp = false, triggerDown = true, triggerAlways = false, activeType = Player.INPUT_ACTIVE_TYPE.STARTS_DISABLED, callbackState = nil, text = g_i18n:getText("input_MS_DETACH_HOSE"), textVisibility = true }
    player.inputInformation.registrationList[InputAction.MS_TOGGLE_FLOW] = { eventId = "", callback = Player.actionEventOnToggleFlow, triggerUp = false, triggerDown = true, triggerAlways = false, activeType = Player.INPUT_ACTIVE_TYPE.STARTS_DISABLED, callbackState = nil, text = g_i18n:getText("input_MS_TOGGLE_FLOW"), textVisibility = true }
end

function HosePlayer.inj_player_pickUpObject(player, superFunc, grab, noEventSend)
    if player.isServer and player.lastFoundObjectIsHose then
        local hose = NetworkUtil.getObject(player.lastFoundHose)
        local grabNode = hose:getGrabNodeById(player.lastFoundGradNodeId)

        if grab and not hose:isConnected(grabNode) then
            hose:grab(grabNode.id, player)
        elseif player.hoseGrabNodeId ~= nil then
            hose:drop(player.hoseGrabNodeId, player)
        end
    else
        superFunc(player, grab, noEventSend)
    end
end

function HosePlayer.inj_player_checkObjectInRange(player, superFunc)
    local canHandleCheck = player.isControlled and player.isServer and not player.isCarryingObject

    if canHandleCheck then
        player.lastFoundHose = nil
        player.lastFoundGradNodeId = 0
        player.lastFoundObjectIsHose = false
        player.lastFoundHoseIsConnected = false
    end

    superFunc(player)

    if canHandleCheck then
        if player.lastFoundObject ~= nil then
            local object = g_currentMission:getNodeObject(player.lastFoundObject)
            if object ~= nil
                and object.isaHose ~= nil
                and object:isaHose() then

                local grabNode = object:getClosestGrabNode(unpack(player.lastFoundObjectHitPoint))
                local isConnected = object:isConnected(grabNode)
                if object:isDetached(grabNode) or isConnected then
                    player.lastFoundHose = NetworkUtil.getObjectId(object)
                    player.lastFoundGradNodeId = grabNode.id
                    player.lastFoundObjectIsHose = true
                    player.lastFoundHoseIsConnected = isConnected
                else
                    player.lastFoundHose = nil
                    player.lastFoundGradNodeId = 0
                    player.lastFoundObject = nil
                    player.lastFoundObjectHitPoint = nil
                    player.isObjectInRange = false
                end

                -- we raise active in order to trigger functions on the hose.
                --object:raiseHoseActive()
            end
        end
    end
end

function HosePlayer.inj_playerStateThrow_isAvailable(state, superFunc)
    if state.player.lastFoundObjectIsHose then
        return false
    end

    return superFunc(state)
end

function HosePlayer.inj_playerStatePickup_isAvailable(state, superFunc)
    local player = state.player
    if player.lastFoundObjectIsHose and player.lastFoundHoseIsConnected then
        return false
    end

    return superFunc(state)
end

function HosePlayer.inj_playerStateWalk_isAvailable(state, superFunc)
    local player = state.player
    local hose = NetworkUtil.getObject(player.lastFoundHose)

    if hose ~= nil and player.hoseGrabNodeId ~= nil then
        if player.hoseIsRestricting then
            return false
        end
    end

    return superFunc(state)
end

---- Add action event functions to the player class.
function Player.actionEventOnAttachHose(self, actionName, inputValue, callbackState, isAnalog)
    if self.lastFoundObjectIsHose then
        local hose = NetworkUtil.getObject(self.lastFoundHose)

        if hose ~= nil then
            local spec = hose.spec_hose
            local grabNode = hose:getGrabNodeById(self.lastFoundGradNodeId)

            if hose:isAttached(grabNode) then
                if spec.foundConnectorId ~= 0 and spec.foundVehicleId ~= 0 and not spec.foundConnectorIsConnected then
                    hose:attach(grabNode.id, spec.foundConnectorId, NetworkUtil.getObject(spec.foundVehicleId))
                end
            end
        end
    end
end

function Player.actionEventOnDetachHose(self, actionName, inputValue, callbackState, isAnalog)
    if self.lastFoundObjectIsHose then
        local hose = NetworkUtil.getObject(self.lastFoundHose)

        if hose ~= nil then
            local spec = hose.spec_hose
            local grabNode = hose:getGrabNodeById(self.lastFoundGradNodeId)

            if hose:isConnected(grabNode) then
                local desc = spec.grabNodesToObjects[grabNode.id]
                if desc ~= nil then
                    hose:detach(grabNode.id, desc.connectorId, desc.vehicle)
                end
            end
        end
    end
end

function Player.actionEventOnToggleFlow(self, actionName, inputValue, callbackState, isAnalog)
    if self.lastFoundObjectIsHose then
        local hose = NetworkUtil.getObject(self.lastFoundHose)

        if hose ~= nil then
            local spec = hose.spec_hose
            local grabNode = hose:getGrabNodeById(self.lastFoundGradNodeId)

            if hose:isConnected(grabNode) then
                local desc = spec.grabNodesToObjects[grabNode.id]
                if desc ~= nil then
                    local vehicle = desc.vehicle
                    local connector = vehicle:getConnectorById(desc.connectorId)
                    local hasManureFlowControl = connector.manureFlowAnimationName ~= nil or connector.manureFlowAnimationIndex ~= nil
                    local animationName = connector.manureFlowAnimationName ~= nil and connector.manureFlowAnimationName or connector.manureFlowAnimationIndex

                    if hasManureFlowControl and not vehicle:getIsAnimationPlaying(animationName) then
                        vehicle:setIsManureFlowOpen(desc.connectorId, not connector.hasOpenManureFlow, false)
                    end
                end
            end
        end
    end
end

-- ============================================================================
-- FS25 on-foot hose interaction (build v23, Ray custom).
--
-- The FS25 player is component-based, so the FS22 hooks above (PlayerStatePickup,
-- Player.checkObjectInRange, Player.pickUpObject, player.playerStateMachine) do not
-- exist. This section rebuilds the interaction against the FS25 model:
--   * detection -> aim raycast using the PROVEN FS25 raycastAll signature
--                  (origin, dir, maxDist, callbackName, target, mask, true) as used
--                  by FillPlaneRayCast. The aim ray comes from
--                  PlayerTargeter:getLookRay() when available, else player:getLookRay().
--   * per-frame -> appended Player.update (local, controlled player only).
--   * input     -> appended PlayerInputComponent.registerActionEvents.
--   * grab joint-> Hose:grab() already resolves the FS25 kinematic helper via
--                  player.hands:getKinematicNode(), so no extra joint work is needed here.
--
-- BLIND-PORT NOTE: there is no public FS25 reference for this yet, so the exact
-- PlayerTargeter / Hands / PlayerInputComponent API is UNVERIFIED. On the first
-- Player.update we dump a one-time [MS-HOSE-FS25][PROBE] inventory of the real
-- runtime APIs so the next build can commit to whatever actually exists. Everything
-- is feature-flagged and pcall/nil guarded: a missing API logs once and no-ops
-- instead of freezing the game (the v1 failure mode). Multiplayer netsync and the
-- hose-length movement restriction are intentionally deferred for this prototype.
-- ============================================================================

HosePlayer.LOG = "[MS-HOSE-FS25]"
HosePlayer.FS25_TARGET_MAX_DISTANCE = 5.0

-- Scratch state for the aim raycast (single-player: one cast per frame).
HosePlayer._ray = { node = 0, dist = math.huge, x = 0, y = 0, z = 0 }

--------------------------------------------------------------------------------
-- Local-player gate (tolerant: FS25 field names are unverified)
--------------------------------------------------------------------------------
function HosePlayer.fs25_isLocalActive(player)
    -- If isOwner/isControlled are absent (nil), do NOT hard-block -- fall back to
    -- running so the prototype still has a chance; the [PROBE] block reports the
    -- real values for the next build. Only an explicit false excludes the player.
    local owner = player.isOwner
    local controlled = player.isControlled
    if owner == false then
        return false
    end
    if controlled == false then
        return false
    end
    return true
end

--------------------------------------------------------------------------------
-- Install
--------------------------------------------------------------------------------
function HosePlayer.installFS25(self)
    Player.update = Utils.appendedFunction(Player.update, HosePlayer.fs25_playerUpdate)

    if PlayerInputComponent ~= nil and PlayerInputComponent.registerActionEvents ~= nil then
        PlayerInputComponent.registerActionEvents = Utils.appendedFunction(PlayerInputComponent.registerActionEvents, HosePlayer.fs25_registerActionEvents)
        if PlayerInputComponent.unregisterActionEvents ~= nil then
            PlayerInputComponent.unregisterActionEvents = Utils.appendedFunction(PlayerInputComponent.unregisterActionEvents, HosePlayer.fs25_unregisterActionEvents)
        end
        print(HosePlayer.LOG .. " installFS25: hooked Player.update + PlayerInputComponent.registerActionEvents (build v23).")
    else
        print(HosePlayer.LOG .. " installFS25: PlayerInputComponent(.registerActionEvents) NOT found -- hose prompts unavailable, but the Player.update detection hook + API probe are still active (build v23).")
    end
end

--------------------------------------------------------------------------------
-- One-time runtime API probe (the key diagnostic for this blind port)
--------------------------------------------------------------------------------
local function yn(v)
    if v == nil or v == false then
        return "no"
    end
    return "yes"
end

function HosePlayer.fs25_typeList(packed)
    -- packed[1] is the pcall ok flag; describe the value types after it.
    local parts = {}
    for i = 2, #packed do
        parts[#parts + 1] = type(packed[i])
    end
    return #parts > 0 and table.concat(parts, "/") or "(none)"
end

function HosePlayer.fs25_probe(player)
    local L = HosePlayer.LOG .. "[PROBE]"

    print(L .. " ===== FS25 player API inventory (build v23) =====")
    print((L .. " player flags: isOwner=%s isControlled=%s isServer=%s isClient=%s rootNode=%s")
        :format(tostring(player.isOwner), tostring(player.isControlled), tostring(player.isServer), tostring(player.isClient), yn(player.rootNode)))

    -- Top-level field names on the player (reveals the real component field names).
    pcall(function()
        local keys = {}
        for k in pairs(player) do
            if type(k) == "string" then
                keys[#keys + 1] = k
            end
        end
        table.sort(keys)
        print(L .. " player fields: " .. table.concat(keys, ", "))
    end)

    -- targeter + candidate methods
    local t = player.targeter
    print(L .. " player.targeter=" .. yn(t))
    if t ~= nil then
        local m = {}
        for _, name in ipairs({ "getLookRay", "getClosestTargetedNodeFromType", "addTargetType", "addFilterToTargetType", "removeTargetType", "raycast", "getTarget", "getClosestTarget", "update" }) do
            if t[name] ~= nil then
                m[#m + 1] = name
            end
        end
        print(L .. " targeter methods present: " .. (#m > 0 and table.concat(m, ", ") or "(none of the probed names)"))
        if t.getLookRay ~= nil then
            local r = { pcall(function() return t:getLookRay() end) }
            print((L .. " targeter:getLookRay() ok=%s returns=%d types=%s")
                :format(tostring(r[1]), #r - 1, HosePlayer.fs25_typeList(r)))
        end
    end

    -- hands + candidate methods
    local h = player.hands
    print(L .. " player.hands=" .. yn(h))
    if h ~= nil then
        local m = {}
        for _, name in ipairs({ "getKinematicNode", "getHeldObject", "pickUpObject", "drop", "isCarrying", "getCarriedObject" }) do
            if h[name] ~= nil then
                m[#m + 1] = name
            end
        end
        print(L .. " hands methods present: " .. (#m > 0 and table.concat(m, ", ") or "(none of the probed names)"))
    end

    -- model (FS22 kinematic helper source)
    print(L .. " player.model=" .. yn(player.model) .. " model:getKinematicHelpers=" .. yn(player.model ~= nil and player.model.getKinematicHelpers))

    -- candidate camera / aim nodes
    print((L .. " camera fields: player.camera=%s player.cameraNode=%s player.graphicsRootNode=%s")
        :format(yn(player.camera), yn(player.cameraNode), yn(player.graphicsRootNode)))

    -- global classes
    print((L .. " globals: PlayerInputComponent=%s PlayerTargeter=%s Hands=%s HandsPickUpObjectEvent=%s")
        :format(yn(PlayerInputComponent), yn(PlayerTargeter), yn(Hands), yn(HandsPickUpObjectEvent)))
    if PlayerInputComponent ~= nil then
        print(L .. " PlayerInputComponent.INPUT_CONTEXT_NAME=" .. tostring(PlayerInputComponent.INPUT_CONTEXT_NAME))
    end

    -- collision constants used for the aim mask
    if CollisionFlag ~= nil then
        print((L .. " CollisionFlag: VEHICLE=%s DYNAMIC_OBJECT=%s PLAYER=%s PLAYER_KINEMATIC=%s")
            :format(tostring(CollisionFlag.VEHICLE), tostring(CollisionFlag.DYNAMIC_OBJECT), tostring(CollisionFlag.PLAYER), tostring(CollisionFlag.PLAYER_KINEMATIC)))
    else
        print(L .. " CollisionFlag=nil (aim mask will fall back to raycast default)")
    end
    print(L .. " ===== end inventory =====")
end

--------------------------------------------------------------------------------
-- Action events
--------------------------------------------------------------------------------
function HosePlayer.fs25_registerActionEvents(inputComponent)
    local player = inputComponent.player
    if player == nil or not HosePlayer.fs25_isLocalActive(player) then
        return
    end

    player.msHoseActionEvents = {}

    local registered = 0
    local ok, err = pcall(function()
        local contextName = PlayerInputComponent ~= nil and PlayerInputComponent.INPUT_CONTEXT_NAME or nil
        if contextName ~= nil then
            g_inputBinding:beginActionEventsModification(contextName)
        end

        local function reg(action, callback)
            if action == nil then
                return
            end
            local _, eventId = g_inputBinding:registerActionEvent(action, inputComponent, callback, false, true, false, true, nil, true)
            g_inputBinding:setActionEventActive(eventId, false)
            g_inputBinding:setActionEventTextVisibility(eventId, false)
            player.msHoseActionEvents[action] = eventId
            registered = registered + 1
        end

        reg(InputAction.MS_ATTACH_HOSE, HosePlayer.fs25_onAttach)
        reg(InputAction.MS_DETACH_HOSE, HosePlayer.fs25_onDetach)
        reg(InputAction.MS_TOGGLE_FLOW, HosePlayer.fs25_onToggleFlow)

        if contextName ~= nil then
            g_inputBinding:endActionEventsModification()
        end
    end)

    if ok then
        print((HosePlayer.LOG .. " registerActionEvents: registered %d hose action event(s) for the local player."):format(registered))
    else
        print(HosePlayer.LOG .. " registerActionEvents ERROR (hose prompts unavailable): " .. tostring(err))
    end
end

function HosePlayer.fs25_unregisterActionEvents(inputComponent)
    local player = inputComponent.player
    if player == nil then
        return
    end
    player.msHoseActionEvents = nil
end

function HosePlayer.fs25_setActionActive(player, action, active, text)
    local events = player.msHoseActionEvents
    if events == nil or action == nil then
        return
    end
    local eventId = events[action]
    if eventId == nil then
        return
    end
    g_inputBinding:setActionEventActive(eventId, active)
    g_inputBinding:setActionEventTextVisibility(eventId, active)
    if active and text ~= nil then
        g_inputBinding:setActionEventText(eventId, text)
        g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_HIGH)
    end
end

--------------------------------------------------------------------------------
-- Per-frame update
--------------------------------------------------------------------------------
function HosePlayer.fs25_playerUpdate(player, dt)
    -- Dump the API inventory once, BEFORE the local-player gate, so we always get a
    -- probe even if isOwner/isControlled turn out to be nil/false in FS25.
    if not HosePlayer._probedOnce then
        HosePlayer._probedOnce = true
        pcall(HosePlayer.fs25_probe, player)
    end

    if not HosePlayer.fs25_isLocalActive(player) then
        return
    end

    local ok, err = pcall(HosePlayer.fs25_playerUpdateInternal, player, dt)
    if not ok and not player.msLoggedUpdateError then
        player.msLoggedUpdateError = true
        print(HosePlayer.LOG .. " update error (further errors suppressed): " .. tostring(err))
    end
end

function HosePlayer.fs25_playerUpdateInternal(player, dt)
    -- Clear all hose prompts each frame; re-enable contextually below.
    HosePlayer.fs25_setActionActive(player, InputAction.MS_ATTACH_HOSE, false)
    HosePlayer.fs25_setActionActive(player, InputAction.MS_DETACH_HOSE, false)
    HosePlayer.fs25_setActionActive(player, InputAction.MS_TOGGLE_FLOW, false)

    -- Carrying a loose hose end: keep its reference and hunt for connectors.
    if player.hoseGrabNodeId ~= nil and player.msCarriedHoseId ~= nil then
        local hose = NetworkUtil.getObject(player.msCarriedHoseId)
        if hose ~= nil then
            hose:findConnector(player.hoseGrabNodeId)
            HosePlayer.fs25_updateCarriedPrompts(player, hose)
        end
        return
    end

    -- Not carrying: aim-raycast for a hose end.
    player.lastFoundHose = nil
    player.lastFoundGradNodeId = 0
    player.lastFoundObjectIsHose = false
    player.lastFoundHoseIsConnected = false

    local node, hx, hy, hz = HosePlayer.fs25_raycastHose(player)
    if node == nil then
        return
    end

    local object = g_currentMission:getNodeObject(node)
    if object == nil or object.isaHose == nil or not object:isaHose() then
        return
    end

    local grabNode = object:getClosestGrabNode(hx, hy, hz)
    if grabNode == nil then
        return
    end

    local isConnected = object:isConnected(grabNode)
    if not (object:isDetached(grabNode) or isConnected) then
        return
    end

    player.lastFoundHose = NetworkUtil.getObjectId(object)
    player.lastFoundGradNodeId = grabNode.id
    player.lastFoundObjectIsHose = true
    player.lastFoundHoseIsConnected = isConnected

    if not player.msLoggedFirstDetect then
        player.msLoggedFirstDetect = true
        print(HosePlayer.LOG .. " hose end DETECTED via aim raycast; interaction prompt enabled. (Detection path works.)")
    end

    if object:isDetached(grabNode) then
        HosePlayer.fs25_setActionActive(player, InputAction.MS_ATTACH_HOSE, true, g_i18n:getText("input_MS_ATTACH_HOSE"))
    elseif isConnected then
        HosePlayer.fs25_offerConnectedPrompts(player, object, grabNode)
    end
end

--------------------------------------------------------------------------------
-- Aim raycast detection (proven FS25 raycastAll signature)
--------------------------------------------------------------------------------
function HosePlayer.fs25_getHoseMask()
    if CollisionFlag == nil then
        return nil -- nil mask -> engine default so detection still has a chance.
    end
    local mask = 0
    if CollisionFlag.VEHICLE ~= nil then
        mask = mask + CollisionFlag.VEHICLE
    end
    if CollisionFlag.DYNAMIC_OBJECT ~= nil then
        mask = mask + CollisionFlag.DYNAMIC_OBJECT
    end
    if mask == 0 then
        return nil
    end
    return mask
end

function HosePlayer.fs25_getAimRay(player)
    -- Returns ox,oy,oz,dx,dy,dz or nil. The aim-ray source is unverified on FS25;
    -- try PlayerTargeter first, then the player, validating we actually got 6 numbers.
    local function tryRay(fn)
        local r = { pcall(fn) }
        if r[1]
            and type(r[2]) == "number" and type(r[3]) == "number" and type(r[4]) == "number"
            and type(r[5]) == "number" and type(r[6]) == "number" and type(r[7]) == "number" then
            return r[2], r[3], r[4], r[5], r[6], r[7]
        end
        return nil
    end

    local t = player.targeter
    if t ~= nil and t.getLookRay ~= nil then
        local ox, oy, oz, dx, dy, dz = tryRay(function() return t:getLookRay() end)
        if ox ~= nil then
            return ox, oy, oz, dx, dy, dz
        end
    end
    if player.getLookRay ~= nil then
        local ox, oy, oz, dx, dy, dz = tryRay(function() return player:getLookRay() end)
        if ox ~= nil then
            return ox, oy, oz, dx, dy, dz
        end
    end
    return nil
end

function HosePlayer.fs25_raycastHose(player)
    local ox, oy, oz, dx, dy, dz = HosePlayer.fs25_getAimRay(player)
    if ox == nil then
        if not player.msLoggedNoRay then
            player.msLoggedNoRay = true
            print(HosePlayer.LOG .. " no aim-ray source found (targeter:getLookRay / player:getLookRay both unavailable or wrong shape) -- hose detection cannot run. See the [PROBE] block above for the real API names.")
        end
        return nil
    end

    HosePlayer._ray.node = 0
    HosePlayer._ray.dist = math.huge

    local mask = HosePlayer.fs25_getHoseMask()
    local ok, err = pcall(function()
        raycastAll(ox, oy, oz, dx, dy, dz, HosePlayer.FS25_TARGET_MAX_DISTANCE, "fs25_onHoseRaycast", HosePlayer, mask, true)
    end)
    if not ok then
        if not player.msLoggedRaycastError then
            player.msLoggedRaycastError = true
            print(HosePlayer.LOG .. " raycastAll error (detection disabled): " .. tostring(err))
        end
        return nil
    end

    if HosePlayer._ray.node ~= 0 then
        return HosePlayer._ray.node, HosePlayer._ray.x, HosePlayer._ray.y, HosePlayer._ray.z
    end
    return nil
end

-- raycastAll invokes this as HosePlayer:fs25_onHoseRaycast(...), so self == HosePlayer.
function HosePlayer.fs25_onHoseRaycast(self, hitObjectId, x, y, z, distance, nx, ny, nz, subShapeIndex, shapeId, isLast)
    if hitObjectId ~= nil and hitObjectId ~= 0
        and g_currentMission ~= nil and hitObjectId ~= g_currentMission.terrainRootNode then
        local object = g_currentMission:getNodeObject(hitObjectId)
        if object ~= nil and object.isaHose ~= nil and object:isaHose() then
            if distance ~= nil and distance < HosePlayer._ray.dist then
                HosePlayer._ray.dist = distance
                HosePlayer._ray.node = hitObjectId
                HosePlayer._ray.x = x
                HosePlayer._ray.y = y
                HosePlayer._ray.z = z
            end
        end
    end
    return true -- keep scanning so we settle on the closest hose hit
end

--------------------------------------------------------------------------------
-- Contextual prompt helpers
--------------------------------------------------------------------------------
function HosePlayer.fs25_updateCarriedPrompts(player, hose)
    -- Always allow dropping while carrying.
    HosePlayer.fs25_setActionActive(player, InputAction.MS_DETACH_HOSE, true, g_i18n:getText("input_MS_DETACH_HOSE"))

    local spec = hose.spec_hose
    local grabNode = hose:getGrabNodeById(player.hoseGrabNodeId)
    if grabNode ~= nil and hose:isAttached(grabNode) and spec.foundConnectorId ~= 0 and not spec.foundConnectorIsConnected then
        local text = spec.foundConnectorIsParkPlace and g_i18n:getText("action_storeHose") or g_i18n:getText("input_MS_ATTACH_HOSE")
        HosePlayer.fs25_setActionActive(player, InputAction.MS_ATTACH_HOSE, true, text)
    end
end

function HosePlayer.fs25_offerConnectedPrompts(player, hose, grabNode)
    local spec = hose.spec_hose
    local desc = spec.grabNodesToObjects[grabNode.id]
    if desc == nil then
        return
    end
    local object = desc.vehicle
    local connector = object:getConnectorById(desc.connectorId)
    local hasFlow = connector.manureFlowAnimationName ~= nil or connector.manureFlowAnimationIndex ~= nil
    if hasFlow then
        HosePlayer.fs25_setActionActive(player, InputAction.MS_TOGGLE_FLOW, true, g_i18n:getText("action_toggleManureFlow"))
    end
    if not hasFlow or not connector.hasOpenManureFlow then
        HosePlayer.fs25_setActionActive(player, InputAction.MS_DETACH_HOSE, true, g_i18n:getText("input_MS_DETACH_HOSE"))
    end
end

--------------------------------------------------------------------------------
-- Input callbacks
--------------------------------------------------------------------------------
-- MS_ATTACH_HOSE: grab a loose end, or (while carrying) attach it to a found connector.
function HosePlayer.fs25_onAttach(inputComponent, actionName, inputValue, callbackState, isAnalog)
    local player = inputComponent.player
    if player == nil then
        return
    end

    -- Carrying: attach to a found connector.
    if player.hoseGrabNodeId ~= nil and player.msCarriedHoseId ~= nil then
        local hose = NetworkUtil.getObject(player.msCarriedHoseId)
        if hose ~= nil then
            local spec = hose.spec_hose
            local grabNode = hose:getGrabNodeById(player.hoseGrabNodeId)
            if grabNode ~= nil and hose:isAttached(grabNode) and spec.foundConnectorId ~= 0 and spec.foundVehicleId ~= 0 and not spec.foundConnectorIsConnected then
                hose:attach(grabNode.id, spec.foundConnectorId, NetworkUtil.getObject(spec.foundVehicleId))
                print(HosePlayer.LOG .. " attach: hose connected to a found connector.")
            end
        end
        return
    end

    -- Not carrying: grab a loose end.
    if player.lastFoundObjectIsHose then
        local hose = NetworkUtil.getObject(player.lastFoundHose)
        if hose ~= nil then
            local grabNode = hose:getGrabNodeById(player.lastFoundGradNodeId)
            if grabNode ~= nil and not hose:isConnected(grabNode) then
                player.msCarriedHoseId = player.lastFoundHose
                hose:grab(grabNode.id, player)
                print(HosePlayer.LOG .. " grab: picked up a hose end (grabNodeId=" .. tostring(grabNode.id) .. ").")
            end
        end
    end
end

-- MS_DETACH_HOSE: drop the carried end, or detach a connected end.
function HosePlayer.fs25_onDetach(inputComponent, actionName, inputValue, callbackState, isAnalog)
    local player = inputComponent.player
    if player == nil then
        return
    end

    -- Carrying: drop the end.
    if player.hoseGrabNodeId ~= nil and player.msCarriedHoseId ~= nil then
        local hose = NetworkUtil.getObject(player.msCarriedHoseId)
        if hose ~= nil then
            hose:drop(player.hoseGrabNodeId, player)
            print(HosePlayer.LOG .. " drop: released the carried hose end.")
        end
        player.msCarriedHoseId = nil
        return
    end

    -- Looking at a connected end: detach it.
    if player.lastFoundObjectIsHose and player.lastFoundHoseIsConnected then
        local hose = NetworkUtil.getObject(player.lastFoundHose)
        if hose ~= nil then
            local spec = hose.spec_hose
            local grabNode = hose:getGrabNodeById(player.lastFoundGradNodeId)
            if grabNode ~= nil and hose:isConnected(grabNode) then
                local desc = spec.grabNodesToObjects[grabNode.id]
                if desc ~= nil then
                    hose:detach(grabNode.id, desc.connectorId, desc.vehicle)
                    print(HosePlayer.LOG .. " detach: disconnected a connected hose end.")
                end
            end
        end
    end
end

-- MS_TOGGLE_FLOW: open/close manure flow on the connected connector.
function HosePlayer.fs25_onToggleFlow(inputComponent, actionName, inputValue, callbackState, isAnalog)
    local player = inputComponent.player
    if player == nil then
        return
    end
    local hoseId = player.msCarriedHoseId or player.lastFoundHose
    local nodeId = player.hoseGrabNodeId or player.lastFoundGradNodeId
    if hoseId == nil or nodeId == nil then
        return
    end
    local hose = NetworkUtil.getObject(hoseId)
    if hose == nil then
        return
    end
    local spec = hose.spec_hose
    local grabNode = hose:getGrabNodeById(nodeId)
    if grabNode == nil or not hose:isConnected(grabNode) then
        return
    end
    local desc = spec.grabNodesToObjects[grabNode.id]
    if desc == nil then
        return
    end
    local vehicle = desc.vehicle
    local connector = vehicle:getConnectorById(desc.connectorId)
    local hasFlow = connector.manureFlowAnimationName ~= nil or connector.manureFlowAnimationIndex ~= nil
    local animationName = connector.manureFlowAnimationName ~= nil and connector.manureFlowAnimationName or connector.manureFlowAnimationIndex
    if hasFlow and not vehicle:getIsAnimationPlaying(animationName) then
        vehicle:setIsManureFlowOpen(desc.connectorId, not connector.hasOpenManureFlow, false)
        print(HosePlayer.LOG .. " toggleFlow: toggled manure flow on the connected connector.")
    end
end
