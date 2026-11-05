--[[
LAST STOP - ALIEN TOKEN FARMER HF9.9 (CENTERED UNDERBODY TETHER + NEAREST CONTACT + TARGET ROTATION + HEALTH GUARD + FULL CLEAR + TOKEN RECOVERY + ANTI-AFK)
Standalone experimental build for the Last Stop Roblox experience.
HF9.9 keeps the HF9.8 full-clear, token recovery, anti-AFK, health guard, collateral protection, nearest-contact selection, and original ReplicaSignal transport. It removes the lateral hover offset and continuously tethers the player root directly beneath the selected alien torso on Heartbeat, maintaining a 6.5-stud vertical gap during attack and tool cooldown.

Observed game structures used:
  Workspace.ENTITY_CONTAINER.<GUID>.Dress.AlienType1/2/3
  Workspace.ITEM_CONTAINER.<GUID>.Main.CollectAlienTokenPrompt
  ReplicatedStorage.ClientSource.ReplicaRemoteEvents.Replica_ReplicaSignal
  ReplicatedStorage.ClientSource.*.ReplicaController (discovered by ModuleScript name)

Observed melee signal shape from captured traffic:
  FireServer(liveEquippedItemReplicaId, "Melee", "Attack", direction, 1)
  FireServer(liveEquippedItemReplicaId, "Melee", "Hit", part, hitPosition, normal, material)

No external loaders, no global metamethod hooks, and no input interception.
Passive UserInputService listeners are used for diagnostics. Anti-AFK sends a single VirtualUser response only when LocalPlayer.Idled fires; no continuous synthetic-input loop is used.
Attack direction follows the nearest valid alien contact. Server damage confirmation is monitored separately.
]]

if game.GameId ~= 10759337137 then
    warn("[LSAF] Wrong experience. This script is intended for Last Stop (GameId 10759337137).")
    return
end

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local VirtualUser = nil
pcall(function() VirtualUser = game:GetService("VirtualUser") end)
local LocalPlayer = Players.LocalPlayer

local ENTITY_CONTAINER = Workspace:WaitForChild("ENTITY_CONTAINER", 15)
local ITEM_CONTAINER = Workspace:WaitForChild("ITEM_CONTAINER", 15)
local ClientSource = ReplicatedStorage:WaitForChild("ClientSource", 15)
local ReplicaRemoteEvents = ClientSource and ClientSource:WaitForChild("ReplicaRemoteEvents", 15)
local ReplicaSignal = ReplicaRemoteEvents and ReplicaRemoteEvents:WaitForChild("Replica_ReplicaSignal", 15)

if not ENTITY_CONTAINER or not ITEM_CONTAINER or not ReplicaSignal then
    warn("[LSAF] Required game objects were not found. Join a live run and execute again.")
    return
end

local CONFIG = {
    SCAN_X = 300,
    SCAN_Y = 112,
    SCAN_START_Z = 500,
    SCAN_STEP = 600,
    SCAN_MIN_Z = -100000,
    SCAN_WAIT = 0.8,
    SCAN_DETECT_RADIUS = 900,
    ALIEN_ATTACK_RANGE = 50, -- original Classic engagement radius from main.lua
    HOVER_BELOW = 6.5, -- centered beneath torso with 3.5 studs of margin inside the 10-stud contact limit
    HOVER_REPOSITION_THRESHOLD = 0.05,
    TORSO_HORIZONTAL_STANDOFF = 0.0, -- no sideways offset; player root stays directly under torso anchor
    HOVER_TETHER_DEADBAND = 0.05, -- Heartbeat tether corrects even small target-relative drift
    ATTACK_INTERVAL = 0.0655, -- measured median from the working outgoing capture
    MELEE_HIT_DELAY = 0.0323, -- measured median Attack -> first Hit delay
    TOOL_EQUIP_RETRY_INTERVAL = 0.35, -- prevent rapid EquipTool/Unequipped cycling

    NO_KILL_TIMEOUT = 15, -- backup per-pass timeout; the active cluster remains locked
    TARGET_STALL_TIMEOUT = 4.0, -- rotate to another tracked alien after no confirmed hit on the current one
    TARGET_RETRY_COOLDOWN = 8.0, -- revisit a stalled alien after trying other cluster members
    MAX_NO_PROGRESS_CLUSTER_PASSES = 2, -- backup recovery pass count; never releases the cluster
    CLUSTER_RETRY_DELAY = 0.45,
    LOW_HEALTH_STOP_PERCENT = 35.0, -- stop farming and restore player control before critical health
    MAX_HITS_PER_TARGET = 1, -- observed working aura: one Hit per selected target
    MAX_TARGETS_PER_SWEEP = 3,
    MAX_HITS_PER_SWEEP = 3, -- observed working aura: up to three distinct target Hits per Attack
    MELEE_HIT_MAX_DISTANCE = 10.0, -- HF9.0 close-contact part-center limit
    MELEE_HIT_HARD_CEILING = 80, -- never allow the configured contact range above the reference UI maximum
    COLLATERAL_GUARD_RADIUS = 10.0, -- match the close-contact hit radius; suppress nearby non-alien collateral
    TOKEN_SEARCH_RADIUS = 260,
    TOKEN_PROMPT_DISTANCE = 14,
    TOKEN_SETTLE_WAIT = 0.25,
    TOKEN_DROP_SPAWN_WAIT = 0.45,
    TOKEN_DROP_SPAWN_RETRIES = 4,
    TOKEN_PROMPT_RETRIES = 3,
    TOKEN_IDLE_PASSES = 4,
    MAX_TOKEN_PICKUPS_PER_PASS = 40,
    ANTI_AFK = true,
    AUTO_FULLBRIGHT = true,
}

local function getMeleeHitRange()
    return math.min(CONFIG.MELEE_HIT_MAX_DISTANCE, CONFIG.MELEE_HIT_HARD_CEILING)
end

local running = false
local paused = false
local scanZ = CONFIG.SCAN_START_Z
local lap = 1
local scanAdvanceCount = 0
local alienKills = 0
local serverDamageEvents = 0
local serverOnDiedEvents = 0
local serverMeleeEffects = 0
local serverAlienDeathEvents = 0
local serverNonAlienDeathEvents = 0
local serverConfirmedAlienHitEvents = 0
local serverNonAlienMeleeEffects = 0
local lastServerDamageAt = nil
local serverDeadAlienModels = setmetatable({}, { __mode = "k" })
local replicaGuidsById = {}
local serverMonitorConnections = {}
local itemReplicaIdsByGuid = {}
local itemReplicaResolverConnection = nil
local replicaController = nil
local replicaControllerPath = "not found"
local replicaRegistryIndexed = 0
local lastResolvedMeleeReplicaId = nil
local lastReplicaIdSource = "not resolved"
local tokenAttempts = 0
local tokenPickupsConfirmed = 0
local pendingTokenDropCenters = {}
local tokenDropCentersQueued = 0
local tokenDropCentersProcessed = 0
local antiAfkEvents = 0
local antiAfkErrors = 0
local antiAfkAvailable = false
local antiAfkConnection = nil
local deferredAlienGuidCount = 0
local rewardToastEstimate = 0
local remoteErrors = 0
local currentTarget = "None"
local equippedToolName = "None"
local lastToolEquipAttemptAt = -math.huge
local toolEquipAttempts = 0
local toolEquippedEvents = 0
local toolUnequippedEvents = 0
local playerHealthCurrent = nil
local playerHealthMax = nil
local playerDeathEvents = 0
local lowHealthStopTriggered = false
local stopFarm = nil
local currentStatus = "Initializing"
local lastAlienKillAt = os.clock()
local lastLabelText = {}
local rewardFramesSeen = {}
local trackedTextLabels = {}
local collisionSnapshot = {}
local activeCharacter = nil
local activeRoot = nil
local activeHumanoid = nil
local flyVelocity = nil
local flyGyro = nil
local hoverTetherConnection = nil
local hoverTetherEntry = nil
local hoverTetherAnchor = nil
local originalLighting = {}
local fullbrightApplied = false
local safeCameraState = nil
local mainLoopThread = nil
local diagEvents = {}
local diagCounts = {}
local diagLastByKey = {}
local diagMaxEvents = 5000
local diagErrorCount = 0
local diagPanel = nil
local diagText = nil
local diagCountLabel = nil
local refreshDiagPanel = nil
local flightLogRoot = nil
local monitoredHumanoids = {}
-- HF4 diagnostics-only counters and correlation timestamps.
local monitoredAliens = {}
local monitoredAlienModelsTotal = 0
local alienHealthSourcesFound = 0
local alienDamageEvents = 0
local alienDeathEvents = 0
local alienHealthUiEvents = 0
local automatedDamageUiEvents = 0
local monitoredTools = {}
local nativeToolActivations = 0
local automatedAttackRequests = 0
local automatedHitRequests = 0
local lastManualToolActivationAt = nil
local lastAutoAttackAt = nil
local lastAutoHitAt = nil
local lastAutoHitByModel = {}
local manualMouseDownCount = 0
local manualMouseUpCount = 0
local manualTouchCount = 0
local lastManualInputAt = nil
local lastManualInputKind = "None"
local lastManualInputProcessed = nil
local movementAnomalyCount = 0
local fallWarningCount = 0
local movementSamples = 0
local movementMonitorCharacters = setmetatable({}, { __mode = "k" })
local expectedCharacterMove = nil

local function diagTraceback(err)
    local message = tostring(err)
    if debug and type(debug.traceback) == "function" then
        local ok, trace = pcall(debug.traceback, message, 2)
        if ok and trace then
            return tostring(trace)
        end
    end
    return message
end

local function recordEvent(category, message, details)
    local event = {
        time = os.date("%H:%M:%S"),
        clock = math.floor(os.clock() * 1000) / 1000,
        category = tostring(category or "INFO"),
        message = tostring(message or ""),
        details = tostring(details or ""),
    }
    table.insert(diagEvents, event)
    if #diagEvents > diagMaxEvents then
        table.remove(diagEvents, 1)
    end
    diagCounts[event.category] = (diagCounts[event.category] or 0) + 1
    if event.category == "ERROR" then
        diagErrorCount = diagErrorCount + 1
    end
    if refreshDiagPanel and diagPanel and diagPanel.Visible then
        pcall(refreshDiagPanel)
    end
    return event
end

local function recordThrottled(key, interval, category, message, details)
    local now = os.clock()
    local previous = diagLastByKey[key]
    if previous == nil or now - previous >= interval then
        diagLastByKey[key] = now
        return recordEvent(category, message, details)
    end
    return nil
end

local function getReplicaGuidForDeath(replicaId)
    local numericId = tonumber(replicaId)
    local guid = replicaGuidsById[numericId] or replicaGuidsById[tostring(replicaId)]
    if guid then
        return tostring(guid)
    end

    local controller = replicaController
    if controller and type(controller.GetReplicaById) == "function" then
        local ok, replica = pcall(function()
            return controller.GetReplicaById(numericId or replicaId)
        end)
        if ok and type(replica) == "table" then
            local containers = {}
            if type(replica.Tags) == "table" then table.insert(containers, replica.Tags) end
            if type(replica.Data) == "table" then table.insert(containers, replica.Data) end
            for _, container in ipairs(containers) do
                for _, key in ipairs({ "Id", "id", "Guid", "GUID", "ItemGuid", "ItemGUID", "GuidString" }) do
                    local value = container[key]
                    if type(value) == "string" and value ~= "" then
                        guid = value
                        if string.sub(string.upper(guid), 1, 5) == "ITEM|" then
                            guid = string.sub(guid, 6)
                        end
                        return guid
                    end
                end
            end
        end
    end
    return nil
end

local function findEntityModelForPart(part)
    if typeof(part) ~= "Instance" then
        return nil
    end

    -- Prefer the already-monitored model table; this also works if an entity
    -- has just been reparented out of ENTITY_CONTAINER after dying.
    for model in pairs(monitoredAliens) do
        local ok, inside = pcall(function()
            return part:IsDescendantOf(model)
        end)
        if ok and inside then
            return model
        end
    end

    local current = part
    while current and current.Parent and current.Parent ~= ENTITY_CONTAINER do
        current = current.Parent
    end
    if current and current.Parent == ENTITY_CONTAINER and current:IsA("Model") then
        return current
    end
    return nil
end

local function findAlienModelForReplicaDeath(replicaId, guid)
    if guid then
        local direct = ENTITY_CONTAINER and ENTITY_CONTAINER:FindFirstChild(guid)
        if direct and monitoredAliens[direct] then
            return direct
        end
        for model in pairs(monitoredAliens) do
            if tostring(model.Name) == tostring(guid) then
                return model
            end
        end
    end
    return nil
end

local function attachServerCombatMonitors()
    if ReplicaSignal and ReplicaSignal:IsA("RemoteEvent") then
        local ok, connection = pcall(function()
            return ReplicaSignal.OnClientEvent:Connect(function(replicaId, signalName, ...)
                if signalName == "OnDied" then
                    serverOnDiedEvents = serverOnDiedEvents + 1
                    local guid = getReplicaGuidForDeath(replicaId)
                    local model = findAlienModelForReplicaDeath(replicaId, guid)
                    local alienRecord = model and monitoredAliens[model]
                    if alienRecord then
                        if not alienRecord.serverDead then
                            alienRecord.serverDead = true
                            serverDeadAlienModels[model] = true
                            serverAlienDeathEvents = serverAlienDeathEvents + 1
                        end
                        if not alienRecord.tokenDropQueued then
                            local deathPosition = alienRecord.lastKnownPosition
                            pcall(function()
                                local deathRoot = model:FindFirstChild("HumanoidRootPart")
                                    or model.PrimaryPart
                                    or model:FindFirstChild("Torso", true)
                                    or model:FindFirstChild("Head", true)
                                if deathRoot and deathRoot:IsA("BasePart") then
                                    deathPosition = deathRoot.Position
                                end
                            end)
                            if deathPosition then
                                alienRecord.tokenDropQueued = true
                                table.insert(pendingTokenDropCenters, {
                                    position = deathPosition,
                                    modelName = tostring(model.Name),
                                    variant = tostring(alienRecord.variant),
                                    replicaId = tostring(replicaId),
                                })
                                tokenDropCentersQueued = tokenDropCentersQueued + 1
                                recordEvent("TOKEN", "Confirmed alien death position queued for drop collection",
                                    string.format("Target=%s/%s | Position=(%.1f, %.1f, %.1f) | Queue=%d",
                                        tostring(alienRecord.variant), tostring(model.Name),
                                        deathPosition.X, deathPosition.Y, deathPosition.Z, #pendingTokenDropCenters))
                            else
                                recordEvent("TOKEN", "Alien death confirmed but drop position unavailable",
                                    "Target=" .. tostring(alienRecord.variant) .. "/" .. tostring(model.Name)
                                        .. " | A tracked cluster position will be used as fallback")
                            end
                        end
                        recordEvent("KILL", "Server-confirmed alien death",
                            "ReplicaId=" .. tostring(replicaId) .. " | GUID=" .. tostring(guid)
                                .. " | Variant=" .. tostring(alienRecord.variant)
                                .. " | Model=" .. tostring(model.Name)
                                .. " | AlienDeaths=" .. tostring(serverAlienDeathEvents))
                    else
                        serverNonAlienDeathEvents = serverNonAlienDeathEvents + 1
                        recordEvent("KILL", "Server death signal for non-alien/unknown entity",
                            "ReplicaId=" .. tostring(replicaId) .. " | GUID=" .. tostring(guid)
                                .. " | NonAlienOrUnknownDeaths=" .. tostring(serverNonAlienDeathEvents))
                    end
                end
            end)
        end)
        if ok and connection then
            table.insert(serverMonitorConnections, connection)
        else
            recordEvent("ERROR", "Replica death monitor unavailable", tostring(connection))
        end
    end

    task.spawn(function()
        local mutual = ClientSource and (ClientSource:FindFirstChild("Mutual") or ClientSource:WaitForChild("Mutual", 8))
        local packages = mutual and (mutual:FindFirstChild("Packages") or mutual:WaitForChild("Packages", 8))
        local knit = packages and (packages:FindFirstChild("Knit") or packages:WaitForChild("Knit", 8))
        local services = knit and (knit:FindFirstChild("Services") or knit:WaitForChild("Services", 8))
        local damageService = services and (services:FindFirstChild("DamageService") or services:WaitForChild("DamageService", 8))
        local damageFolder = damageService and (damageService:FindFirstChild("RE") or damageService:WaitForChild("RE", 8))
        local damageRemote = damageFolder and (damageFolder:FindFirstChild("DamageDealt") or damageFolder:WaitForChild("DamageDealt", 8))

        if damageRemote and damageRemote:IsA("RemoteEvent") then
            local ok, connection = pcall(function()
                return damageRemote.OnClientEvent:Connect(function(...)
                    local args = table.pack(...)
                    serverDamageEvents = serverDamageEvents + 1
                    lastServerDamageAt = os.clock()
                    recordEvent("COMBAT", "Server DamageDealt confirmation",
                        "Damage=" .. tostring(args[2]) .. " | Position=" .. tostring(args[3])
                        .. " | TotalDamageEvents=" .. tostring(serverDamageEvents))
                end)
            end)
            if ok and connection then
                table.insert(serverMonitorConnections, connection)
                recordEvent("SYSTEM", "Server damage monitor attached", damageRemote:GetFullName())
            else
                recordEvent("ERROR", "Server damage monitor connection failed", tostring(connection))
            end
        else
            recordEvent("DIAGNOSTICS", "Server damage monitor unavailable",
                "Knit DamageService.RE.DamageDealt was not found")
        end

        local effectService = services and (services:FindFirstChild("EffectService") or services:WaitForChild("EffectService", 8))
        local effectFolder = effectService and (effectService:FindFirstChild("RE") or effectService:WaitForChild("RE", 8))
        local effectRemote = effectFolder and (effectFolder:FindFirstChild("Play") or effectFolder:WaitForChild("Play", 8))
        if effectRemote and effectRemote:IsA("RemoteEvent") then
            local ok, connection = pcall(function()
                return effectRemote.OnClientEvent:Connect(function(effectType, actionName, ...)
                    if effectType == "Melee" and actionName == "Hit" then
                        serverMeleeEffects = serverMeleeEffects + 1
                        local packed = table.pack(...)
                        local payload = packed[2]
                        local hitInstance = type(payload) == "table" and payload.Instance or nil
                        local source = type(payload) == "table" and payload.Source or nil
                        local targetModel = findEntityModelForPart(hitInstance)
                        local alienRecord = targetModel and monitoredAliens[targetModel]
                        local sourceIsLocal = source == nil or source == LocalPlayer

                        if alienRecord and sourceIsLocal then
                            serverConfirmedAlienHitEvents = serverConfirmedAlienHitEvents + 1
                            alienRecord.serverHitCount = (alienRecord.serverHitCount or 0) + 1
                            alienRecord.lastServerHitAt = os.clock()
                            alienRecord.lastServerHitPart = hitInstance and hitInstance.Name or "unknown"
                            recordEvent("COMBAT", "Server-confirmed alien impact",
                                "Target=" .. tostring(alienRecord.variant) .. "/" .. tostring(targetModel.Name)
                                    .. " | Part=" .. tostring(alienRecord.lastServerHitPart)
                                    .. " | Source=" .. tostring(source and source.Name or "unspecified")
                                    .. " | AlienImpactCount=" .. tostring(serverConfirmedAlienHitEvents))
                        else
                            serverNonAlienMeleeEffects = serverNonAlienMeleeEffects + 1
                            local instancePath = "unavailable"
                            if typeof(hitInstance) == "Instance" then
                                pcall(function() instancePath = hitInstance:GetFullName() end)
                            end
                            recordEvent("COMBAT", "Server melee impact was not attributed to our alien target",
                                "Instance=" .. instancePath
                                    .. " | Source=" .. tostring(source and source.Name or "unspecified")
                                    .. " | NonAlienOrUnknownEffects=" .. tostring(serverNonAlienMeleeEffects))
                        end
                    end
                end)
            end)
            if ok and connection then
                table.insert(serverMonitorConnections, connection)
                recordEvent("SYSTEM", "Server melee effect monitor attached", effectRemote:GetFullName())
            else
                recordEvent("ERROR", "Server melee effect monitor connection failed", tostring(connection))
            end
        else
            recordEvent("DIAGNOSTICS", "Server melee effect monitor unavailable",
                "Knit EffectService.RE.Play was not found")
        end
    end)
end

attachServerCombatMonitors()

-- Resolve the equipped item's replica ID from the game's already-loaded
-- ReplicaController registry. HF8.5 only listened for future ReplicaCreate
-- events; if the starting Shovel already existed, it silently fell back to 120.
-- ReplicaService exposes the loaded registry as ReplicaController._replicas.
local function discoverReplicaController()
    if replicaController and type(replicaController._replicas) == "table" then
        return replicaController
    end

    local roots = { ClientSource, ReplicatedStorage }
    local visited = {}
    for _, root in ipairs(roots) do
        if root and not visited[root] then
            visited[root] = true
            local descendants = root:GetDescendants()
            for _, object in ipairs(descendants) do
                if object:IsA("ModuleScript") and object.Name == "ReplicaController" then
                    local ok, candidate = pcall(require, object)
                    if ok and type(candidate) == "table"
                        and type(candidate.GetReplicaById) == "function"
                        and type(candidate._replicas) == "table" then
                        replicaController = candidate
                        replicaControllerPath = object:GetFullName()
                        local existingCount = 0
                        for _ in pairs(candidate._replicas) do
                            existingCount = existingCount + 1
                        end
                        recordEvent("SYSTEM", "ReplicaController registry found",
                            replicaControllerPath .. " | Existing replicas=" .. tostring(existingCount))
                        return replicaController
                    elseif not ok then
                        recordThrottled("replica-controller-require:" .. object:GetFullName(), 5,
                            "DIAGNOSTICS", "ReplicaController require failed",
                            object:GetFullName() .. " | " .. tostring(candidate))
                    end
                end
            end
        end
    end

    replicaControllerPath = "ModuleScript named ReplicaController not found or incompatible API"
    return nil
end

local function normalizeReplicaGuid(value)
    if value == nil then
        return nil
    end
    local guid = tostring(value)
    if string.sub(string.upper(guid), 1, 5) == "ITEM|" then
        guid = string.sub(guid, 6)
    end
    return guid
end

local function getReplicaGuid(replica)
    if type(replica) ~= "table" then
        return nil
    end

    local containers = {}
    if type(replica.Tags) == "table" then table.insert(containers, replica.Tags) end
    if type(replica.Data) == "table" then table.insert(containers, replica.Data) end
    local keys = { "Id", "id", "Guid", "GUID", "ItemGuid", "ItemGUID", "GuidString" }
    for _, container in ipairs(containers) do
        for _, key in ipairs(keys) do
            local value = container[key]
            if type(value) == "string" and value ~= "" then
                return normalizeReplicaGuid(value)
            end
        end
    end

    return nil
end

local function indexReplica(replica, fallbackId)
    if type(replica) ~= "table" then
        return false
    end

    local guid = getReplicaGuid(replica)
    local replicaId = tonumber(replica.Id) or tonumber(fallbackId)
    if not guid or not replicaId then
        return false
    end

    itemReplicaIdsByGuid[guid] = replicaId
    replicaGuidsById[replicaId] = guid
    replicaGuidsById[tostring(replicaId)] = guid
    return true
end

local function indexExistingReplicaRegistry()
    local controller = discoverReplicaController()
    if not controller then
        return false
    end

    local registry = controller._replicas
    if type(registry) ~= "table" then
        return false
    end

    local indexed = 0
    for id, replica in pairs(registry) do
        if indexReplica(replica, id) then
            indexed = indexed + 1
        end
    end
    replicaRegistryIndexed = indexed

    recordThrottled("replica-registry-indexed", 2, "SYSTEM",
        "Existing replica registry indexed",
        "Controller=" .. tostring(replicaControllerPath)
            .. " | Live replicas=" .. tostring((function()
                local count = 0
                for _ in pairs(registry) do count = count + 1 end
                return count
            end)())
            .. " | GUID-tagged replicas=" .. tostring(indexed))

    return true
end

local function attachReplicaRegistryListeners()
    local controller = discoverReplicaController()
    if not controller then
        recordEvent("DIAGNOSTICS", "Live replica registry unavailable",
            "No compatible ReplicaController._replicas table found; no hardcoded replica ID will be used")
        return
    end

    -- Connect first, then index the current registry, so a replica created
    -- during the initial scan cannot be missed.
    local newSignal = controller.NewReplicaSignal
    if newSignal and type(newSignal.Connect) == "function" then
        local ok, connection = pcall(function()
            return newSignal:Connect(function(replica)
                indexReplica(replica)
            end)
        end)
        if ok and connection then
            table.insert(serverMonitorConnections, connection)
            itemReplicaResolverConnection = connection
            recordEvent("SYSTEM", "ReplicaController.NewReplicaSignal listener attached",
                tostring(replicaControllerPath))
        else
            recordEvent("DIAGNOSTICS", "ReplicaController.NewReplicaSignal listener unavailable",
                tostring(connection))
        end
    end

    local initialSignal = controller.InitialDataReceivedSignal
    if controller.InitialDataReceived == false and initialSignal
        and type(initialSignal.Connect) == "function" then
        local ok, connection = pcall(function()
            return initialSignal:Connect(function()
                indexExistingReplicaRegistry()
            end)
        end)
        if ok and connection then
            table.insert(serverMonitorConnections, connection)
            recordEvent("SYSTEM", "Replica initial-data listener attached",
                "Will index existing replicas when initial replication completes")
        end
    end

    indexExistingReplicaRegistry()

    -- Keep a passive event listener as a secondary cache source. This is not
    -- the primary resolver because it cannot replay ReplicaCreate events that
    -- occurred before this farmer was executed.
    local createRemote = ReplicaRemoteEvents and ReplicaRemoteEvents:FindFirstChild("Replica_ReplicaCreate")
    if createRemote and createRemote:IsA("RemoteEvent") then
        local ok, connection = pcall(function()
            return createRemote.OnClientEvent:Connect(function(replicaId, payload)
                if type(payload) ~= "table" then return end
                local metadata = type(payload[2]) == "table" and payload[2] or payload
                if type(metadata) ~= "table" then return end
                local guid = metadata.Id or metadata.id or metadata.Guid or metadata.GUID
                local numericId = tonumber(replicaId)
                if guid ~= nil and numericId then
                    itemReplicaIdsByGuid[normalizeReplicaGuid(guid)] = numericId
                end
            end)
        end)
        if ok and connection then
            table.insert(serverMonitorConnections, connection)
            recordEvent("SYSTEM", "ReplicaCreate backup listener attached", createRemote:GetFullName())
        end
    end
end

attachReplicaRegistryListeners()

local function resolveMeleeReplicaId(tool)
    if not tool then
        lastResolvedMeleeReplicaId = nil
        lastReplicaIdSource = "no equipped Tool"
        return nil, lastReplicaIdSource, nil
    end

    local guid = normalizeReplicaGuid(tool.Name)
    local controller = discoverReplicaController()
    if controller then
        local mapped = itemReplicaIdsByGuid[guid]
        if mapped ~= nil then
            local ok, replica = pcall(function()
                return controller.GetReplicaById(mapped)
            end)
            if ok and replica and getReplicaGuid(replica) == guid then
                lastResolvedMeleeReplicaId = tonumber(replica.Id) or mapped
                lastReplicaIdSource = "ReplicaController registry cache; equipped Tool GUID verified"
                return lastResolvedMeleeReplicaId, lastReplicaIdSource, replica
            end
            itemReplicaIdsByGuid[guid] = nil
        end

        -- Re-scan the live registry on a cache miss. This handles tools whose
        -- ReplicaCreate event happened before the farmer was executed.
        indexExistingReplicaRegistry()
        mapped = itemReplicaIdsByGuid[guid]
        if mapped ~= nil then
            local ok, replica = pcall(function()
                return controller.GetReplicaById(mapped)
            end)
            if ok and replica and getReplicaGuid(replica) == guid then
                lastResolvedMeleeReplicaId = tonumber(replica.Id) or mapped
                lastReplicaIdSource = "ReplicaController._replicas live GUID match"
                return lastResolvedMeleeReplicaId, lastReplicaIdSource, replica
            end
            itemReplicaIdsByGuid[guid] = nil
        end
    end

    lastResolvedMeleeReplicaId = nil
    lastReplicaIdSource = "UNRESOLVED: equipped Tool GUID not present in live ReplicaController registry"
    return nil, lastReplicaIdSource, nil
end

local function buildAlienHealthSnapshot()
    local snapshot = {}
    for model, record in pairs(monitoredAliens) do
        local sources = {}
        for sourceName, value in pairs(record.sources or {}) do
            table.insert(sources, { name = tostring(sourceName), value = tonumber(value) })
        end
        table.sort(sources, function(a, b) return a.name < b.name end)
        table.insert(snapshot, {
            variant = tostring(record.variant),
            modelName = tostring(model.Name),
            inEntityContainer = model.Parent == ENTITY_CONTAINER,
            deadSignal = record.dead == true,
            serverDead = record.serverDead == true,
            serverHitCount = tonumber(record.serverHitCount) or 0,
            removed = record.removed == true,
            sourceCount = tonumber(record.sourceCount) or 0,
            uiSourceCount = (function()
                local count = 0
                for _ in pairs(record.uiSources or {}) do count = count + 1 end
                return count
            end)(),
            lastHealthValue = record.lastHealthValue,
            lastHealthDelta = record.lastHealthDelta,
            lastHealthSource = record.lastHealthSource,
            lastHealthAttribution = record.lastHealthAttribution,
            lastUiDamageAt = record.lastUiDamageAt,
            lastUiDamageDelta = record.lastUiDamageDelta,
            lastUiDamageAttribution = record.lastUiDamageAttribution,
            lastAutoUiDamageAt = record.lastAutoUiDamageAt,
            lastAutoUiDamageDelta = record.lastAutoUiDamageDelta,
            lastAutoUiDamageAttribution = record.lastAutoUiDamageAttribution,
            maxHealthSources = record.maxHealthSources or {},
            sources = sources,
        })
    end
    table.sort(snapshot, function(a, b)
        if a.variant == b.variant then return a.modelName < b.modelName end
        return a.variant < b.variant
    end)
    return snapshot
end

local function buildDiagnosticReport()
    local lines = {
        "LAST STOP ALIEN FARMER - DIAGNOSTICS",
        "Version: HF9.9-CENTERED-UNDERBODY-TETHER-NEAREST-CONTACT-TARGET-ROTATION-HEALTH-GUARD-ANTIAFK",
        "GameId: " .. tostring(game.GameId) .. " | PlaceId: " .. tostring(game.PlaceId),
        "Status: " .. tostring(currentStatus) .. " | Running=" .. tostring(running) .. " | Paused=" .. tostring(paused),
        "Current target: " .. tostring(currentTarget) .. " | Equipped tool: " .. tostring(equippedToolName),
        "Underbody tether: Active=" .. tostring(hoverTetherConnection ~= nil) .. " | Target=" .. tostring(hoverTetherEntry and hoverTetherEntry.model and hoverTetherEntry.model.Name or "None") .. " | Vertical=" .. tostring(CONFIG.HOVER_BELOW) .. " | HorizontalOffset=" .. tostring(CONFIG.TORSO_HORIZONTAL_STANDOFF),
        "Player health: " .. tostring(playerHealthCurrent) .. "/" .. tostring(playerHealthMax) .. " | Death events=" .. tostring(playerDeathEvents),
        "Tool cycle: EquipAttempts=" .. tostring(toolEquipAttempts) .. " | EquippedEvents=" .. tostring(toolEquippedEvents) .. " | UnequippedEvents=" .. tostring(toolUnequippedEvents),
        "Lap: " .. tostring(lap) .. " | ScanZ: " .. tostring(scanZ),
        "Alien kill notifications: " .. tostring(alienKills),
        "Server confirmations: DamageDealt=" .. tostring(serverDamageEvents) .. " | OnDied=" .. tostring(serverOnDiedEvents) .. " | MeleeEffects=" .. tostring(serverMeleeEffects),
        "Entity attribution: AlienImpacts=" .. tostring(serverConfirmedAlienHitEvents) .. " | NonAlienOrUnknownImpacts=" .. tostring(serverNonAlienMeleeEffects) .. " | AlienDeaths=" .. tostring(serverAlienDeathEvents) .. " | NonAlienOrUnknownDeaths=" .. tostring(serverNonAlienDeathEvents),
        "Alien monitors: " .. tostring(monitoredAlienModelsTotal) .. " | Numeric health sources: " .. tostring(alienHealthSourcesFound),
        "Alien health-source decrease signals: " .. tostring(alienDamageEvents) .. " | Alien death signals: " .. tostring(alienDeathEvents),
        "Health-bar UI changes: " .. tostring(alienHealthUiEvents) .. " | Auto-correlated foreground damage events: " .. tostring(automatedDamageUiEvents) .. " | Native Tool.Activated signals: " .. tostring(nativeToolActivations),
        "Farmer requests: Attack=" .. tostring(automatedAttackRequests) .. " | Hit=" .. tostring(automatedHitRequests),
        "Melee replica mapping: ID=" .. tostring(lastResolvedMeleeReplicaId) .. " | Source=" .. tostring(lastReplicaIdSource),
        "ReplicaController: " .. tostring(replicaControllerPath) .. " | GUID-tagged replicas indexed=" .. tostring(replicaRegistryIndexed),
        "Manual input: MouseDown=" .. tostring(manualMouseDownCount) .. " | MouseUp=" .. tostring(manualMouseUpCount) .. " | Touch=" .. tostring(manualTouchCount) .. " | Tool.Activated=" .. tostring(nativeToolActivations) .. " | Last=" .. tostring(lastManualInputKind),
        "Survivor deferral: disabled | Tracked cluster: full-clear",
        "Combat recovery: Target stall=" .. tostring(CONFIG.TARGET_STALL_TIMEOUT) .. "s | Retry cooldown=" .. tostring(CONFIG.TARGET_RETRY_COOLDOWN) .. "s | Contact range=" .. tostring(getMeleeHitRange()) .. " | Collateral guard=" .. tostring(CONFIG.COLLATERAL_GUARD_RADIUS),
        "Low-health safety stop: " .. tostring(CONFIG.LOW_HEALTH_STOP_PERCENT) .. "% (restores player control; no bus teleport)",
        "Movement observer: Samples=" .. tostring(movementSamples) .. " | Unexpected displacement candidates=" .. tostring(movementAnomalyCount) .. " | Fall candidates=" .. tostring(fallWarningCount),
        "Camera follows the character during physical under-alien hover; camera/root offset alone is informational and is not classified as a movement error.",
        "Token attempts: " .. tostring(tokenAttempts) .. " | Confirmed pickups: " .. tostring(tokenPickupsConfirmed),
        "Token death centers: queued=" .. tostring(tokenDropCentersQueued) .. " | processed=" .. tostring(tokenDropCentersProcessed) .. " | pending=" .. tostring(#pendingTokenDropCenters),
        "Anti-AFK: available=" .. tostring(antiAfkAvailable) .. " | Idled events=" .. tostring(antiAfkEvents) .. " | Errors=" .. tostring(antiAfkErrors),
        "Reward toast estimate (not a verified balance): " .. tostring(rewardToastEstimate),
        "Local call errors: " .. tostring(remoteErrors) .. " | Captured errors: " .. tostring(diagErrorCount),
        "Events retained: " .. tostring(#diagEvents) .. " / " .. tostring(diagMaxEvents),
        "Event categories: " .. (function()
            local keys = {}
            for key in pairs(diagCounts) do table.insert(keys, key) end
            table.sort(keys)
            local parts = {}
            for _, key in ipairs(keys) do table.insert(parts, key .. "=" .. tostring(diagCounts[key])) end
            return table.concat(parts, ", ")
        end)(),
        string.rep("-", 72),
    }
    local healthSnapshot = buildAlienHealthSnapshot()
    table.insert(lines, "Alien health snapshot (client-visible sources only):")
    if #healthSnapshot == 0 then
        table.insert(lines, "  No alien models have been attached to the health observer yet.")
    else
        for index, npc in ipairs(healthSnapshot) do
            if index > 40 then
                table.insert(lines, "  ... " .. tostring(#healthSnapshot - 40) .. " additional alien records omitted from text summary; see JSON export.")
                break
            end
            local sourceParts = {}
            for _, source in ipairs(npc.sources) do
                table.insert(sourceParts, source.name .. "=" .. tostring(source.value))
            end
            local maxParts = {}
            for sourceName, value in pairs(npc.maxHealthSources or {}) do
                table.insert(maxParts, tostring(sourceName) .. "=" .. tostring(value))
            end
            table.sort(maxParts)
            table.insert(lines, string.format(
                "  %s/%s | InContainer=%s | Sources=%d | UI=%d | DeadSignal=%s | ServerDead=%s | ServerHits=%d | Removed=%s | LastValue=%s | LastDelta=%s | Attribution=%s | AutoUiDelta=%s | AutoUiAttribution=%s | Max=%s | %s",
                npc.variant, npc.modelName, tostring(npc.inEntityContainer), npc.sourceCount, npc.uiSourceCount,
                tostring(npc.deadSignal), tostring(npc.serverDead), tonumber(npc.serverHitCount) or 0, tostring(npc.removed), tostring(npc.lastHealthValue),
                tostring(npc.lastHealthDelta), tostring(npc.lastHealthAttribution),
                tostring(npc.lastAutoUiDamageDelta), tostring(npc.lastAutoUiDamageAttribution),
                #maxParts > 0 and table.concat(maxParts, "; ") or "unknown",
                #sourceParts > 0 and table.concat(sourceParts, "; ") or "No numeric health source"
            ))
        end
    end
    table.insert(lines, string.rep("-", 72))
    for _, event in ipairs(diagEvents) do
        local line = string.format("[%s] [%.3f] [%s] %s", event.time, event.clock, event.category, event.message)
        if event.details ~= "" then
            line = line .. " | " .. event.details
        end
        table.insert(lines, line)
    end
    return table.concat(lines, "\n")
end

local function log(message)
    pcall(function()
        warn("[LSAF] " .. tostring(message))
    end)
end

local function stopAntiAfk()
    if antiAfkConnection then
        pcall(function() antiAfkConnection:Disconnect() end)
        antiAfkConnection = nil
        recordEvent("SYSTEM", "Anti-AFK listener stopped", "Idled event connection disconnected")
    end
    antiAfkAvailable = false
end

local function startAntiAfk()
    if not CONFIG.ANTI_AFK then
        recordEvent("DIAGNOSTICS", "Anti-AFK disabled by configuration", "ANTI_AFK=false")
        return false
    end
    if antiAfkConnection then
        antiAfkAvailable = true
        return true
    end
    if not VirtualUser then
        antiAfkAvailable = false
        recordEvent("DIAGNOSTICS", "Anti-AFK unavailable", "VirtualUser service is not exposed in this client/executor")
        return false
    end

    local ok, connection = pcall(function()
        return LocalPlayer.Idled:Connect(function()
            if not running then
                return
            end
            local actionOk, actionError = pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new(0, 0))
            end)
            if actionOk then
                antiAfkEvents = antiAfkEvents + 1
                recordEvent("SYSTEM", "Anti-AFK idle event handled",
                    "Count=" .. tostring(antiAfkEvents) .. " | Method=VirtualUser ClickButton2 | Trigger=LocalPlayer.Idled")
            else
                antiAfkErrors = antiAfkErrors + 1
                recordEvent("ERROR", "Anti-AFK idle response failed",
                    "Count=" .. tostring(antiAfkErrors) .. " | Error=" .. diagTraceback(actionError))
            end
        end)
    end)

    if ok and connection then
        antiAfkConnection = connection
        antiAfkAvailable = true
        recordEvent("SYSTEM", "Anti-AFK listener active",
            "Method=LocalPlayer.Idled + VirtualUser:CaptureController/ClickButton2 | No polling or continuous synthetic input")
        return true
    end

    antiAfkAvailable = false
    antiAfkErrors = antiAfkErrors + 1
    recordEvent("ERROR", "Anti-AFK listener could not attach", diagTraceback(connection))
    return false
end

local function setStatus(message)
    currentStatus = tostring(message)
end

local executorName = "Unknown"
if type(identifyexecutor) == "function" then
    local ok, value = pcall(identifyexecutor)
    if ok and value then
        executorName = tostring(value)
    end
end
recordEvent("SYSTEM", "Diagnostics initialized", "Version=HF9.9 | Base=HF9.8 full-clear/token/anti-AFK systems | CombatProfile=HF9.0 close torso-relative hover, 10-stud contact, up to 3 alien targets, corrected part hierarchy and collateral guard | ReplicaIdentity=live ReplicaController registry GUID match; no fixed ID fallback | Transport=original ReplicaSignal RemoteEvent | Executor=" .. executorName .. " | GameId=" .. tostring(game.GameId) .. " | PlaceId=" .. tostring(game.PlaceId))

pcall(function()
    LogService.MessageOut:Connect(function(message, messageType)
        if messageType == Enum.MessageType.MessageError then
            recordThrottled("client-error:" .. tostring(message), 1.5, "ERROR", "Client error observed (origin may be game or script)", tostring(message))
        end
    end)
end)

pcall(function()
    local ScriptContext = game:GetService("ScriptContext")
    ScriptContext.Error:Connect(function(message, stackTrace, scriptInstance)
        local sourceName = "unknown script"
        if scriptInstance then
            pcall(function() sourceName = scriptInstance:GetFullName() end)
        end
        recordThrottled("script-context-error:" .. tostring(message), 1.5, "ERROR", "ScriptContext error", "Source=" .. sourceName .. " | Message=" .. tostring(message) .. " | Stack=" .. tostring(stackTrace))
    end)
end)

local function getCharacter()
    local character = LocalPlayer.Character
    if not character then
        local playerContainer = Workspace:FindFirstChild("PLAYER_CONTAINER")
        if playerContainer then
            character = playerContainer:FindFirstChild(LocalPlayer.Name)
        end
    end
    if not character then
        return nil, nil, nil
    end
    local root = character:FindFirstChild("HumanoidRootPart")
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    return character, root, humanoid
end

local function ensureToolEquipped()
    local character, _, humanoid = getCharacter()
    if not character or not humanoid then
        return false
    end

    -- If the game has the shovel equipped already, do not fight its Enabled state.
    -- The captured game transport can still accept a melee request while Enabled=false.
    local equipped = character:FindFirstChildOfClass("Tool")
    if equipped then
        if equippedToolName ~= equipped.Name then
            equippedToolName = equipped.Name
            recordEvent("WEAPON", "Starting shovel already equipped", equippedToolName .. " | Slot=1")
        end
        return true
    end

    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack") or LocalPlayer:FindFirstChild("Backpack")
    if not backpack then
        recordThrottled("no-backpack", 3, "WEAPON", "Waiting for Backpack", "Cannot equip starting shovel / hotbar slot 1")
        return false
    end

    -- The shovel is the only starting Tool, so the first Tool in Backpack is slot 1.
    local candidate = nil
    for _, child in ipairs(backpack:GetChildren()) do
        if child:IsA("Tool") then
            candidate = child
            break
        end
    end

    if not candidate then
        recordThrottled("no-tool", 3, "WEAPON", "Starting shovel not found", "No Tool in Backpack or Character")
        return false
    end

    local now = os.clock()
    if now - lastToolEquipAttemptAt < CONFIG.TOOL_EQUIP_RETRY_INTERVAL then
        recordThrottled("tool-equip-retry-throttled", 1, "WEAPON", "Shovel equip retry throttled",
            "Previous attempt was " .. string.format("%.3f", now - lastToolEquipAttemptAt)
                .. "s ago | RetryInterval=" .. tostring(CONFIG.TOOL_EQUIP_RETRY_INTERVAL))
        return false
    end

    lastToolEquipAttemptAt = now
    toolEquipAttempts = toolEquipAttempts + 1
    recordThrottled("tool-equip-attempt", 0.15, "WEAPON", "Equipping starting shovel",
        candidate.Name .. " | Source=Backpack first Tool | HotbarSlot=1 | Attempt=" .. tostring(toolEquipAttempts))
    local ok, equipError = pcall(function()
        humanoid:EquipTool(candidate)
    end)
    if not ok then
        recordEvent("ERROR", "Starting shovel EquipTool failed", diagTraceback(equipError))
        return false
    end

    -- HF9.6 waited 120 ms, longer than the ~90-110 ms equipped window in this run.
    -- Verify quickly so the captured Attack -> Hit sequence can use the live Tool.
    task.wait(0.025)
    equipped = character:FindFirstChildOfClass("Tool")
    if equipped then
        equippedToolName = equipped.Name
        recordEvent("WEAPON", "Starting shovel equip verified",
            equippedToolName .. " | Slot=1 | ToolEnabled=" .. tostring(equipped.Enabled)
                .. " | VerificationDelay=0.025s")
        return true
    end

    recordThrottled("equip-not-confirmed", 0.5, "WEAPON", "Starting shovel equip not confirmed", candidate.Name)
    return false
end

local function getPromptPosition(prompt)
    if not prompt or not prompt.Parent then
        return nil
    end
    local parent = prompt.Parent
    if parent:IsA("BasePart") then
        return parent.Position
    end
    if parent:IsA("Attachment") then
        return parent.WorldPosition
    end
    local part = parent:FindFirstChildWhichIsA("BasePart", true)
    if part then
        return part.Position
    end
    return nil
end

local function markerFromText(value)
    if type(value) ~= "string" then
        return nil
    end
    local name = string.lower(value)
    if string.find(name, "zombie", 1, true) then
        return "Zombie"
    end
    if string.find(name, "parasite", 1, true) then
        return "Parasite"
    end
    return nil
end

local function getExcludedHostileMarker(model)
    if not model or not model:IsA("Model") then
        return nil
    end

    local marker = markerFromText(model.Name)
    if marker then
        return marker
    end

    local function inspectAttributes(instance)
        local ok, attributes = pcall(function()
            return instance:GetAttributes()
        end)
        if ok and type(attributes) == "table" then
            for key, value in pairs(attributes) do
                marker = markerFromText(key) or markerFromText(value)
                if marker then
                    return marker
                end
            end
        end
        return nil
    end

    marker = inspectAttributes(model)
    if marker then
        return marker
    end

    for _, descendant in ipairs(model:GetDescendants()) do
        marker = markerFromText(descendant.Name)
        if marker then
            return marker
        end

        if descendant:IsA("StringValue") then
            local value
            pcall(function() value = descendant.Value end)
            marker = markerFromText(value)
            if marker then
                return marker
            end
        end

        if descendant:IsA("Model") or descendant:IsA("Folder") or descendant:IsA("ValueBase") then
            marker = inspectAttributes(descendant)
            if marker then
                return marker
            end
        end
    end
    return nil
end

local function hasZombieMarker(model)
    return getExcludedHostileMarker(model) == "Zombie"
end

local function hasParasiteMarker(model)
    return getExcludedHostileMarker(model) == "Parasite"
end

local function hasExcludedHostileMarker(model)
    return getExcludedHostileMarker(model) ~= nil
end

local function isAlienModel(model)
    if not model or not model:IsA("Model") or hasExcludedHostileMarker(model) then
        return nil
    end
    local variantNames = {
        alientype1 = "AlienType1",
        alientype2 = "AlienType2",
        alientype3 = "AlienType3",
    }
    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("Model") or descendant:IsA("Folder") then
            local lowerName = string.lower(descendant.Name)
            if variantNames[lowerName] then
                return variantNames[lowerName]
            end
        end
    end
    return nil
end

local function getModelRoot(model)
    if not model then
        return nil
    end
    return model:FindFirstChild("HumanoidRootPart")
        or model.PrimaryPart
        or model:FindFirstChild("Torso", true)
        or model:FindFirstChild("Head", true)
end

local function getNearestNonAlienEntityWithin(position, radius)
    if not ENTITY_CONTAINER or not position then
        return nil
    end
    local nearest = nil
    for _, model in ipairs(ENTITY_CONTAINER:GetChildren()) do
        if model:IsA("Model") and not isAlienModel(model) then
            local entityRoot = getModelRoot(model) or model:FindFirstChildWhichIsA("BasePart", true)
            if entityRoot and entityRoot.Parent then
                local distance = (entityRoot.Position - position).Magnitude
                if distance <= radius and (not nearest or distance < nearest.distance) then
                    nearest = {
                        model = model,
                        root = entityRoot,
                        distance = distance,
                        marker = getExcludedHostileMarker(model) or "UnknownNonAlien",
                    }
                end
            end
        end
    end
    return nearest
end

local function isModelAlive(model)
    if not model or not model.Parent or serverDeadAlienModels[model] then
        return false
    end
    local monitoredRecord = monitoredAliens[model]
    if monitoredRecord and (monitoredRecord.dead or monitoredRecord.serverDead) then
        return false
    end
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.Health <= 0 then
        return false
    end
    local healthAttribute = model:GetAttribute("Health")
    if type(healthAttribute) == "number" and healthAttribute <= 0 then
        return false
    end
    return getModelRoot(model) ~= nil
end

local function isAlienConfirmedDead(model)
    if not model then return false end
    if serverDeadAlienModels[model] then return true end
    local record = monitoredAliens[model]
    if record then
        if record.serverDead or record.dead then return true end
        if tonumber(record.lastHealthValue) and tonumber(record.lastHealthValue) <= 0 then return true end
    end
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.Health <= 0 then return true end
    local healthAttribute = model:GetAttribute("Health")
    return type(healthAttribute) == "number" and healthAttribute <= 0
end

local function getAliensNear(position, radius)
    local results = {}
    if not ENTITY_CONTAINER or not position then
        return results
    end
    for _, model in ipairs(ENTITY_CONTAINER:GetChildren()) do
        local variant = isAlienModel(model)
        if variant and not hasExcludedHostileMarker(model) and isModelAlive(model) then
            local root = getModelRoot(model)
            if root then
                local distance = (root.Position - position).Magnitude
                if distance <= radius then
                    table.insert(results, {
                        model = model,
                        root = root,
                        variant = variant,
                        distance = distance,
                    })
                end
            end
        end
    end
    table.sort(results, function(a, b)
        return a.distance < b.distance
    end)
    return results
end

local function getTrackedClusterEntries(position, radius, trackedMembers)
    local results = getAliensNear(position, radius)
    local seen = {}
    for _, entry in ipairs(results) do
        seen[entry.model] = true
        if trackedMembers then
            trackedMembers[entry.model] = entry.root.Position
        end
    end

    for model, lastPosition in pairs(trackedMembers or {}) do
        if model and not seen[model] and model.Parent == ENTITY_CONTAINER then
            local variant = isAlienModel(model)
            if variant and not hasExcludedHostileMarker(model) and isModelAlive(model) then
                local root = getModelRoot(model)
                if root and root.Parent then
                    local distance = (root.Position - position).Magnitude
                    table.insert(results, {
                        model = model,
                        root = root,
                        variant = variant,
                        distance = distance,
                        trackedOutsideScanRadius = distance > radius,
                    })
                    trackedMembers[model] = root.Position
                end
            end
        end
    end

    table.sort(results, function(a, b)
        return a.distance < b.distance
    end)
    return results
end

-- HF4: observe client-visible alien health without changing game state.
local function isHealthValueName(name)
    local lower = string.lower(tostring(name or ""))
    local normalized = string.gsub(lower, "[%s_%-]", "")
    if string.find(normalized, "maxhealth", 1, true) or string.find(normalized, "maxhp", 1, true)
        or string.find(normalized, "maxhitpoint", 1, true) then
        return false
    end
    return normalized == "health"
        or normalized == "hp"
        or normalized == "currenthealth"
        or normalized == "currenthp"
        or normalized == "healthvalue"
        or normalized == "hpvalue"
        or normalized == "healthpercent"
        or normalized == "hppercent"
        or normalized == "healthratio"
        or normalized == "hitpoints"
        or normalized == "currenthitpoints"
        or normalized == "hitpoint"
        or normalized == "currenthitpoint"
        or normalized == "healthnow"
        or normalized == "hpnow"
        or string.find(normalized, "currenthealth", 1, true) ~= nil
        or string.find(normalized, "currenthp", 1, true) ~= nil
end

local function hasHealthNamedAncestor(instance, model)
    local current = instance and instance.Parent
    while current and current ~= model do
        local normalized = string.gsub(string.lower(tostring(current.Name or "")), "[%s_%-]", "")
        if string.find(normalized, "health", 1, true) or normalized == "hp" or string.find(normalized, "hitpoint", 1, true) then
            return true
        end
        current = current.Parent
    end
    return false
end

local function getAlienDamageAttribution(model)
    local now = os.clock()
    local manualToolAge = lastManualToolActivationAt and (now - lastManualToolActivationAt) or math.huge
    local manualInputAge = lastManualInputAt and (now - lastManualInputAt) or math.huge
    local manualAge = math.min(manualToolAge, manualInputAge)
    local autoAge = lastAutoHitByModel[model] and (now - lastAutoHitByModel[model]) or math.huge
    if manualAge <= 1.25 and autoAge <= 1.25 then
        return "AMBIGUOUS: manual input/native activation and farmer Hit requests both occurred recently"
    elseif manualToolAge <= 1.25 and manualInputAge <= 1.25 then
        return "Mouse/touch input plus native Tool.Activated recently (timing correlation only)"
    elseif manualAge <= 1.25 then
        return "Recent manual mouse/touch input or native Tool.Activated (timing correlation only)"
    elseif autoAge <= 1.25 then
        return "Farmer sent a Hit request to this alien recently (timing correlation only)"
    elseif lastAutoAttackAt and (now - lastAutoAttackAt) <= 1.25 then
        return "Farmer Attack request was recent, but no per-alien Hit correlation (not proof)"
    end
    return "Unattributed: no recent monitored tool activation or farmer hit request"
end

local function markAlienDead(record, reason)
    if not record or record.dead then
        return
    end
    record.dead = true
    alienDeathEvents = alienDeathEvents + 1
    recordEvent("KILL", "Alien death signal observed", "Variant=" .. tostring(record.variant)
        .. " | Model=" .. tostring(record.model.Name) .. " | Signal=" .. tostring(reason)
        .. " | Death is client-observed, not independently server-verified")
end

local function recordAlienHealthChange(record, sourceKey, oldValue, newValue)
    oldValue = tonumber(oldValue)
    newValue = tonumber(newValue)
    if not oldValue or not newValue or math.abs(newValue - oldValue) < 0.001 then
        return
    end

    record.lastHealthValue = newValue
    record.lastHealthDelta = newValue - oldValue
    record.lastHealthSource = tostring(sourceKey)
    record.lastHealthChangeAt = os.clock()
    record.lastHealthAttribution = getAlienDamageAttribution(record.model)

    if newValue < oldValue then
        local amount = oldValue - newValue
        alienDamageEvents = alienDamageEvents + 1
        recordEvent("DAMAGE", "Alien health decreased", string.format(
            "Variant=%s | Model=%s | Source=%s | Health=%.3f->%.3f | Damage=%.3f | Attribution=%s | ManualInput=%s | Paused=%s",
            tostring(record.variant), tostring(record.model.Name), tostring(sourceKey),
            oldValue, newValue, amount, tostring(record.lastHealthAttribution), tostring(lastManualInputKind), tostring(paused)
        ))
    else
        recordEvent("HEAL", "Alien health increased", string.format(
            "Variant=%s | Model=%s | Source=%s | Health=%.3f->%.3f | Change=+%.3f",
            tostring(record.variant), tostring(record.model.Name), tostring(sourceKey),
            oldValue, newValue, newValue - oldValue
        ))
    end

    if newValue <= 0 then
        markAlienDead(record, sourceKey .. " reached zero")
    end
end

local function attachNumericAlienHealthSource(record, sourceKey, initialValue, connectCallback)
    if not record or record.sources[sourceKey] ~= nil then
        return
    end
    local initialNumber = tonumber(initialValue)
    if not initialNumber then
        return
    end
    record.sources[sourceKey] = initialNumber
    record.sourceCount = record.sourceCount + 1
    alienHealthSourcesFound = alienHealthSourcesFound + 1
    recordEvent("NPC_HEALTH", "Alien numeric health source attached", string.format(
        "Variant=%s | Model=%s | Source=%s | InitialValue=%.3f",
        tostring(record.variant), tostring(record.model.Name), tostring(sourceKey), initialNumber
    ))
    if initialNumber <= 0 then
        markAlienDead(record, sourceKey .. " was already zero when monitored")
    end

    local ok, connection = pcall(connectCallback, function(newValue)
        local currentNumber = tonumber(newValue)
        if not currentNumber then
            return
        end
        local previousNumber = record.sources[sourceKey]
        record.sources[sourceKey] = currentNumber
        recordAlienHealthChange(record, sourceKey, previousNumber, currentNumber)
    end)
    if ok and connection then
        table.insert(record.connections, connection)
    elseif not ok then
        recordEvent("ERROR", "Alien health source connection failed", "Source=" .. tostring(sourceKey) .. " | Error=" .. tostring(connection))
    end
end

local function parseHealthText(textValue)
    local text = tostring(textValue or "")
    local current, maximum = string.match(text, "([%d%.]+)%s*/%s*([%d%.]+)")
    if current then
        return tonumber(current), tonumber(maximum)
    end
    local percent = string.match(text, "([%d%.]+)%s*%%")
    if percent then
        return tonumber(percent), 100
    end
    local labelled = string.match(text, "[Hh][Pp]?%s*[:=]%s*([%d%.]+)")
        or string.match(text, "[Hh]ealth%s*[:=]%s*([%d%.]+)")
    if labelled then
        return tonumber(labelled), nil
    end
    if string.match(text, "^%s*[%d%.]+%s*$") then
        return tonumber(text), nil
    end
    return nil, nil
end

local function findHealthBarAncestor(instance, model)
    local current = instance
    while current and current ~= model do
        local lower = string.lower(tostring(current.Name or ""))
        local normalized = string.gsub(lower, "[%s_%-]", "")
        if string.find(normalized, "healthbar", 1, true) or normalized == "hpbar" then
            return current
        end
        current = current.Parent
    end
    return nil
end

local function attachAlienHealthUi(record, instance)
    if not record or not instance or record.uiSources[instance] then
        return
    end
    local barRoot = findHealthBarAncestor(instance, record.model)
    if not barRoot then
        return
    end

    local isBillboard = instance:IsA("BillboardGui") or instance:IsA("SurfaceGui")
    local isGuiObject = instance:IsA("GuiObject")
    local isTextObject = instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox")
    if not isBillboard and not isGuiObject then
        return
    end

    record.uiSources[instance] = true
    local path = "unknown"
    pcall(function() path = instance:GetFullName() end)

    if isBillboard then
        local enabledValue = false
        pcall(function() enabledValue = instance.Enabled end)
        recordEvent("NPC_UI", "Alien health-bar container observed", "Variant=" .. tostring(record.variant)
            .. " | Model=" .. tostring(record.model.Name) .. " | Enabled=" .. tostring(enabledValue)
            .. " | Path=" .. path)
        local ok, connection = pcall(function()
            return instance:GetPropertyChangedSignal("Enabled"):Connect(function()
                local newValue = instance.Enabled
                alienHealthUiEvents = alienHealthUiEvents + 1
                recordEvent("NPC_UI", "Alien health-bar visibility changed", "Model=" .. tostring(record.model.Name)
                    .. " | Enabled=" .. tostring(newValue) .. " | Path=" .. path)
            end)
        end)
        if ok and connection then table.insert(record.connections, connection) end
    end

    if isGuiObject then
        local previousSize = instance.Size
        local ok, connection = pcall(function()
            return instance:GetPropertyChangedSignal("Size"):Connect(function()
                local newSize = instance.Size
                if newSize ~= previousSize then
                    local oldWidth = previousSize.X.Scale + previousSize.X.Offset / 100000
                    local newWidth = newSize.X.Scale + newSize.X.Offset / 100000
                    local oldHeight = previousSize.Y.Scale + previousSize.Y.Offset / 100000
                    local newHeight = newSize.Y.Scale + newSize.Y.Offset / 100000
                    alienHealthUiEvents = alienHealthUiEvents + 1
                    local direction = (newWidth < oldWidth or newHeight < oldHeight) and "shrunk (possible damage indicator)" or "changed"
                    local widthDrop = oldWidth - newWidth
                    local isForegroundHealthBar = string.lower(instance.Name) == "bar"
                        and string.find(string.lower(path), "healthbar.frame.bar", 1, true) ~= nil

                    if isForegroundHealthBar and widthDrop > 0.001 then
                        local attribution = getAlienDamageAttribution(record.model)
                        record.lastUiDamageAt = os.clock()
                        record.lastUiDamageDelta = widthDrop
                        record.lastUiDamageAttribution = attribution
                        if string.find(attribution, "Farmer sent a Hit request", 1, true) ~= nil then
                            record.lastAutoUiDamageAt = record.lastUiDamageAt
                            record.lastAutoUiDamageDelta = widthDrop
                            record.lastAutoUiDamageAttribution = attribution
                            automatedDamageUiEvents = automatedDamageUiEvents + 1
                            recordEvent("DAMAGE_UI", "Alien foreground health bar decreased after farmer Hit request", string.format(
                                "Variant=%s | Model=%s | WidthDrop=%.5f | OldWidth=%.5f | NewWidth=%.5f | Attribution=%s | Path=%s",
                                tostring(record.variant), tostring(record.model.Name), widthDrop, oldWidth, newWidth, attribution, path
                            ))
                        else
                            recordThrottled("alien-health-ui-size:" .. path, 0.08, "NPC_UI", "Alien health-bar GUI size " .. direction,
                                "Model=" .. tostring(record.model.Name) .. " | Object=" .. tostring(instance.Name)
                                .. " | OldSize=" .. tostring(previousSize) .. " | NewSize=" .. tostring(newSize)
                                .. " | Attribution=" .. attribution .. " | Path=" .. path)
                        end
                    else
                        recordThrottled("alien-health-ui-size:" .. path, 0.08, "NPC_UI", "Alien health-bar GUI size " .. direction,
                            "Model=" .. tostring(record.model.Name) .. " | Object=" .. tostring(instance.Name)
                            .. " | OldSize=" .. tostring(previousSize) .. " | NewSize=" .. tostring(newSize) .. " | Path=" .. path)
                    end
                    previousSize = newSize
                end
            end)
        end)
        if ok and connection then table.insert(record.connections, connection) end
    end

    if isGuiObject then
        local previousVisible = instance.Visible
        local visibleOk, visibleConnection = pcall(function()
            return instance:GetPropertyChangedSignal("Visible"):Connect(function()
                local currentVisible = instance.Visible
                if currentVisible ~= previousVisible then
                    alienHealthUiEvents = alienHealthUiEvents + 1
                    recordEvent("NPC_UI", "Alien health-bar GUI visibility changed", "Model=" .. tostring(record.model.Name)
                        .. " | Object=" .. tostring(instance.Name) .. " | Old=" .. tostring(previousVisible)
                        .. " | New=" .. tostring(currentVisible) .. " | Path=" .. path)
                    previousVisible = currentVisible
                end
            end)
        end)
        if visibleOk and visibleConnection then table.insert(record.connections, visibleConnection) end
    end

    if isTextObject then
        local sourceKey = "HealthBarText:" .. path
        local initialCurrent, initialMaximum = parseHealthText(instance.Text)
        if initialMaximum then
            record.maxHealthSources[sourceKey] = initialMaximum
        end
        if initialCurrent then
            attachNumericAlienHealthSource(record, sourceKey, initialCurrent, function(callback)
                return instance:GetPropertyChangedSignal("Text"):Connect(function()
                    local current, maximum = parseHealthText(instance.Text)
                    if maximum then record.maxHealthSources[sourceKey] = maximum end
                    if current then callback(current) end
                end)
            end)
        else
            local previousText = tostring(instance.Text or "")
            local ok, connection = pcall(function()
                return instance:GetPropertyChangedSignal("Text"):Connect(function()
                    local currentText = tostring(instance.Text or "")
                    if currentText ~= previousText then
                        local currentNumeric, currentMaximum = parseHealthText(currentText)
                        if currentMaximum then record.maxHealthSources[sourceKey] = currentMaximum end
                        if currentNumeric then
                            if record.sources[sourceKey] ~= nil then
                                local oldNumeric = record.sources[sourceKey]
                                record.sources[sourceKey] = currentNumeric
                                recordAlienHealthChange(record, sourceKey, oldNumeric, currentNumeric)
                            else
                                record.sources[sourceKey] = currentNumeric
                                record.sourceCount = record.sourceCount + 1
                                alienHealthSourcesFound = alienHealthSourcesFound + 1
                                recordEvent("NPC_HEALTH", "Numeric health-bar text source became available", "Model=" .. tostring(record.model.Name)
                                    .. " | Source=" .. sourceKey .. " | InitialValue=" .. tostring(currentNumeric))
                            end
                        else
                            alienHealthUiEvents = alienHealthUiEvents + 1
                            recordThrottled("alien-health-ui-text:" .. path, 0.1, "NPC_UI", "Alien health-bar text changed",
                                "Model=" .. tostring(record.model.Name) .. " | Old=" .. previousText
                                .. " | New=" .. currentText .. " | Path=" .. path)
                        end
                        previousText = currentText
                    end
                end)
            end)
            if ok and connection then table.insert(record.connections, connection) end
        end
    end
end

local function inspectAlienHealthInstance(record, instance)
    if not record or not instance then
        return
    end

    if instance:IsA("Humanoid") then
        local humanoidPath = tostring(instance:GetFullName())
        local maxHealthKey = "Humanoid.MaxHealth:" .. humanoidPath
        if record.maxHealthSources[maxHealthKey] == nil then
            record.maxHealthSources[maxHealthKey] = instance.MaxHealth
            recordEvent("NPC_HEALTH", "Alien Humanoid max-health baseline", "Variant=" .. tostring(record.variant)
                .. " | Model=" .. tostring(record.model.Name) .. " | MaxHealth=" .. tostring(instance.MaxHealth)
                .. " | Path=" .. humanoidPath)
            local maxOk, maxConnection = pcall(function()
                local previousMax = instance.MaxHealth
                return instance:GetPropertyChangedSignal("MaxHealth"):Connect(function()
                    local currentMax = instance.MaxHealth
                    if currentMax ~= previousMax then
                        recordEvent("NPC_HEALTH", "Alien Humanoid MaxHealth changed", "Model=" .. tostring(record.model.Name)
                            .. " | Old=" .. tostring(previousMax) .. " | New=" .. tostring(currentMax) .. " | Path=" .. humanoidPath)
                        previousMax = currentMax
                        record.maxHealthSources[maxHealthKey] = currentMax
                    end
                end)
            end)
            if maxOk and maxConnection then table.insert(record.connections, maxConnection) end
        end
        attachNumericAlienHealthSource(record, "Humanoid.Health:" .. humanoidPath, instance.Health, function(callback)
            return instance.HealthChanged:Connect(callback)
        end)
        if not record.humanoidDeathSignals[instance] then
            record.humanoidDeathSignals[instance] = true
            local ok, connection = pcall(function()
                return instance.Died:Connect(function()
                    markAlienDead(record, "Humanoid.Died")
                end)
            end)
            if ok and connection then table.insert(record.connections, connection) end
        end
    end

    local attributes = {}
    pcall(function() attributes = instance:GetAttributes() end)
    for attributeName, attributeValue in pairs(attributes) do
        if (isHealthValueName(attributeName) or (string.lower(tostring(attributeName)) == "value" and hasHealthNamedAncestor(instance, record.model))) and tonumber(attributeValue) then
            local sourceKey = "Attribute:" .. tostring(instance.Name) .. "." .. tostring(attributeName)
            attachNumericAlienHealthSource(record, sourceKey, attributeValue, function(callback)
                return instance:GetAttributeChangedSignal(attributeName):Connect(function()
                    callback(instance:GetAttribute(attributeName))
                end)
            end)
        end
    end
    if not record.attributeWatchers[instance] then
        record.attributeWatchers[instance] = true
        local attributeOk, attributeConnection = pcall(function()
            return instance.AttributeChanged:Connect(function(attributeName)
                if isHealthValueName(attributeName) or (string.lower(tostring(attributeName)) == "value" and hasHealthNamedAncestor(instance, record.model)) then
                    local currentValue = instance:GetAttribute(attributeName)
                    if tonumber(currentValue) then
                        local sourceKey = "Attribute:" .. tostring(instance.Name) .. "." .. tostring(attributeName)
                        attachNumericAlienHealthSource(record, sourceKey, currentValue, function(callback)
                            return instance:GetAttributeChangedSignal(attributeName):Connect(function()
                                callback(instance:GetAttribute(attributeName))
                            end)
                        end)
                    end
                end
            end)
        end)
        if attributeOk and attributeConnection then table.insert(record.connections, attributeConnection) end
    end

    if instance:IsA("ValueBase") and (isHealthValueName(instance.Name) or (string.lower(tostring(instance.Name)) == "value" and hasHealthNamedAncestor(instance, record.model))) then
        local sourceKey = "ValueObject:" .. tostring(instance:GetFullName())
        attachNumericAlienHealthSource(record, sourceKey, instance.Value, function(callback)
            return instance:GetPropertyChangedSignal("Value"):Connect(function()
                callback(instance.Value)
            end)
        end)
    end

    attachAlienHealthUi(record, instance)
end

local function monitorAlienModel(model)
    if not model or not model:IsA("Model") or monitoredAliens[model] then
        return
    end
    local variant = isAlienModel(model)
    if not variant then
        return
    end

    local initialRoot = getModelRoot(model)
    local record = {
        model = model,
        variant = variant,
        lastKnownPosition = initialRoot and initialRoot.Position or nil,
        sources = {},
        maxHealthSources = {},
        sourceCount = 0,
        uiSources = {},
        humanoidDeathSignals = {},
        attributeWatchers = {},
        connections = {},
        dead = false,
        removed = false,
        lastHealthValue = nil,
        lastHealthDelta = nil,
        lastHealthSource = nil,
        lastHealthAttribution = nil,
        lastHealthChangeAt = nil,
        lastUiDamageAt = nil,
        lastUiDamageDelta = nil,
        lastUiDamageAttribution = nil,
        lastAutoUiDamageAt = nil,
        lastAutoUiDamageDelta = nil,
        lastAutoUiDamageAttribution = nil,
    }
    monitoredAliens[model] = record
    monitoredAlienModelsTotal = monitoredAlienModelsTotal + 1

    inspectAlienHealthInstance(record, model)
    for _, descendant in ipairs(model:GetDescendants()) do
        inspectAlienHealthInstance(record, descendant)
    end

    local addedOk, addedConnection = pcall(function()
        return model.DescendantAdded:Connect(function(descendant)
            inspectAlienHealthInstance(record, descendant)
        end)
    end)
    if addedOk and addedConnection then table.insert(record.connections, addedConnection) end

    local ancestryOk, ancestryConnection = pcall(function()
        return model.AncestryChanged:Connect(function(_, parent)
            if not parent and not record.removed then
                record.removed = true
                recordEvent("NPC_LIFECYCLE", "Alien model removed from Workspace", "Variant=" .. tostring(record.variant)
                    .. " | Model=" .. tostring(model.Name) .. " | HealthDeathConfirmed=" .. tostring(record.dead)
                    .. " | Removal alone is not counted as a kill")
            end
        end)
    end)
    if ancestryOk and ancestryConnection then table.insert(record.connections, ancestryConnection) end

    local destroyingOk, destroyingConnection = pcall(function()
        return model.Destroying:Connect(function()
            if not record.removed then
                record.removed = true
                recordEvent("NPC_LIFECYCLE", "Alien model Destroying signal", "Variant=" .. tostring(record.variant)
                    .. " | Model=" .. tostring(model.Name) .. " | HealthDeathConfirmed=" .. tostring(record.dead)
                    .. " | Destruction alone is not counted as a kill")
            end
        end)
    end)
    if destroyingOk and destroyingConnection then table.insert(record.connections, destroyingConnection) end

    if record.sourceCount == 0 then
        recordEvent("NPC_HEALTH", "No numeric alien health source found at monitor attach", "Variant=" .. tostring(variant)
            .. " | Model=" .. tostring(model.Name) .. " | HealthBarUI=" .. tostring(next(record.uiSources) ~= nil)
            .. " | Watching new descendants, attributes, value objects, health-bar UI and removal")
    else
        recordEvent("NPC_HEALTH", "Alien health monitor attached", "Variant=" .. tostring(variant)
            .. " | Model=" .. tostring(model.Name) .. " | NumericSources=" .. tostring(record.sourceCount)
            .. " | HealthBarUI=" .. tostring(next(record.uiSources) ~= nil))
    end
end

local function startAlienHealthMonitoring()
    if not ENTITY_CONTAINER then
        recordEvent("ERROR", "Alien health monitor could not start", "ENTITY_CONTAINER is missing")
        return
    end
    for _, model in ipairs(ENTITY_CONTAINER:GetChildren()) do
        task.spawn(function()
            for attempt = 1, 20 do
                if not model or model.Parent ~= ENTITY_CONTAINER then
                    return
                end
                if isAlienModel(model) then
                    monitorAlienModel(model)
                    return
                end
                task.wait(0.1)
            end
        end)
    end
    ENTITY_CONTAINER.ChildAdded:Connect(function(model)
        task.spawn(function()
            for attempt = 1, 20 do
                if not model or model.Parent ~= ENTITY_CONTAINER then
                    return
                end
                if isAlienModel(model) then
                    monitorAlienModel(model)
                    return
                end
                task.wait(0.1)
            end
            recordThrottled("alien-monitor-unclassified:" .. tostring(model.Name), 5, "NPC_HEALTH", "New entity did not expose an AlienType1/2/3 marker during monitor window", "Model=" .. tostring(model.Name))
        end)
    end)
    recordEvent("NPC_HEALTH", "Alien health monitoring active", "Container=Workspace.ENTITY_CONTAINER | ExistingModels="
        .. tostring(monitoredAlienModelsTotal) .. " | Mode=Humanoid/attributes/ValueBase/HealthBar UI/despawn observation")
end

local function classifyAlienHitPart(part, model)
    if not part or not part:IsA("BasePart") or not model then
        return nil
    end

    local lowerName = string.lower(part.Name)
    local blockedNames = {
        ["humanoidrootpart"] = true,
        ["entitydetector"] = true,
        ["handle"] = true,
        ["sword"] = true,
        ["blade"] = true,
        ["hitbox"] = true,
    }
    if blockedNames[lowerName] then
        return nil
    end

    local ancestor = part.Parent
    while ancestor and ancestor ~= model do
        if ancestor:IsA("Accessory") or ancestor:IsA("Tool") then
            return nil
        end
        local ancestorName = string.lower(ancestor.Name)
        if ancestorName == "sword" or ancestorName == "blade"
            or ancestorName == "weapon" or ancestorName == "accessories" then
            return nil
        end
        ancestor = ancestor.Parent
    end

    local fullPath = string.lower(part:GetFullName())
    local inAlienDress = string.find(fullPath, ".dress.alientype", 1, true) ~= nil
    local inTorsoFolder = inAlienDress and string.find(fullPath, ".torso.", 1, true) ~= nil
    local inArmFolder = string.find(fullPath, ".left arm.", 1, true) ~= nil
        or string.find(fullPath, ".right arm.", 1, true) ~= nil
        or string.find(fullPath, ".upperarm.", 1, true) ~= nil
        or string.find(fullPath, ".lowerarm.", 1, true) ~= nil
    local inHeadFolder = string.find(fullPath, ".head.", 1, true) ~= nil
    local inLegFolder = string.find(fullPath, ".left leg.", 1, true) ~= nil
        or string.find(fullPath, ".right leg.", 1, true) ~= nil
        or string.find(fullPath, ".upperleg.", 1, true) ~= nil
        or string.find(fullPath, ".lowerleg.", 1, true) ~= nil

    if inTorsoFolder and (lowerName == "cylinder.008" or lowerName == "alien.008") then
        return 0, "TORSO_MESH"
    end
    if inTorsoFolder or lowerName == "torso" or lowerName == "uppertorso" or lowerName == "lowertorso" then
        return 1, "TORSO"
    end
    if inArmFolder or inHeadFolder or lowerName == "right arm" or lowerName == "left arm"
        or lowerName == "head" or lowerName == "upperarm" or lowerName == "lowerarm"
        or lowerName == "alien.008" or lowerName == "cylinder.008" then
        return 2, (inHeadFolder or lowerName == "head") and "HEAD" or "ARM"
    end
    if inLegFolder or lowerName == "right leg" or lowerName == "left leg"
        or lowerName == "upperleg" or lowerName == "lowerleg" then
        return 3, "LEG"
    end
    return nil
end

local function getPreferredTorsoAnchor(model)
    if not model then
        return nil
    end
    local modelRoot = getModelRoot(model)
    local origin = modelRoot and modelRoot.Position or Vector3.zero
    local bestPart = nil
    local bestPriority = math.huge
    local bestDistance = math.huge

    for _, descendant in ipairs(model:GetDescendants()) do
        local priority, partClass = classifyAlienHitPart(descendant, model)
        if priority ~= nil and priority <= 1 then
            local distance = (descendant.Position - origin).Magnitude
            if priority < bestPriority or (priority == bestPriority and distance < bestDistance) then
                bestPart = descendant
                bestPriority = priority
                bestDistance = distance
            end
        end
    end
    return bestPart
end

local function getClosestMeleeContact(model, origin, maxDistance)
    if not model or not origin then
        return nil
    end

    -- Select by body-part class first, not just nearest center. The HF5.9
    -- distance-only selector repeatedly chose a leg while torso meshes existed.
    -- Priority: captured torso meshes, torso parts, arms/head, then legs.
    local bestContact = nil
    local counts = { torso = 0, armHead = 0, leg = 0 }
    local nearestTorsoDistance = nil
    local nearestArmHeadDistance = nil
    local nearestLegDistance = nil

    for _, descendant in ipairs(model:GetDescendants()) do
        local priority, partClass = classifyAlienHitPart(descendant, model)
        if priority ~= nil then
            local partPosition = descendant.Position
            local distance = (partPosition - origin).Magnitude
            if priority <= 1 then
                counts.torso = counts.torso + 1
                if not nearestTorsoDistance or distance < nearestTorsoDistance then
                    nearestTorsoDistance = distance
                end
            elseif priority == 2 then
                counts.armHead = counts.armHead + 1
                if not nearestArmHeadDistance or distance < nearestArmHeadDistance then
                    nearestArmHeadDistance = distance
                end
            else
                counts.leg = counts.leg + 1
                if not nearestLegDistance or distance < nearestLegDistance then
                    nearestLegDistance = distance
                end
            end

            if (maxDistance == nil or distance <= maxDistance) then
                -- Contact distance is the primary constraint. Prefer a torso only
                -- when it is nearly as close as the nearest limb; otherwise a
                -- farther torso can move outside the 10-stud limit during the
                -- measured Attack -> Hit delay while a nearer leg was usable.
                local replaceContact = not bestContact
                if bestContact then
                    local distanceAdvantage = bestContact.distance - distance
                    if distanceAdvantage > 0.75 then
                        replaceContact = true
                    elseif math.abs(distanceAdvantage) <= 0.75 and priority < bestContact.priority then
                        replaceContact = true
                    end
                end
                if replaceContact then
                    bestContact = {
                        part = descendant,
                        position = partPosition,
                        normal = Vector3.new(0, 1, 0),
                        material = descendant.Material,
                        distance = distance,
                        priority = priority,
                        partClass = partClass,
                    }
                end
            end
        end
    end

    local selected = bestContact and (bestContact.part.Name .. "/" .. bestContact.partClass) or "none"
    recordThrottled(
        "melee-hitbox-audit:" .. tostring(model.Name),
        0.75,
        "COMBAT",
        "Alien hitbox priority audit",
        string.format(
            "Target=%s | TorsoParts=%d | ArmHeadParts=%d | LegParts=%d | NearestTorso=%s | NearestArmHead=%s | NearestLeg=%s | Selected=%s | SelectedPriority=%s | MaxDistance=%.1f",
            tostring(model.Name), counts.torso, counts.armHead, counts.leg,
            nearestTorsoDistance and string.format("%.2f", nearestTorsoDistance) or "none",
            nearestArmHeadDistance and string.format("%.2f", nearestArmHeadDistance) or "none",
            nearestLegDistance and string.format("%.2f", nearestLegDistance) or "none",
            selected,
            bestContact and tostring(bestContact.priority) or "none",
            tonumber(maxDistance) or 0
        )
    )
    return bestContact
end

local function getNearestEntry(entries)
    local nearest = nil
    local bestDistance = math.huge
    local _, root = getCharacter()
    if not root then
        return nil
    end
    for _, entry in ipairs(entries) do
        if entry.root and entry.root.Parent then
            local distance = (entry.root.Position - root.Position).Magnitude
            if distance < bestDistance then
                bestDistance = distance
                nearest = entry
            end
        end
    end
    return nearest
end

local function applyFullbright()
    if not CONFIG.AUTO_FULLBRIGHT or fullbrightApplied then
        return
    end
    local ok = pcall(function()
        originalLighting.Brightness = Lighting.Brightness
        originalLighting.ClockTime = Lighting.ClockTime
        originalLighting.FogEnd = Lighting.FogEnd
        originalLighting.GlobalShadows = Lighting.GlobalShadows
        originalLighting.Ambient = Lighting.Ambient
        originalLighting.OutdoorAmbient = Lighting.OutdoorAmbient
        Lighting.Brightness = 2
        Lighting.ClockTime = 14
        Lighting.FogEnd = 100000
        Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.new(1, 1, 1)
        Lighting.OutdoorAmbient = Color3.new(1, 1, 1)
    end)
    fullbrightApplied = ok
    if ok then
        recordEvent("VISUAL", "Fullbright applied", "Brightness=2 | ClockTime=14 | FogEnd=100000 | GlobalShadows=false")
    else
        recordEvent("ERROR", "Fullbright application failed", "Lighting properties could not be updated")
    end
end

local function restoreFullbright()
    if not fullbrightApplied then
        return
    end
    pcall(function()
        if originalLighting.Brightness ~= nil then Lighting.Brightness = originalLighting.Brightness end
        if originalLighting.ClockTime ~= nil then Lighting.ClockTime = originalLighting.ClockTime end
        if originalLighting.FogEnd ~= nil then Lighting.FogEnd = originalLighting.FogEnd end
        if originalLighting.GlobalShadows ~= nil then Lighting.GlobalShadows = originalLighting.GlobalShadows end
        if originalLighting.Ambient ~= nil then Lighting.Ambient = originalLighting.Ambient end
        if originalLighting.OutdoorAmbient ~= nil then Lighting.OutdoorAmbient = originalLighting.OutdoorAmbient end
    end)
    fullbrightApplied = false
    recordEvent("VISUAL", "Original lighting restored", "Fullbright disabled during cleanup")
end

local function setupFlight()
    local character, root, humanoid = getCharacter()
    if not character or not root or not humanoid then
        return false
    end

    if activeCharacter ~= character then
        if activeCharacter then
            for part, oldValue in pairs(collisionSnapshot) do
                if part and part.Parent then
                    pcall(function() part.CanCollide = oldValue end)
                end
            end
        end
        collisionSnapshot = {}
        activeCharacter = character
        activeRoot = root
        activeHumanoid = humanoid
        flyVelocity = nil
        flyGyro = nil
        flightLogRoot = nil
    end

    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart") then
            if collisionSnapshot[descendant] == nil then
                collisionSnapshot[descendant] = descendant.CanCollide
            end
            descendant.CanCollide = false
        end
    end

    humanoid.PlatformStand = true
    root.CanCollide = false

    if not flyVelocity or not flyVelocity.Parent then
        flyVelocity = Instance.new("BodyVelocity")
        flyVelocity.Name = "LSAF_FlyVel"
        flyVelocity.MaxForce = Vector3.new(100000, 100000, 100000)
        flyVelocity.P = 1250
        flyVelocity.Velocity = Vector3.zero
        flyVelocity.Parent = root
    end

    if not flyGyro or not flyGyro.Parent then
        flyGyro = Instance.new("BodyGyro")
        flyGyro.Name = "LSAF_FlyGyro"
        flyGyro.MaxTorque = Vector3.new(100000, 100000, 100000)
        flyGyro.P = 5000
        flyGyro.D = 100
        flyGyro.CFrame = root.CFrame
        flyGyro.Parent = root
    end

    if flightLogRoot ~= root then
        flightLogRoot = root
        recordEvent("FLIGHT", "Flight controllers initialized", "BodyVelocity=LSAF_FlyVel | BodyGyro=LSAF_FlyGyro | PlatformStand=" .. tostring(humanoid.PlatformStand) .. " | RootCanCollide=" .. tostring(root.CanCollide))
    end
    return true
end

local function restoreSafeCamera()
    local state = safeCameraState
    safeCameraState = nil
    if not state then
        return
    end
    local camera = state.camera
    if camera and camera.Parent then
        pcall(function()
            camera.CameraType = state.cameraType
            if state.cameraSubject then
                camera.CameraSubject = state.cameraSubject
            end
            camera.CFrame = state.cframe
            camera.Focus = state.focus
        end)
        recordThrottled("camera-safe-restore", 0.5, "CAMERA", "Default camera restored", "CameraType and CameraSubject returned to their pre-engagement values")
    end
end


local function moveCharacter(position, lookAtPosition, moveReason)
    -- Keep the normal Roblox camera attached to the character, including during safe hover.
    restoreSafeCamera()
    if not setupFlight() then
        return false
    end
    local root = activeRoot
    if not root or not root.Parent then
        return false
    end
    local lookAt = lookAtPosition or (position + Vector3.new(0, 0, -1))
    local targetCFrame = CFrame.lookAt(position, lookAt)
    expectedCharacterMove = {
        position = position,
        at = os.clock(),
        reason = tostring(moveReason or "FARMER_REPOSITION"),
    }
    local ok, moveError = pcall(function()
        root.CFrame = targetCFrame
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        if flyVelocity then
            flyVelocity.Velocity = Vector3.zero
        end
        if flyGyro then
            flyGyro.CFrame = targetCFrame
        end
    end)
    if not ok then
        recordEvent("ERROR", "Character reposition failed", diagTraceback(moveError))
        return false
    end
    local cameraGap = "unknown"
    local camera = Workspace.CurrentCamera
    if camera then
        cameraGap = string.format("%.1f", (camera.CFrame.Position - root.Position).Magnitude)
    end
    recordThrottled("movement-sample", 0.65, "MOVEMENT", "Character repositioned", string.format("Reason=%s | Requested=(%.1f, %.1f, %.1f) | Actual=(%.1f, %.1f, %.1f) | CameraRootGap=%s (informational) | PlatformStand=%s", tostring(moveReason or "FARMER_REPOSITION"), position.X, position.Y, position.Z, root.Position.X, root.Position.Y, root.Position.Z, cameraGap, tostring(activeHumanoid and activeHumanoid.PlatformStand)))
    return true
end

local function moveBelowAlien(entry, hoverBelowOverride)
    if not entry or not entry.root or not entry.root.Parent then return false end

    local targetRootPosition = entry.root.Position
    local record = monitoredAliens[entry.model]
    if record then
        record.lastKnownPosition = targetRootPosition
    end
    local torsoAnchor = getPreferredTorsoAnchor(entry.model)
    local anchorPosition = torsoAnchor and torsoAnchor.Position or targetRootPosition
    local _, playerRoot = getCharacter()
    if not playerRoot then return false end

    -- Keep the root on the torso anchor's exact X/Z. Facing is preserved separately;
    -- it must never create a lateral standoff from the alien.
    local facingVector = Vector3.new(playerRoot.CFrame.LookVector.X, 0, playerRoot.CFrame.LookVector.Z)
    if facingVector.Magnitude < 0.001 then
        facingVector = Vector3.new(0, 0, -1)
    else
        facingVector = facingVector.Unit
    end

    local hoverBelow = tonumber(hoverBelowOverride) or CONFIG.HOVER_BELOW
    local hoverPosition = Vector3.new(anchorPosition.X, anchorPosition.Y - hoverBelow, anchorPosition.Z)
    local horizontalLookAt = hoverPosition + facingVector
    currentTarget = entry.variant .. " / " .. entry.model.Name

    local beforeDistance = (playerRoot.Position - anchorPosition).Magnitude
    local requestedDelta = (playerRoot.Position - hoverPosition).Magnitude
    local moved = true
    if requestedDelta > CONFIG.HOVER_REPOSITION_THRESHOLD then
        moved = moveCharacter(hoverPosition, horizontalLookAt, "SAFE_HOVER_CENTERED_UNDERBODY")
    end

    local _, actualRoot = getCharacter()
    local actualPosition = actualRoot and actualRoot.Position or hoverPosition
    local actualTorsoOffset = actualPosition.Y - anchorPosition.Y
    local actualRootOffset = actualPosition.Y - targetRootPosition.Y
    local actualRootDistance = (actualPosition - targetRootPosition).Magnitude
    local actualAnchorDistance = (actualPosition - anchorPosition).Magnitude
    local horizontalError = Vector3.new(actualPosition.X - anchorPosition.X, 0, actualPosition.Z - anchorPosition.Z).Magnitude
    local camera = Workspace.CurrentCamera
    local cameraType = camera and tostring(camera.CameraType) or "unknown"

    recordThrottled("close-hover-position:" .. tostring(entry.model.Name), 0.35, "TARGET", "Centered underbody hover maintained", string.format(
        "Variant=%s | Model=%s | TorsoAnchor=%s | AnchorPosition=(%.2f, %.2f, %.2f) | RequestedPlayerRoot=(%.2f, %.2f, %.2f) | ActualPlayerRoot=(%.2f, %.2f, %.2f) | ActualTorsoVerticalOffset=%.2f | ActualRootVerticalOffset=%.2f | ActualRootDistance=%.2f | ActualTorsoAnchorDistance=%.2f | HorizontalOffset=%.2f | HorizontalError=%.3f | HoverBelowTorso=%.2f | PreviousAnchorDistance=%.2f | RepositionDelta=%.2f | CharacterMove=%s | CameraType=%s",
        entry.variant, entry.model.Name, torsoAnchor and torsoAnchor:GetFullName() or "root-fallback",
        anchorPosition.X, anchorPosition.Y, anchorPosition.Z,
        hoverPosition.X, hoverPosition.Y, hoverPosition.Z,
        actualPosition.X, actualPosition.Y, actualPosition.Z,
        actualTorsoOffset, actualRootOffset, actualRootDistance, actualAnchorDistance,
        CONFIG.TORSO_HORIZONTAL_STANDOFF, horizontalError,
        hoverBelow, beforeDistance, requestedDelta, tostring(moved), cameraType
    ))
    return moved
end

local function stopHoverTether(reason)
    local wasActive = hoverTetherConnection ~= nil or hoverTetherEntry ~= nil
    if hoverTetherConnection then
        pcall(function() hoverTetherConnection:Disconnect() end)
    end
    hoverTetherConnection = nil
    hoverTetherEntry = nil
    hoverTetherAnchor = nil
    if wasActive then
        recordEvent("MOVEMENT", "Centered underbody tether detached", "Reason=" .. tostring(reason or "unspecified"))
    end
end

local function startHoverTether(entry)
    if not entry or not entry.model or entry.model.Parent ~= ENTITY_CONTAINER
        or not entry.root or not entry.root.Parent then
        return false
    end

    local previousModel = hoverTetherEntry and hoverTetherEntry.model or nil
    hoverTetherEntry = entry
    if previousModel ~= entry.model or not hoverTetherAnchor or not hoverTetherAnchor.Parent then
        hoverTetherAnchor = getPreferredTorsoAnchor(entry.model)
    end

    if hoverTetherConnection then
        if previousModel ~= entry.model then
            recordEvent("MOVEMENT", "Underbody tether target changed",
                "Previous=" .. tostring(previousModel and previousModel.Name or "none")
                    .. " | Current=" .. tostring(entry.model.Name)
                    .. " | HorizontalOffset=0 | VerticalOffset=" .. tostring(CONFIG.HOVER_BELOW))
        end
        return true
    end

    hoverTetherConnection = RunService.Heartbeat:Connect(function()
        if not running or paused then
            stopHoverTether(not running and "FARMER_STOPPED" or "PAUSED")
            return
        end

        local ok, tetherError = pcall(function()
            local targetEntry = hoverTetherEntry
            if not targetEntry or not targetEntry.model or targetEntry.model.Parent ~= ENTITY_CONTAINER then
                stopHoverTether("TARGET_REMOVED")
                return
            end

            local targetRoot = targetEntry.root
            if not targetRoot or not targetRoot.Parent then
                targetRoot = getModelRoot(targetEntry.model)
                targetEntry.root = targetRoot
            end
            if not targetRoot or not targetRoot.Parent then
                stopHoverTether("TARGET_ROOT_MISSING")
                return
            end

            if not hoverTetherAnchor or not hoverTetherAnchor.Parent
                or not hoverTetherAnchor:IsDescendantOf(targetEntry.model) then
                hoverTetherAnchor = getPreferredTorsoAnchor(targetEntry.model)
            end
            local anchor = hoverTetherAnchor or targetRoot
            local anchorPosition = anchor.Position
            local desiredPosition = Vector3.new(
                anchorPosition.X,
                anchorPosition.Y - CONFIG.HOVER_BELOW,
                anchorPosition.Z
            )

            if not activeRoot or not activeRoot.Parent then
                if not setupFlight() then return end
            end
            local root = activeRoot
            if not root or not root.Parent then return end

            local drift = (root.Position - desiredPosition).Magnitude
            if drift > CONFIG.HOVER_TETHER_DEADBAND then
                local desiredCFrame = CFrame.new(desiredPosition) * root.CFrame.Rotation
                expectedCharacterMove = {
                    position = desiredPosition,
                    at = os.clock(),
                    reason = "ALIEN_UNDERBODY_TETHER",
                }
                root.CFrame = desiredCFrame
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
                if flyVelocity and flyVelocity.Parent then
                    flyVelocity.Velocity = Vector3.zero
                end
                if flyGyro and flyGyro.Parent then
                    flyGyro.CFrame = desiredCFrame
                end
            end

            local actualOffset = root.Position - anchorPosition
            local horizontalError = Vector3.new(actualOffset.X, 0, actualOffset.Z).Magnitude
            recordThrottled(
                "underbody-tether:" .. tostring(targetEntry.model.Name),
                0.75,
                "MOVEMENT",
                "Centered underbody tether active",
                string.format(
                    "Target=%s/%s | TorsoAnchor=%s | VerticalOffset=%.2f | HorizontalError=%.3f | DesiredVerticalOffset=%.2f | HeartbeatFollow=true | DriftCorrected=%s",
                    tostring(targetEntry.variant), tostring(targetEntry.model.Name),
                    anchor:GetFullName(), actualOffset.Y, horizontalError,
                    -CONFIG.HOVER_BELOW, tostring(drift > CONFIG.HOVER_TETHER_DEADBAND)
                )
            )
        end)
        if not ok then
            recordThrottled("underbody-tether-error", 1.0, "ERROR", "Underbody tether update failed", diagTraceback(tetherError))
        end
    end)

    recordEvent("MOVEMENT", "Centered underbody tether attached",
        "Target=" .. tostring(entry.variant) .. "/" .. tostring(entry.model.Name)
            .. " | HorizontalOffset=0 | VerticalOffset=" .. tostring(CONFIG.HOVER_BELOW)
            .. " | Update=RunService.Heartbeat | ActiveDuringToolCooldown=true")
    return true
end

local function restoreMovement()
    stopHoverTether("MOVEMENT_RESTORE")
    restoreSafeCamera()
    if activeHumanoid or flyVelocity or flyGyro then
        recordEvent("FLIGHT", "Restoring character movement and collision state", "Emergency stop / cleanup requested")
    end
    if activeHumanoid and activeHumanoid.Parent then
        pcall(function() activeHumanoid.PlatformStand = false end)
    end
    for part, oldValue in pairs(collisionSnapshot) do
        if part and part.Parent then
            pcall(function() part.CanCollide = oldValue end)
        end
    end
    collisionSnapshot = {}
    if flyVelocity then
        pcall(function() flyVelocity:Destroy() end)
        flyVelocity = nil
    end
    if flyGyro then
        pcall(function() flyGyro:Destroy() end)
        flyGyro = nil
    end
    activeCharacter = nil
    activeRoot = nil
    activeHumanoid = nil
end

local function sendMeleeSweep(entries, toolAlreadyReady)
    local character, root = getCharacter()
    if not character or not root or not ReplicaSignal then
        return 0
    end

    -- Preserve the Classic starting Shovel when no tool is equipped, but use
    -- whichever melee Tool is currently equipped once the player changes it.
    -- Tool.Enabled is recorded for diagnostics but is not used as an attack gate.
    if toolAlreadyReady ~= true and not ensureToolEquipped() then
        setStatus("Waiting for starting melee tool in hotbar slot 1")
        return 0
    end
    local equippedTool = character:FindFirstChildOfClass("Tool")
    if not equippedTool then
        setStatus("Melee tool is not equipped")
        return 0
    end
    local signalId, signalIdSource, meleeReplica = resolveMeleeReplicaId(equippedTool)
    if signalId == nil or not meleeReplica then
        setStatus("Waiting for live melee replica mapping")
        recordThrottled("melee-replica-unresolved:" .. tostring(equippedTool.Name), 1.5,
            "WEAPON", "Combat paused: equipped melee replica could not be resolved",
            "ToolGuid=" .. tostring(equippedTool.Name)
                .. " | Controller=" .. tostring(replicaControllerPath)
                .. " | IndexedGUIDReplicas=" .. tostring(replicaRegistryIndexed)
                .. " | No guessed replica ID was sent")
        return 0
    end
    if not equippedTool.Enabled then
        recordThrottled("melee-disabled-state", 2, "WEAPON", "Equipped melee Tool has Tool.Enabled=false", "Property is left game-controlled; it is not used as an attack gate")
    end

    local candidates = {}
    for _, entry in ipairs(entries) do
        if entry.model and entry.model.Parent == ENTITY_CONTAINER and entry.root and entry.root.Parent
            and isAlienModel(entry.model) == entry.variant
            and not hasExcludedHostileMarker(entry.model)
            and not serverDeadAlienModels[entry.model] then
            local contact = getClosestMeleeContact(entry.model, root.Position, getMeleeHitRange())
            if contact and contact.part and contact.part.Parent then
                contact.entry = entry
                table.insert(candidates, contact)
            else
                recordThrottled(
                    "melee-no-part-in-range:" .. entry.model.Name,
                    1,
                    "COMBAT",
                    "Alien skipped: no body-part center in attack radius",
                    entry.variant .. "/" .. entry.model.Name .. " | MaxPartCenterDistance=" .. tostring(getMeleeHitRange())
                )
            end
        end
    end

    table.sort(candidates, function(a, b)
        if math.abs(a.distance - b.distance) > 0.25 then
            return a.distance < b.distance
        end
        return a.priority < b.priority
    end)

    local maxTargets = math.min(#candidates, CONFIG.MAX_TARGETS_PER_SWEEP)
    if maxTargets == 0 then
        recordThrottled(
            "melee-no-valid-contact",
            0.75,
            "COMBAT",
            "No valid alien body part in attack radius",
            "No eligible body-part center within " .. tostring(getMeleeHitRange()) .. " studs"
        )
        return 0
    end

    -- The observed server melee effect can affect nearby entities beyond the
    -- exact client-selected part. Suppress the whole sweep if any non-alien
    -- model is inside the configured attack area; this is intentionally strict.
    local collateralBlocker = getNearestNonAlienEntityWithin(root.Position, CONFIG.COLLATERAL_GUARD_RADIUS)
    if collateralBlocker then
        recordThrottled(
            "collateral-guard:" .. tostring(collateralBlocker.model.Name),
            0.75,
            "COMBAT",
            "Melee sweep suppressed to prevent non-alien collateral",
            string.format("BlockedEntity=%s | Marker=%s | Distance=%.2f | GuardRadius=%.1f | AllowedTargets=AlienType1/2/3 only",
                tostring(collateralBlocker.model.Name), tostring(collateralBlocker.marker),
                collateralBlocker.distance, CONFIG.COLLATERAL_GUARD_RADIUS)
        )
        setStatus("Holding attacks: non-alien entity inside " .. tostring(CONFIG.COLLATERAL_GUARD_RADIUS) .. "-stud guard")
        return 0
    end

    -- Aim at the nearest actual in-range alien contact. Averaging separated
    -- targets can point the melee cone between them instead of at a target.
    local nearestContact = candidates[1]
    nearestContact.position = nearestContact.part.Position
    local contactDelta = nearestContact.position - root.Position
    local direction = contactDelta
    local directionSource = "nearest valid alien contact"
    if direction.Magnitude < 0.001 then
        direction = root.CFrame.LookVector
        directionSource = "character look fallback"
    end
    direction = direction.Unit

    lastAutoAttackAt = os.clock()
    automatedAttackRequests = automatedAttackRequests + 1
    -- Match the original HF5.9 source and the observed working aura exactly:
    -- call the game's ReplicaSignal RemoteEvent with the resolved live ID.
    local okAttack, attackError = pcall(function()
        ReplicaSignal:FireServer(signalId, "Melee", "Attack", direction, 1)
    end)
    if not okAttack then
        remoteErrors = remoteErrors + 1
        recordEvent("ERROR", "Melee Attack call failed locally", diagTraceback(attackError))
        return 0
    end

    -- The measured working capture had a 32.3 ms median Attack-to-first-Hit delay.
    task.wait(CONFIG.MELEE_HIT_DELAY)
    local lateCollateralBlocker = getNearestNonAlienEntityWithin(root.Position, CONFIG.COLLATERAL_GUARD_RADIUS)
    if lateCollateralBlocker then
        recordEvent("COMBAT", "Hit payloads withheld by late collateral guard",
            string.format("BlockedEntity=%s | Marker=%s | Distance=%.2f | GuardRadius=%.1f | AttackStartWasSent=true | HitRequestsSent=0",
                tostring(lateCollateralBlocker.model.Name), tostring(lateCollateralBlocker.marker),
                lateCollateralBlocker.distance, CONFIG.COLLATERAL_GUARD_RADIUS))
        setStatus("Holding Hit requests to avoid non-alien collateral")
        return 0
    end
    recordThrottled(
        "melee-attack-dispatched",
        0.25,
        "COMBAT",
        "Melee Attack request dispatched",
        string.format(
            "Nearest=%s/%s | HitPart=%s | PartClass=%s | Priority=%d | PartPath=%s | PartCenterDistance=%.2f | PartPosition=(%.2f, %.2f, %.2f) | PartVector=(%.3f, %.3f, %.3f) | HitNormal=(0, 1, 0) | Material=%s | Root=(%.2f, %.2f, %.2f) | AttackDirection=(%.3f, %.3f, %.3f) | DirectionSource=%s | ReplicaId=%s | ReplicaIdSource=%s | Transport=ReplicaSignal:FireServer | Tool=%s | ToolEnabled=%s | Server acceptance unknown",
            nearestContact.entry.variant,
            nearestContact.entry.model.Name,
            nearestContact.part.Name,
            nearestContact.partClass or "UNKNOWN",
            nearestContact.priority or 99,
            nearestContact.part:GetFullName(),
            nearestContact.distance,
            nearestContact.position.X, nearestContact.position.Y, nearestContact.position.Z,
            contactDelta.X, contactDelta.Y, contactDelta.Z,
            tostring(nearestContact.material),
            root.Position.X, root.Position.Y, root.Position.Z,
            direction.X, direction.Y, direction.Z,
            directionSource,
            tostring(signalId),
            signalIdSource,
            equippedTool.Name,
            tostring(equippedTool.Enabled)
        )
    )

    local sentHits = 0
    for targetIndex = 1, maxTargets do
        if sentHits >= CONFIG.MAX_HITS_PER_SWEEP then
            break
        end

        local contact = candidates[targetIndex]
        local entry = contact.entry
        if contact.part and contact.part.Parent and entry.model and entry.model.Parent == ENTITY_CONTAINER
            and contact.part:IsDescendantOf(entry.model)
            and isAlienModel(entry.model) == entry.variant
            and not hasExcludedHostileMarker(entry.model)
            and not serverDeadAlienModels[entry.model] then
            local targetHitCount = 0
            for hitIndex = 1, CONFIG.MAX_HITS_PER_TARGET do
                if sentHits >= CONFIG.MAX_HITS_PER_SWEEP or not contact.part.Parent then
                    break
                end

                local liveCollateralBlocker = getNearestNonAlienEntityWithin(root.Position, CONFIG.COLLATERAL_GUARD_RADIUS)
                if liveCollateralBlocker then
                    recordThrottled(
                        "collateral-guard-live:" .. tostring(liveCollateralBlocker.model.Name),
                        0.5,
                        "COMBAT",
                        "Remaining Hit requests cancelled by collateral guard",
                        string.format("BlockedEntity=%s | Marker=%s | Distance=%.2f | GuardRadius=%.1f",
                            tostring(liveCollateralBlocker.model.Name), tostring(liveCollateralBlocker.marker),
                            liveCollateralBlocker.distance, CONFIG.COLLATERAL_GUARD_RADIUS)
                    )
                    return sentHits
                end

                local currentPartPosition = contact.part.Position
                local currentContactDistance = (currentPartPosition - root.Position).Magnitude
                if currentContactDistance <= getMeleeHitRange() then
                    local okHit, hitError = pcall(function()
                        -- Use the live part center, upward normal and actual material.
                        ReplicaSignal:FireServer(
                            signalId,
                            "Melee",
                            "Hit",
                            contact.part,
                            currentPartPosition,
                            Vector3.new(0, 1, 0),
                            contact.part.Material
                        )
                    end)

                    if okHit then
                        sentHits = sentHits + 1
                        targetHitCount = targetHitCount + 1
                        lastAutoHitAt = os.clock()
                        automatedHitRequests = automatedHitRequests + 1
                        lastAutoHitByModel[entry.model] = lastAutoHitAt
                    else
                        remoteErrors = remoteErrors + 1
                        recordEvent("ERROR", "Melee Hit call failed locally", diagTraceback(hitError))
                    end
                else
                    recordThrottled("melee-contact-moved-out:" .. tostring(entry.model.Name), 0.5,
                        "COMBAT", "Alien contact moved outside configured melee radius; Hit skipped",
                        string.format("Target=%s/%s | CurrentPartDistance=%.2f | MaxDistance=%.2f", entry.variant, entry.model.Name, currentContactDistance, getMeleeHitRange()))
                end
            end

            if targetHitCount > 0 then
                recordThrottled(
                    "melee-hit-summary:" .. entry.model.Name,
                    0.5,
                    "COMBAT",
                    "Melee part hits dispatched",
                    string.format(
                        "Target=%s/%s | Part=%s | PartClass=%s | Priority=%d | Repeats=%d | PartPosition=(%.2f, %.2f, %.2f) | Normal=(0, 1, 0) | Material=%s | Server damage unverified",
                        entry.variant,
                        entry.model.Name,
                        contact.part.Name,
                        contact.partClass or "UNKNOWN",
                        contact.priority or 99,
                        targetHitCount,
                        contact.part.Position.X,
                        contact.part.Position.Y,
                        contact.part.Position.Z,
                        tostring(contact.part.Material)
                    )
                )
            end
        end
    end

    recordThrottled(
        "melee-sweep-summary",
        0.5,
        "COMBAT",
        "Attack sweep finished",
        "Captured-payload Hit requests without local error=" .. tostring(sentHits) .. " | Targets=" .. tostring(maxTargets) .. " | Local call errors=" .. tostring(remoteErrors)
    )
    recordEvent("COMBAT", "Classic Shovel sweep summary", string.format(
        "ReplicaId=%s | ReplicaIdSource=%s | Targets=%d | HitRequests=%d | HitsPerTargetCap=%d | DirectionSource=%s | ServerDamageEvents=%d | ServerMeleeEffects=%d | ServerDeaths=%d | Server acceptance remains determined only by confirmations",
        tostring(signalId), signalIdSource, maxTargets, sentHits, CONFIG.MAX_HITS_PER_TARGET, directionSource,
        serverDamageEvents, serverMeleeEffects, serverOnDiedEvents
    ))
    return sentHits
end

local function getAlienTokenPrompts(center, radius)
    local prompts = {}
    if not ITEM_CONTAINER then
        return prompts
    end
    for _, descendant in ipairs(ITEM_CONTAINER:GetDescendants()) do
        if descendant:IsA("ProximityPrompt") and descendant.Name == "CollectAlienTokenPrompt" and descendant.Enabled then
            local position = getPromptPosition(descendant)
            if position and (position - center).Magnitude <= radius then
                table.insert(prompts, {
                    prompt = descendant,
                    position = position,
                    distance = (position - center).Magnitude,
                })
            end
        end
    end
    table.sort(prompts, function(a, b)
        return a.distance < b.distance
    end)
    return prompts
end

local function activatePrompt(prompt, attemptNumber)
    if not prompt or not prompt.Parent or not prompt.Enabled then
        return false, "Prompt is missing or disabled"
    end

    local previousError = nil
    if (tonumber(attemptNumber) or 1) % 2 == 1 and type(fireproximityprompt) == "function" then
        local fireOk, fireError = pcall(function()
            fireproximityprompt(prompt)
        end)
        if fireOk then
            return true, nil
        end
        previousError = fireError
    end

    local holdOk, holdError = pcall(function()
        prompt:InputHoldBegin()
        task.wait(math.max(tonumber(prompt.HoldDuration) or 0, 0.05))
        prompt:InputHoldEnd()
    end)
    if holdOk then
        return true, nil
    end
    return false, holdError or previousError
end

local function collectTokensAround(center, radius)
    if not center then
        return 0, 0
    end

    local confirmed = 0
    local attemptsByPrompt = {}
    local confirmedPrompts = {}
    local idlePasses = 0

    while running and not paused and idlePasses < CONFIG.TOKEN_IDLE_PASSES
        and confirmed < CONFIG.MAX_TOKEN_PICKUPS_PER_PASS do
        local prompts = getAlienTokenPrompts(center, radius)
        local attemptedAny = false

        for _, item in ipairs(prompts) do
            local prompt = item.prompt
            local attemptNumber = attemptsByPrompt[prompt] or 0
            if prompt and prompt.Parent and prompt.Enabled and not confirmedPrompts[prompt]
                and attemptNumber < CONFIG.TOKEN_PROMPT_RETRIES then
                attemptedAny = true
                attemptNumber = attemptNumber + 1
                attemptsByPrompt[prompt] = attemptNumber
                local position = getPromptPosition(prompt) or item.position
                if position then
                    local promptPath = "unknown"
                    pcall(function() promptPath = prompt:GetFullName() end)
                    recordEvent("TOKEN", "Alien Token pickup detected", string.format(
                        "Path=%s | Position=(%.1f, %.1f, %.1f) | DistanceFromDeath=%.1f | MaxActivationDistance=%.1f | Attempt=%d/%d",
                        promptPath, position.X, position.Y, position.Z, item.distance,
                        prompt.MaxActivationDistance, attemptNumber, CONFIG.TOKEN_PROMPT_RETRIES))
                    local moved = moveCharacter(position + Vector3.new(0, 2, 0), position, "TOKEN_PICKUP")
                    task.wait(0.10)
                    tokenAttempts = tokenAttempts + 1
                    recordEvent("TOKEN", "Pickup attempt started", "Path=" .. promptPath
                        .. " | MoveToPickup=" .. tostring(moved)
                        .. " | Attempt=" .. tostring(tokenAttempts)
                        .. " | PromptRetry=" .. tostring(attemptNumber))
                    local triggered, triggerError = activatePrompt(prompt, attemptNumber)
                    recordEvent("TOKEN", triggered and "Prompt activation call returned" or "Prompt activation call failed",
                        "Path=" .. promptPath .. " | LocalResult=" .. tostring(triggered)
                            .. (triggerError and " | Error=" .. diagTraceback(triggerError) or ""))
                    task.wait(CONFIG.TOKEN_SETTLE_WAIT)
                    if triggered and (not prompt.Parent or not prompt.Enabled) then
                        confirmedPrompts[prompt] = true
                        tokenPickupsConfirmed = tokenPickupsConfirmed + 1
                        confirmed = confirmed + 1
                        setStatus("Collected Alien Token pickup")
                        recordEvent("TOKEN", "Pickup confirmed by prompt removal/disable",
                            "Path=" .. promptPath .. " | ConfirmedThisPass=" .. tostring(confirmed)
                                .. " | TotalConfirmed=" .. tostring(tokenPickupsConfirmed))
                    elseif attemptNumber < CONFIG.TOKEN_PROMPT_RETRIES then
                        setStatus("Token pickup not confirmed; retrying prompt")
                        recordThrottled("token-unconfirmed:" .. promptPath, 0.5, "TOKEN", "Pickup not confirmed; retry scheduled",
                            "Prompt remained present and enabled | Retry=" .. tostring(attemptNumber + 1)
                                .. "/" .. tostring(CONFIG.TOKEN_PROMPT_RETRIES))
                        task.wait(0.15)
                    else
                        recordEvent("TOKEN", "Pickup retries exhausted",
                            "Path=" .. promptPath .. " | Prompt remained present/enabled after "
                                .. tostring(CONFIG.TOKEN_PROMPT_RETRIES) .. " attempts")
                    end
                end
            end
        end

        if attemptedAny then
            idlePasses = 0
            task.wait(0.08)
        else
            idlePasses = idlePasses + 1
            task.wait(0.25)
        end
    end

    local remainingPrompts = getAlienTokenPrompts(center, radius)
    recordEvent("TOKEN", "Token search pass complete",
        "Confirmed=" .. tostring(confirmed) .. " | RemainingEnabledPrompts=" .. tostring(#remainingPrompts)
            .. " | SearchRadius=" .. tostring(radius))
    return confirmed, #remainingPrompts
end

local function collectPendingTokenDrops(fallbackCenters)
    local totalConfirmed = 0
    local processedThisPass = 0
    local searchedCenters = {}
    local seenCenters = {}

    local function rememberSearchCenter(center)
        if typeof(center) == "Vector3" then
            local key = string.format("%.0f:%.0f:%.0f", center.X, center.Y, center.Z)
            if not seenCenters[key] then
                seenCenters[key] = true
                table.insert(searchedCenters, center)
            end
        end
    end

    while running and not paused and #pendingTokenDropCenters > 0 do
        local drop = table.remove(pendingTokenDropCenters, 1)
        if drop and drop.position then
            rememberSearchCenter(drop.position)
            task.wait(CONFIG.TOKEN_DROP_SPAWN_WAIT)
            local prompts = getAlienTokenPrompts(drop.position, CONFIG.TOKEN_SEARCH_RADIUS)
            if #prompts == 0 then
                task.wait(0.35)
                prompts = getAlienTokenPrompts(drop.position, CONFIG.TOKEN_SEARCH_RADIUS)
            end

            if #prompts > 0 then
                setStatus("Collecting drops from confirmed alien death")
                local collected, remaining = collectTokensAround(drop.position, CONFIG.TOKEN_SEARCH_RADIUS)
                totalConfirmed = totalConfirmed + collected
                tokenDropCentersProcessed = tokenDropCentersProcessed + 1
                processedThisPass = processedThisPass + 1
                recordEvent("TOKEN", "Death-location collection pass finished",
                    "Target=" .. tostring(drop.variant) .. "/" .. tostring(drop.modelName)
                        .. " | PromptsInitiallyFound=" .. tostring(#prompts)
                        .. " | Confirmed=" .. tostring(collected)
                        .. " | Remaining=" .. tostring(remaining))
            else
                drop.spawnChecks = (tonumber(drop.spawnChecks) or 0) + 1
                if drop.spawnChecks < CONFIG.TOKEN_DROP_SPAWN_RETRIES then
                    table.insert(pendingTokenDropCenters, drop)
                    recordEvent("TOKEN", "Waiting for delayed token drop spawn",
                        "Target=" .. tostring(drop.variant) .. "/" .. tostring(drop.modelName)
                            .. " | SpawnCheck=" .. tostring(drop.spawnChecks) .. "/" .. tostring(CONFIG.TOKEN_DROP_SPAWN_RETRIES)
                            .. " | Queue=" .. tostring(#pendingTokenDropCenters))
                else
                    tokenDropCentersProcessed = tokenDropCentersProcessed + 1
                    processedThisPass = processedThisPass + 1
                    recordEvent("TOKEN", "No token prompt found after death-location retries",
                        "Target=" .. tostring(drop.variant) .. "/" .. tostring(drop.modelName)
                            .. " | DeathPosition=" .. tostring(drop.position)
                            .. " | Checks=" .. tostring(drop.spawnChecks)
                            .. " | SearchRadius=" .. tostring(CONFIG.TOKEN_SEARCH_RADIUS))
                end
            end
        end
    end

    for _, center in ipairs(fallbackCenters or {}) do
        if not running or paused then
            break
        end
        rememberSearchCenter(center)
        if typeof(center) == "Vector3" then
            local prompts = getAlienTokenPrompts(center, CONFIG.TOKEN_SEARCH_RADIUS)
            if #prompts > 0 then
                local collected, remaining = collectTokensAround(center, CONFIG.TOKEN_SEARCH_RADIUS)
                totalConfirmed = totalConfirmed + collected
                recordEvent("TOKEN", "Tracked-alien fallback collection pass finished",
                    "Center=" .. tostring(center) .. " | PromptsInitiallyFound=" .. tostring(#prompts)
                        .. " | Confirmed=" .. tostring(collected) .. " | Remaining=" .. tostring(remaining))
            end
        end
    end

    local remainingPromptSet = {}
    for _, center in ipairs(searchedCenters) do
        for _, item in ipairs(getAlienTokenPrompts(center, CONFIG.TOKEN_SEARCH_RADIUS)) do
            remainingPromptSet[item.prompt] = true
        end
    end
    local remainingPromptCount = 0
    for _ in pairs(remainingPromptSet) do
        remainingPromptCount = remainingPromptCount + 1
    end

    if processedThisPass > 0 or totalConfirmed > 0 or remainingPromptCount > 0 then
        recordEvent("TOKEN", "Pending alien drop collection summary",
            "DeathCentersProcessed=" .. tostring(processedThisPass)
                .. " | TotalDeathCentersProcessed=" .. tostring(tokenDropCentersProcessed)
                .. " | ConfirmedThisPass=" .. tostring(totalConfirmed)
                .. " | RemainingEnabledPrompts=" .. tostring(remainingPromptCount)
                .. " | TotalConfirmed=" .. tostring(tokenPickupsConfirmed))
    end
    return totalConfirmed, remainingPromptCount
end

local function engageAliens(seedEntries, clusterPosition, trackedMembers)
    if not seedEntries or #seedEntries == 0 then
        return true, false
    end

    local firstTarget = seedEntries[1]
    if not firstTarget.root or not firstTarget.root.Parent then
        return false, false
    end

    local clusterCenter = clusterPosition or firstTarget.root.Position
    local fallbackDropCenters = {}
    for model, lastPosition in pairs(trackedMembers or {}) do
        local root = model and model.Parent == ENTITY_CONTAINER and getModelRoot(model) or nil
        local position = root and root.Position or lastPosition
        if typeof(position) == "Vector3" then
            table.insert(fallbackDropCenters, position)
        end
    end
    if #fallbackDropCenters == 0 then
        for _, entry in ipairs(seedEntries) do
            if entry.root and entry.root.Parent then
                table.insert(fallbackDropCenters, entry.root.Position)
            end
        end
    end

    local startTime = os.clock()
    local initialKillCount = alienKills
    local initialAlienImpactCount = serverConfirmedAlienHitEvents
    local initialAlienDeathCount = serverAlienDeathEvents
    recordEvent("TARGET", "Alien cluster engagement started",
        string.format("InitialTarget=%s/%s | Count=%d | Policy=UNLIMITED | Sweep=close torso-relative hover plus up to 3 nearby alien contacts | DetectionRadius=%.1f | Center=(%.1f, %.1f, %.1f)",
            firstTarget.variant, firstTarget.model.Name, #seedEntries, CONFIG.SCAN_DETECT_RADIUS,
            clusterCenter.X, clusterCenter.Y, clusterCenter.Z))

    local lastProgressTime = os.clock()
    local lastKnownAlienImpacts = serverConfirmedAlienHitEvents
    local lastKnownAlienDeaths = serverAlienDeathEvents
    local lastKnownKillCount = alienKills
    local lockedTargetModel = nil
    local targetRetryUntil = {}
    local targetLastProgressAt = os.clock()
    setStatus("Engaging alien cluster; scan held until clear")

    while running and not paused do
        local entries = getTrackedClusterEntries(clusterCenter, CONFIG.SCAN_DETECT_RADIUS, trackedMembers)
        if #entries == 0 then
            break
        end

        local nearest = nil
        local selectionNow = os.clock()
        if lockedTargetModel and (targetRetryUntil[lockedTargetModel] or 0) <= selectionNow then
            for _, entry in ipairs(entries) do
                if entry.model == lockedTargetModel then
                    nearest = entry
                    break
                end
            end
        end
        if not nearest then
            local _, playerRoot = getCharacter()
            local bestDistance = math.huge
            if playerRoot then
                for _, entry in ipairs(entries) do
                    local retryUntil = targetRetryUntil[entry.model] or 0
                    if retryUntil <= selectionNow and entry.root and entry.root.Parent then
                        local distance = (entry.root.Position - playerRoot.Position).Magnitude
                        if distance < bestDistance then
                            bestDistance = distance
                            nearest = entry
                        end
                    end
                end
            end
            if not nearest then
                local earliestRetry = math.huge
                for _, entry in ipairs(entries) do
                    local retryUntil = targetRetryUntil[entry.model] or 0
                    if retryUntil > selectionNow and retryUntil < earliestRetry then
                        earliestRetry = retryUntil
                    end
                end
                if earliestRetry < math.huge then
                    recordThrottled("cluster-targets-cooling", 1.5, "TARGET",
                        "All remaining aliens are temporarily on target-retry cooldown",
                        "ScanAdvanceBlocked=true | WaitingForNextRetry=" .. string.format("%.2f", math.max(0, earliestRetry - selectionNow)) .. "s")
                    task.wait(math.min(0.25, math.max(0.05, earliestRetry - selectionNow)))
                    lockedTargetModel = nil
                    continue
                end
                break
            end
            lockedTargetModel = nearest.model
            targetLastProgressAt = os.clock()
        end
        if not nearest then
            break
        end

        recordThrottled("target-selection", 0.75, "TARGET", "Alien target locked",
            "Variant=" .. nearest.variant .. " | Model=" .. nearest.model.Name
                .. " | ClusterTargets=" .. tostring(#entries) .. " | TargetLockUntilDeathOrRemoval=true | RemovalDoesNotClearCluster")
        -- Attach to the exact torso X/Z before tool checks. Heartbeat keeps the
        -- root centered under a moving alien through Attack -> Hit delay and cooldown.
        startHoverTether(nearest)
        moveBelowAlien(nearest, CONFIG.HOVER_BELOW)
        local toolReady = ensureToolEquipped()
        if not toolReady then
            recordThrottled("tool-cooldown-hold:" .. tostring(nearest.model.Name), 0.75,
                "WEAPON", "Centered underbody tether held during shovel re-equip delay",
                "Heartbeat follow remains active | HorizontalOffset=0 | ScanAdvanceBlocked=true")
        end
        local targetRecordBefore = monitoredAliens[nearest.model]
        local targetHitCountBefore = targetRecordBefore and (targetRecordBefore.serverHitCount or 0) or 0
        local hits = toolReady and sendMeleeSweep(entries, true) or 0
        if hits > 0 then
            setStatus("Locked " .. tostring(nearest.variant) .. " / " .. tostring(nearest.model.Name) .. " | " .. tostring(hits) .. " nearby Hit requests")
        else
            setStatus("Locked alien found; waiting for a valid melee contact")
        end

        local targetRecordAfter = monitoredAliens[nearest.model]
        local targetHitCountAfter = targetRecordAfter and (targetRecordAfter.serverHitCount or 0) or 0
        local targetResolved = serverDeadAlienModels[nearest.model]
            or (targetRecordAfter and targetRecordAfter.serverDead == true)
            or nearest.model.Parent ~= ENTITY_CONTAINER
        if targetResolved then
            if hoverTetherEntry and hoverTetherEntry.model == nearest.model then
                stopHoverTether("TARGET_RESOLVED")
            end
            recordEvent("TARGET", "Locked alien resolved; selecting next cluster member",
                "Variant=" .. tostring(nearest.variant) .. " | Model=" .. tostring(nearest.model.Name)
                    .. " | ServerDead=" .. tostring(serverDeadAlienModels[nearest.model] == true
                        or (targetRecordAfter and targetRecordAfter.serverDead == true))
                    .. " | Removed=" .. tostring(nearest.model.Parent ~= ENTITY_CONTAINER))
            targetRetryUntil[nearest.model] = nil
            lockedTargetModel = nil
            targetLastProgressAt = os.clock()
            lastProgressTime = os.clock()
        end

        if targetHitCountAfter > targetHitCountBefore then
            targetLastProgressAt = os.clock()
        end

        if not targetResolved and (os.clock() - targetLastProgressAt) >= CONFIG.TARGET_STALL_TIMEOUT then
            local retryUntil = os.clock() + CONFIG.TARGET_RETRY_COOLDOWN
            targetRetryUntil[nearest.model] = retryUntil
            recordEvent("TARGET", "Target rotated after no server-confirmed hit",
                "Target=" .. tostring(nearest.variant) .. "/" .. tostring(nearest.model.Name)
                    .. " | NoConfirmedHitFor=" .. string.format("%.2f", os.clock() - targetLastProgressAt)
                    .. "s | RetryAfter=" .. string.format("%.2f", CONFIG.TARGET_RETRY_COOLDOWN)
                    .. "s | OtherTrackedAliensRemainEligible=true | ScanAdvanceBlocked=true")
            lockedTargetModel = nil
            targetLastProgressAt = os.clock()
            lastProgressTime = os.clock()
        end

        if alienKills > lastKnownKillCount
            or serverConfirmedAlienHitEvents > lastKnownAlienImpacts
            or serverAlienDeathEvents > lastKnownAlienDeaths
            or targetHitCountAfter > targetHitCountBefore then
            lastProgressTime = os.clock()
            lastKnownKillCount = alienKills
            lastKnownAlienImpacts = serverConfirmedAlienHitEvents
            lastKnownAlienDeaths = serverAlienDeathEvents
        end

        if (os.clock() - lastProgressTime) > CONFIG.NO_KILL_TIMEOUT then
            setStatus("No confirmed progress on locked alien; cluster remains held for recovery")
            recordEvent("TARGET", "Attack attempt timed out without confirmed progress",
                "Target=" .. tostring(nearest.variant) .. "/" .. tostring(nearest.model.Name)
                    .. " | SecondsWithoutProgress=" .. string.format("%.2f", os.clock() - lastProgressTime)
                    .. " | ScanAdvanceBlocked=true | ClusterPolicy=UNLIMITED")
            break
        end

        task.wait(math.max(0, CONFIG.ATTACK_INTERVAL - CONFIG.MELEE_HIT_DELAY))
    end

    stopHoverTether("ENGAGEMENT_PASS_ENDED")
    local remaining = getTrackedClusterEntries(clusterCenter, CONFIG.SCAN_DETECT_RADIUS, trackedMembers)
    local allTrackedMembersDeathConfirmed = true
    local trackedMemberCount = 0
    for model in pairs(trackedMembers or {}) do
        trackedMemberCount = trackedMemberCount + 1
        if not isAlienConfirmedDead(model) then
            allTrackedMembersDeathConfirmed = false
        end
    end
    local clusterCleared = #remaining == 0 and allTrackedMembersDeathConfirmed
    local madeProgress = serverConfirmedAlienHitEvents > initialAlienImpactCount
        or serverAlienDeathEvents > initialAlienDeathCount
        or alienKills > initialKillCount

    local collectedAtEnd = 0
    if clusterCleared then
        collectedAtEnd = collectPendingTokenDrops(fallbackDropCenters)
    else
        recordEvent("TOKEN", "Drop collection held until entire cluster is death-confirmed",
            "TrackedMembers=" .. tostring(trackedMemberCount)
                .. " | RemainingActiveAliens=" .. tostring(#remaining)
                .. " | PendingDeathCenters=" .. tostring(#pendingTokenDropCenters)
                .. " | ScanAdvanceBlocked=true")
    end
    recordEvent("TARGET", "Alien engagement ended",
        "Elapsed=" .. string.format("%.2f", os.clock() - startTime) .. "s"
            .. " | AlienImpactDelta=" .. tostring(serverConfirmedAlienHitEvents - initialAlienImpactCount)
            .. " | AlienDeathDelta=" .. tostring(serverAlienDeathEvents - initialAlienDeathCount)
            .. " | KillNotificationDelta=" .. tostring(alienKills - initialKillCount)
            .. " | RemainingTrackedAliens=" .. tostring(#remaining)
            .. " | Progress=" .. tostring(madeProgress)
            .. " | ScanAdvanceBlocked=" .. tostring(not clusterCleared))
    recordEvent("TOKEN", "Cluster collection pass finished",
        "ConfirmedAtEnd=" .. tostring(collectedAtEnd)
            .. " | TotalConfirmed=" .. tostring(tokenPickupsConfirmed)
            .. " | PendingDeathCenters=" .. tostring(#pendingTokenDropCenters))
    recordEvent("TARGET", "Cluster clearance check",
        "RemainingAliens=" .. tostring(#remaining) .. " | Cleared=" .. tostring(clusterCleared))
    currentTarget = "None"
    return clusterCleared, madeProgress
end

local function getCurrentScanPosition()
    return Vector3.new(CONFIG.SCAN_X, CONFIG.SCAN_Y, scanZ)
end

local function advanceScan()
    stopHoverTether("SCAN_ADVANCE")
    local oldZ = scanZ
    local oldLap = lap
    scanAdvanceCount = scanAdvanceCount + 1
    scanZ = scanZ - CONFIG.SCAN_STEP
    if scanZ < CONFIG.SCAN_MIN_Z then
        lap = lap + 1
        scanZ = CONFIG.SCAN_START_Z
    end
    local position = getCurrentScanPosition()
    local moved = moveCharacter(position, position + Vector3.new(0, 0, -1), "SCAN_ADVANCE")
    setStatus("Scanning lap " .. tostring(lap) .. " / Z=" .. tostring(scanZ))
    recordEvent("SCAN", "Scan route advanced", "Lap=" .. tostring(oldLap) .. "->" .. tostring(lap) .. " | Z=" .. tostring(oldZ) .. "->" .. tostring(scanZ) .. " | Step=" .. tostring(CONFIG.SCAN_STEP) .. " | MoveSuccess=" .. tostring(moved))
    task.wait(CONFIG.SCAN_WAIT)
end

local function waitWhilePaused()
    while running and paused do
        task.wait(0.2)
    end
end

local function mainLoop()
    applyFullbright()
    setupFlight()

    local _, initialRoot = getCharacter()
    if initialRoot and initialRoot.Position.Z < -1000 then
        scanZ = CONFIG.SCAN_START_Z + math.floor((initialRoot.Position.Z - CONFIG.SCAN_START_Z) / CONFIG.SCAN_STEP) * CONFIG.SCAN_STEP
    end

    local pendingClusterCenter = nil
    local pendingClusterNoProgressPasses = 0
    local pendingClusterMembers = {}

    local function rememberClusterMembers(entries)
        for _, entry in ipairs(entries or {}) do
            if entry.model and entry.root and entry.root.Parent then
                pendingClusterMembers[entry.model] = entry.root.Position
            end
        end
    end

    local function clusterDeathState()
        local total, unconfirmed, active = 0, 0, 0
        for model in pairs(pendingClusterMembers) do
            total = total + 1
            -- Track every originally detected alien until death/health confirmation.
            -- Leaving ENTITY_CONTAINER or being destroyed is not kill confirmation.
            if not isAlienConfirmedDead(model) then
                unconfirmed = unconfirmed + 1
            end
            if model and model.Parent == ENTITY_CONTAINER and isAlienModel(model)
                and not hasExcludedHostileMarker(model) and getModelRoot(model) then
                active = active + 1
            end
        end
        return total > 0 and unconfirmed == 0, total, unconfirmed, active
    end

    local function getClusterDropCenters()
        local centers = {}
        local seen = {}
        for model, lastPosition in pairs(pendingClusterMembers) do
            local root = model and model.Parent == ENTITY_CONTAINER and getModelRoot(model) or nil
            local position = root and root.Position or lastPosition
            if typeof(position) == "Vector3" then
                local key = string.format("%.0f:%.0f:%.0f", position.X, position.Y, position.Z)
                if not seen[key] then
                    seen[key] = true
                    table.insert(centers, position)
                end
            end
        end
        return centers
    end

    local function resetPendingCluster()
        pendingClusterCenter = nil
        pendingClusterNoProgressPasses = 0
        pendingClusterMembers = {}
    end

    local function getEligibleAliensNear(position, radius)
        return getTrackedClusterEntries(position, radius, pendingClusterMembers)
    end

    local function holdClusterWithoutProgress(stillPending)
        pendingClusterNoProgressPasses = pendingClusterNoProgressPasses + 1
        recordEvent("TARGET", "Alien cluster made no confirmed progress",
            "Pass=" .. tostring(pendingClusterNoProgressPasses)
                .. " | Remaining=" .. tostring(#(stillPending or {}))
                .. " | ScanAdvanceBlocked=true | ClusterPolicy=UNLIMITED")
        if pendingClusterNoProgressPasses >= CONFIG.MAX_NO_PROGRESS_CLUSTER_PASSES then
            pendingClusterNoProgressPasses = 0
            local nextTarget = getNearestEntry(stillPending or {})
            if nextTarget then
                startHoverTether(nextTarget)
                moveBelowAlien(nextTarget)
                recordEvent("TARGET", "Cluster recovery re-approach completed",
                    "Target=" .. tostring(nextTarget.variant) .. "/" .. tostring(nextTarget.model.Name)
                        .. " | TorsoApproach=true | ScanAdvanceBlocked=true")
            end
            setStatus("No damage confirmed; re-locking nearest survivor, scan held")
        else
            setStatus("No confirmed damage; staying on the same alien cluster")
        end
        task.wait(CONFIG.CLUSTER_RETRY_DELAY)
    end

    setStatus("Automatic farming started")
    recordEvent("SCAN", "Initial scan route ready", string.format(
        "Start=(%.1f, %.1f, %.1f) | Step=%d | DetectionRadius=%.1f | Wait=%.2fs | TorsoRelativeHover=%.1f below selected torso anchor / %.1f horizontal standoff | MeleePartRange=%.1f (hard ceiling %.1f) | CollateralGuard=%.1f | ClusterPolicy=UNLIMITED | SurvivorDeferral=disabled | TokenSearch=death-position-centered",
        CONFIG.SCAN_X, CONFIG.SCAN_Y, scanZ, CONFIG.SCAN_STEP, CONFIG.SCAN_DETECT_RADIUS,
        CONFIG.SCAN_WAIT, CONFIG.HOVER_BELOW, CONFIG.TORSO_HORIZONTAL_STANDOFF, getMeleeHitRange(),
        CONFIG.MELEE_HIT_HARD_CEILING, CONFIG.COLLATERAL_GUARD_RADIUS
    ))

    while running do
        waitWhilePaused()
        if not running then
            break
        end

        local character, root, humanoid = getCharacter()
        if not character or not root or not humanoid then
            setStatus("Waiting for character")
            task.wait(0.8)
        elseif humanoid.Health <= 0 then
            setStatus("Character down; waiting for respawn")
            restoreMovement()
            task.wait(1)
        else
            setupFlight()

            if pendingClusterCenter then
                local pendingAliens = getEligibleAliensNear(pendingClusterCenter, CONFIG.SCAN_DETECT_RADIUS)
                rememberClusterMembers(pendingAliens)
                local allResolvedBeforePass, trackedBeforePass, unconfirmedBeforePass, activeBeforePass = clusterDeathState()

                if #pendingAliens == 0 and allResolvedBeforePass then
                    local collected, remainingTokenPrompts = collectPendingTokenDrops(getClusterDropCenters())
                    if remainingTokenPrompts == 0 then
                        recordEvent("TARGET", "Alien cluster fully cleared from active container",
                            "TrackedEntities=" .. tostring(trackedBeforePass)
                                .. " | Active=" .. tostring(activeBeforePass)
                                .. " | Unconfirmed=" .. tostring(unconfirmedBeforePass)
                                .. " | FinalTokenPickups=" .. tostring(collected)
                                .. " | RemainingTokenPrompts=0 | Scan may advance")
                        resetPendingCluster()
                        advanceScan()
                    else
                        setStatus("Aliens cleared; collecting remaining token drops before scanning")
                        recordEvent("TOKEN", "Scan advancement blocked by remaining token prompts",
                            "RemainingEnabledPrompts=" .. tostring(remainingTokenPrompts)
                                .. " | ConfirmedThisPass=" .. tostring(collected)
                                .. " | ScanAdvanceBlocked=true")
                        task.wait(0.5)
                    end
                elseif #pendingAliens == 0 then
                    recordEvent("TARGET", "Tracked alien temporarily unavailable; scan remains held",
                        "TrackedEntities=" .. tostring(trackedBeforePass)
                            .. " | Active=" .. tostring(activeBeforePass)
                            .. " | Unconfirmed=" .. tostring(unconfirmedBeforePass)
                            .. " | ScanAdvanceBlocked=true")
                    setStatus("Waiting for remaining tracked alien; scan held")
                    task.wait(0.5)
                else
                    recordEvent("TARGET", "Continuing active alien cluster",
                        "RemainingTrackedAliens=" .. tostring(#pendingAliens)
                            .. " | TrackedEntities=" .. tostring(trackedBeforePass)
                            .. " | NoProgressPasses=" .. tostring(pendingClusterNoProgressPasses)
                            .. " | ClusterPolicy=UNLIMITED")
                    local passCleared, passMadeProgress = engageAliens(pendingAliens, pendingClusterCenter, pendingClusterMembers)
                    local stillPending = getEligibleAliensNear(pendingClusterCenter, CONFIG.SCAN_DETECT_RADIUS)
                    rememberClusterMembers(stillPending)
                    local allResolvedAfterPass, trackedAfterPass, unconfirmedAfterPass, activeAfterPass = clusterDeathState()

                    if #stillPending == 0 and allResolvedAfterPass then
                        local collected, remainingTokenPrompts = collectPendingTokenDrops(getClusterDropCenters())
                        if remainingTokenPrompts == 0 then
                            recordEvent("TARGET", "Alien cluster fully cleared from active container",
                                "TrackedEntities=" .. tostring(trackedAfterPass)
                                    .. " | Active=" .. tostring(activeAfterPass)
                                    .. " | Unconfirmed=" .. tostring(unconfirmedAfterPass)
                                    .. " | FinalTokenPickups=" .. tostring(collected)
                                    .. " | RemainingTokenPrompts=0 | Scan may advance")
                            resetPendingCluster()
                            advanceScan()
                        else
                            setStatus("Aliens cleared; collecting remaining token drops before scanning")
                            recordEvent("TOKEN", "Scan advancement blocked by remaining token prompts",
                                "RemainingEnabledPrompts=" .. tostring(remainingTokenPrompts)
                                    .. " | ConfirmedThisPass=" .. tostring(collected)
                                    .. " | ScanAdvanceBlocked=true")
                            task.wait(0.5)
                        end
                    elseif #stillPending == 0 then
                        recordEvent("TARGET", "Alien models absent but a tracked target remains unresolved",
                            "TrackedEntities=" .. tostring(trackedAfterPass)
                                .. " | Active=" .. tostring(activeAfterPass)
                                .. " | Unconfirmed=" .. tostring(unconfirmedAfterPass)
                                .. " | ScanAdvanceBlocked=true")
                        setStatus("Waiting for remaining tracked alien; scan held")
                        task.wait(0.5)
                    elseif passCleared then
                        pendingClusterNoProgressPasses = 0
                        setStatus("Current tracked cluster cleared; checking for late spawns/drops")
                        task.wait(0.15)
                    elseif passMadeProgress then
                        pendingClusterNoProgressPasses = 0
                        setStatus("Alien impact confirmed; continuing until every active alien is cleared")
                        task.wait(0.2)
                    else
                        holdClusterWithoutProgress(stillPending)
                    end
                end
            else
                local scanPosition = getCurrentScanPosition()
                moveCharacter(scanPosition, scanPosition + Vector3.new(0, 0, -1), "SCAN_POINT")
                task.wait(0.25)

                local aliens = getAliensNear(scanPosition, CONFIG.SCAN_DETECT_RADIUS)
                if #aliens > 0 then
                    local variantCounts = {AlienType1 = 0, AlienType2 = 0, AlienType3 = 0}
                    for _, entry in ipairs(aliens) do
                        variantCounts[entry.variant] = (variantCounts[entry.variant] or 0) + 1
                    end
                    pendingClusterCenter = scanPosition
                    pendingClusterNoProgressPasses = 0
                    pendingClusterMembers = {}
                    rememberClusterMembers(aliens)
                    recordEvent("SCAN", "Alien cluster detected", string.format(
                        "Total=%d | AlienType1=%d | AlienType2=%d | AlienType3=%d | ScanPosition=(%.1f, %.1f, %.1f) | ClusterPolicy=UNLIMITED | SurvivorDeferral=disabled",
                        #aliens, variantCounts.AlienType1, variantCounts.AlienType2, variantCounts.AlienType3,
                        scanPosition.X, scanPosition.Y, scanPosition.Z
                    ))
                    setStatus("Detected " .. tostring(#aliens) .. " alien(s)")
                    local passCleared, passMadeProgress = engageAliens(aliens, pendingClusterCenter, pendingClusterMembers)
                    local stillPending = getEligibleAliensNear(pendingClusterCenter, CONFIG.SCAN_DETECT_RADIUS)
                    rememberClusterMembers(stillPending)
                    local allResolvedAfterPass, trackedAfterPass, unconfirmedAfterPass, activeAfterPass = clusterDeathState()

                    if #stillPending == 0 and allResolvedAfterPass then
                        local collected, remainingTokenPrompts = collectPendingTokenDrops(getClusterDropCenters())
                        if remainingTokenPrompts == 0 then
                            recordEvent("TARGET", "Alien cluster fully cleared from active container",
                                "TrackedEntities=" .. tostring(trackedAfterPass)
                                    .. " | Active=" .. tostring(activeAfterPass)
                                    .. " | Unconfirmed=" .. tostring(unconfirmedAfterPass)
                                    .. " | FinalTokenPickups=" .. tostring(collected)
                                    .. " | RemainingTokenPrompts=0 | Scan may advance")
                            resetPendingCluster()
                            advanceScan()
                        else
                            setStatus("Aliens cleared; collecting remaining token drops before scanning")
                            recordEvent("TOKEN", "Scan advancement blocked by remaining token prompts",
                                "RemainingEnabledPrompts=" .. tostring(remainingTokenPrompts)
                                    .. " | ConfirmedThisPass=" .. tostring(collected)
                                    .. " | ScanAdvanceBlocked=true")
                            task.wait(0.5)
                        end
                    elseif #stillPending == 0 then
                        recordEvent("TARGET", "Alien models absent but a tracked target remains unresolved",
                            "TrackedEntities=" .. tostring(trackedAfterPass)
                                .. " | Active=" .. tostring(activeAfterPass)
                                .. " | Unconfirmed=" .. tostring(unconfirmedAfterPass)
                                .. " | ScanAdvanceBlocked=true")
                        setStatus("Waiting for remaining tracked alien; scan held")
                        task.wait(0.5)
                    elseif passCleared then
                        pendingClusterNoProgressPasses = 0
                        setStatus("Current tracked cluster cleared; checking for late spawns/drops")
                        task.wait(0.15)
                    elseif passMadeProgress then
                        pendingClusterNoProgressPasses = 0
                        setStatus("Alien impact confirmed; continuing until every active alien is cleared")
                        task.wait(0.2)
                    else
                        holdClusterWithoutProgress(stillPending)
                    end
                else
                    recordEvent("SCAN", "No alien target at scan point",
                        "Lap=" .. tostring(lap) .. " | Z=" .. tostring(scanZ)
                            .. " | DetectionRadius=" .. tostring(CONFIG.SCAN_DETECT_RADIUS))
                    local looseTokens = getAlienTokenPrompts(scanPosition, 80)
                    if #looseTokens > 0 then
                        recordEvent("TOKEN", "Loose Alien Tokens found during scan",
                            "Count=" .. tostring(#looseTokens) .. " | ScanZ=" .. tostring(scanZ))
                        setStatus("Loose Alien Tokens detected")
                        local collected = collectTokensAround(scanPosition, 100)
                        recordEvent("TOKEN", "Loose-token collection pass finished",
                            "ConfirmedThisPass=" .. tostring(collected))
                    end
                    advanceScan()
                end
            end
        end

        if os.clock() % 2 < 0.25 then
            task.wait(0.05)
        end
    end

    restoreMovement()
    restoreFullbright()
    stopAntiAfk()
    setStatus("Stopped")
end

-- Lightweight kill/reward feed tracking. No hooks or interception.
local function trackTextLabel(label)
    if not label:IsA("TextLabel") or trackedTextLabels[label] then
        return
    end
    trackedTextLabels[label] = true

    local function inspectText()
        local textValue = tostring(label.Text or "")
        local plainText = string.gsub(textValue, "<[^>]*>", "")
        local lowerText = string.lower(plainText)
        local oldText = lastLabelText[label]
        local pathLower = ""
        pcall(function() pathLower = string.lower(label:GetFullName()) end)
        local isAlienKillPath = string.find(pathLower, "killed:", 1, true) and string.find(pathLower, "alien", 1, true)
        local isAlienKillCount = isAlienKillPath and string.find(pathLower, ".count", 1, true)

        if isAlienKillCount then
            local currentCount = tonumber(string.match(plainText, "%((%d+)x%)"))
            local oldPlainText = string.gsub(oldText or "", "<[^>]*>", "")
            local previousCount = tonumber(string.match(oldPlainText, "%((%d+)x%)"))
            local delta = 0
            if currentCount then
                if previousCount == nil then
                    delta = currentCount
                elseif currentCount > previousCount then
                    delta = currentCount - previousCount
                elseif currentCount < previousCount then
                    delta = currentCount
                end
            end
            if delta > 0 then
                alienKills = alienKills + delta
                lastAlienKillAt = os.clock()
                recordEvent("KILL", "Alien kill counter increased", "Delta=" .. tostring(delta) .. " | NotificationCount=" .. tostring(currentCount) .. " | TotalObserved=" .. tostring(alienKills) .. " | Path=" .. pathLower)
            end
        elseif not isAlienKillPath and string.find(lowerText, "killed:%s*alien") then
            if not oldText or not string.find(string.lower(string.gsub(oldText, "<[^>]*>", "")), "killed:%s*alien") then
                alienKills = alienKills + 1
                lastAlienKillAt = os.clock()
                recordEvent("KILL", "Alien kill notification observed", "KillNotifications=" .. tostring(alienKills) .. " | Text=" .. plainText)
            end
        end

        if string.find(lowerText, "alien token", 1, true) then
            local amount = tonumber(string.match(textValue, "%+%s*(%d+)"))
            local frame = label.Parent
            if amount and frame and not rewardFramesSeen[frame] then
                rewardToastEstimate = rewardToastEstimate + amount
                rewardFramesSeen[frame] = true
                recordEvent("REWARD", "Alien Token reward toast observed", "ToastAmount=" .. tostring(amount) .. " | RunningToastEstimate=" .. tostring(rewardToastEstimate) .. " | This is not a verified wallet balance")
            elseif textValue == "" and frame then
                rewardFramesSeen[frame] = nil
            end
        elseif textValue == "" and label.Parent then
            rewardFramesSeen[label.Parent] = nil
        end

        lastLabelText[label] = textValue
    end

    inspectText()
    label:GetPropertyChangedSignal("Text"):Connect(inspectText)
end

local function monitorCharacterMovement(character)
    if not character or movementMonitorCharacters[character] then
        return
    end
    movementMonitorCharacters[character] = true
    expectedCharacterMove = nil
    task.spawn(function()
        local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 8)
        local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 8)
        if not root or not humanoid then
            recordThrottled("movement-monitor-missing-root", 2, "MOVEMENT", "Character movement monitor could not attach", "RootPart or Humanoid was not available")
            return
        end

        local previousPosition = root.Position
        local previousAt = os.clock()
        local previousState = humanoid:GetState()
        local previousFloor = humanoid.FloorMaterial
        recordEvent("MOVEMENT", "Character movement observer attached", string.format(
            "Character=%s | Start=(%.1f, %.1f, %.1f) | State=%s | Floor=%s",
            tostring(character.Name), previousPosition.X, previousPosition.Y, previousPosition.Z,
            tostring(previousState), tostring(previousFloor)
        ))

        local stateConnection = humanoid.StateChanged:Connect(function(oldState, newState)
            recordThrottled("humanoid-state:" .. tostring(newState), 0.2, "MOVEMENT", "Character humanoid state changed",
                "Old=" .. tostring(oldState) .. " | New=" .. tostring(newState)
                .. " | Health=" .. tostring(humanoid.Health) .. " | PlatformStand=" .. tostring(humanoid.PlatformStand))
        end)
        local floorConnection = humanoid:GetPropertyChangedSignal("FloorMaterial"):Connect(function()
            local floor = humanoid.FloorMaterial
            if floor ~= previousFloor then
                recordThrottled("floor-material:" .. tostring(floor), 0.2, "MOVEMENT", "Character floor material changed",
                    "Old=" .. tostring(previousFloor) .. " | New=" .. tostring(floor)
                    .. " | State=" .. tostring(humanoid:GetState()))
                previousFloor = floor
            end
        end)

        while character.Parent and root.Parent and humanoid.Parent do
            task.wait(0.12)
            local now = os.clock()
            local position = root.Position
            local dt = math.max(now - previousAt, 0.001)
            local displacement = position - previousPosition
            local velocity = root.AssemblyLinearVelocity
            local state = humanoid:GetState()
            local floor = humanoid.FloorMaterial
            local expected = expectedCharacterMove
                and (now - expectedCharacterMove.at) <= 1.25
                and (position - expectedCharacterMove.position).Magnitude <= 20
            movementSamples = movementSamples + 1

            if displacement.Magnitude >= 75 then
                local from = string.format("(%.1f, %.1f, %.1f)", previousPosition.X, previousPosition.Y, previousPosition.Z)
                local to = string.format("(%.1f, %.1f, %.1f)", position.X, position.Y, position.Z)
                if expected then
                    recordThrottled("expected-reposition:" .. tostring(expectedCharacterMove.reason), 0.25, "MOVEMENT",
                        "Large farmer-requested reposition observed", string.format(
                            "Reason=%s | From=%s | To=%s | Delta=%.1f | SampleDt=%.3f",
                            tostring(expectedCharacterMove.reason), from, to, displacement.Magnitude, dt
                        ))
                else
                    movementAnomalyCount = movementAnomalyCount + 1
                    recordEvent("MOVEMENT_ALERT", "Unexpected character displacement / possible teleport",
                        string.format("From=%s | To=%s | Delta=%.1f studs | Speed=%.1f studs/s | Velocity=(%.1f, %.1f, %.1f) | State=%s | Floor=%s | Health=%.1f/%.1f | Target=%s | Running=%s | Paused=%s",
                            from, to, displacement.Magnitude, displacement.Magnitude / dt,
                            velocity.X, velocity.Y, velocity.Z, tostring(state), tostring(floor),
                            humanoid.Health, humanoid.MaxHealth, tostring(currentTarget), tostring(running), tostring(paused)))
                end
            end

            local freefallState = state == Enum.HumanoidStateType.Freefall
                or state == Enum.HumanoidStateType.FallingDown
                or state == Enum.HumanoidStateType.Physics
            local rapidDrop = floor == Enum.Material.Air
                and not expected
                and ((freefallState and velocity.Y <= -35) or (displacement.Y <= -15 and dt <= 0.4))
            if rapidDrop then
                local warningEvent = recordThrottled("possible-character-fall", 0.75, "MOVEMENT_ALERT", "Possible character fall / void descent",
                    string.format("Position=(%.1f, %.1f, %.1f) | DeltaY=%.1f | VelocityY=%.1f | State=%s | Floor=%s | Health=%.1f/%.1f | Target=%s | ExpectedMove=%s",
                        position.X, position.Y, position.Z, displacement.Y, velocity.Y, tostring(state), tostring(floor),
                        humanoid.Health, humanoid.MaxHealth, tostring(currentTarget), tostring(expected)))
                if warningEvent then fallWarningCount = fallWarningCount + 1 end
            end

            previousPosition = position
            previousAt = now
            previousState = state
        end
        pcall(function() stateConnection:Disconnect() end)
        pcall(function() floorConnection:Disconnect() end)
        recordEvent("MOVEMENT", "Character movement observer detached", "Character=" .. tostring(character.Name))
    end)
end

local function monitorCharacter(character)
    if not character then
        return
    end
    local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 8)
    if not humanoid or monitoredHumanoids[humanoid] then
        return
    end
    monitoredHumanoids[humanoid] = true
    playerHealthCurrent = humanoid.Health
    playerHealthMax = humanoid.MaxHealth
    recordEvent("PLAYER", "Character monitor attached", "Health=" .. tostring(humanoid.Health) .. "/" .. tostring(humanoid.MaxHealth))
    local previousHealth = humanoid.Health
    humanoid.HealthChanged:Connect(function(newHealth)
        playerHealthCurrent = newHealth
        playerHealthMax = humanoid.MaxHealth
        if newHealth < previousHealth then
            recordEvent("PLAYER", "Player health decreased", string.format("Health=%.1f->%.1f | MaxHealth=%.1f", previousHealth, newHealth, humanoid.MaxHealth))
        elseif newHealth > previousHealth then
            recordThrottled("health-heal", 0.5, "PLAYER", "Player health increased", string.format("Health=%.1f->%.1f", previousHealth, newHealth))
        end
        previousHealth = newHealth
        local lowHealthThreshold = humanoid.MaxHealth * (CONFIG.LOW_HEALTH_STOP_PERCENT / 100)
        if running and not lowHealthStopTriggered and humanoid.MaxHealth > 0 and newHealth <= lowHealthThreshold then
            lowHealthStopTriggered = true
            recordEvent("PLAYER", "Low-health safety threshold reached",
                string.format("Health=%.1f/%.1f | Threshold=%.0f%% | Farming will stop and restore player control", newHealth, humanoid.MaxHealth, CONFIG.LOW_HEALTH_STOP_PERCENT))
            task.defer(function()
                if stopFarm and running then
                    stopFarm("LOW_HEALTH")
                end
            end)
        end
    end)
    humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
        playerHealthMax = humanoid.MaxHealth
        recordThrottled("player-max-health", 1, "PLAYER", "Player MaxHealth changed", "MaxHealth=" .. tostring(playerHealthMax))
    end)
    humanoid.Died:Connect(function()
        playerHealthCurrent = 0
        playerDeathEvents = playerDeathEvents + 1
        recordEvent("PLAYER", "Player humanoid died", "Health=" .. tostring(humanoid.Health)
            .. " | DeathEvents=" .. tostring(playerDeathEvents))
    end)
end

local function monitorTool(tool)
    if not tool or not tool:IsA("Tool") or monitoredTools[tool] then
        return
    end
    monitoredTools[tool] = { connections = {} }
    local toolPath = "unknown"
    pcall(function() toolPath = tool:GetFullName() end)
    recordEvent("WEAPON", "Tool diagnostic monitor attached", "Tool=" .. tostring(tool.Name)
        .. " | Enabled=" .. tostring(tool.Enabled) .. " | Path=" .. toolPath)

    local activatedOk, activatedConnection = pcall(function()
        return tool.Activated:Connect(function()
            nativeToolActivations = nativeToolActivations + 1
            lastManualToolActivationAt = os.clock()
            local inputAge = lastManualInputAt and (os.clock() - lastManualInputAt) or math.huge
            recordEvent("WEAPON", "Native Tool.Activated signal observed", "Tool=" .. tostring(tool.Name)
                .. " | Count=" .. tostring(nativeToolActivations)
                .. " | RecentMouseOrTouch=" .. tostring(inputAge <= 0.5)
                .. " | InputAge=" .. (inputAge < math.huge and string.format("%.3f", inputAge) or "none")
                .. " | InputKind=" .. tostring(lastManualInputKind)
                .. " | InputGameProcessed=" .. tostring(lastManualInputProcessed)
                .. " | Target=" .. tostring(currentTarget)
                .. " | Running=" .. tostring(running) .. " | Paused=" .. tostring(paused)
                .. " | Native activation is timing evidence, not proof of damage")
        end)
    end)
    if activatedOk and activatedConnection then
        table.insert(monitoredTools[tool].connections, activatedConnection)
    elseif not activatedOk then
        recordEvent("ERROR", "Tool.Activated monitor failed", "Tool=" .. tostring(tool.Name) .. " | Error=" .. tostring(activatedConnection))
    end

    local equippedOk, equippedConnection = pcall(function()
        return tool.Equipped:Connect(function()
            toolEquippedEvents = toolEquippedEvents + 1
            recordThrottled("tool-equipped:" .. tostring(tool.Name), 0.75, "WEAPON", "Tool Equipped event observed",
                "Tool=" .. tostring(tool.Name) .. " | Parent=" .. tostring(tool.Parent and tool.Parent.Name)
                    .. " | TotalEquippedEvents=" .. tostring(toolEquippedEvents))
        end)
    end)
    if equippedOk and equippedConnection then table.insert(monitoredTools[tool].connections, equippedConnection) end
    local unequippedOk, unequippedConnection = pcall(function()
        return tool.Unequipped:Connect(function()
            toolUnequippedEvents = toolUnequippedEvents + 1
            recordThrottled("tool-unequipped:" .. tostring(tool.Name), 0.75, "WEAPON", "Tool Unequipped event observed",
                "Tool=" .. tostring(tool.Name) .. " | TotalUnequippedEvents=" .. tostring(toolUnequippedEvents))
        end)
    end)
    if unequippedOk and unequippedConnection then table.insert(monitoredTools[tool].connections, unequippedConnection) end

    local enabledOk, enabledConnection = pcall(function()
        local previousEnabled = tool.Enabled
        return tool:GetPropertyChangedSignal("Enabled"):Connect(function()
            local currentEnabled = tool.Enabled
            recordEvent("WEAPON", "Tool.Enabled changed", "Tool=" .. tostring(tool.Name)
                .. " | Old=" .. tostring(previousEnabled) .. " | New=" .. tostring(currentEnabled))
            previousEnabled = currentEnabled
        end)
    end)
    if enabledOk and enabledConnection then
        table.insert(monitoredTools[tool].connections, enabledConnection)
    elseif not enabledOk then
        recordEvent("ERROR", "Tool.Enabled monitor failed", "Tool=" .. tostring(tool.Name) .. " | Error=" .. tostring(enabledConnection))
    end
end

local function monitorToolContainer(container)
    if not container then
        return
    end
    for _, child in ipairs(container:GetChildren()) do
        monitorTool(child)
    end
    container.ChildAdded:Connect(function(child)
        monitorTool(child)
    end)
end

local function startManualInputMonitoring()
    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        local inputType = input.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 then
            manualMouseDownCount = manualMouseDownCount + 1
            local character = LocalPlayer.Character
            local tool = character and character:FindFirstChildOfClass("Tool")
            local root = character and character:FindFirstChild("HumanoidRootPart")
            local camera = Workspace.CurrentCamera
            if tool and not gameProcessed then
                lastManualInputAt = os.clock()
                lastManualInputKind = "MouseButton1"
            end
            lastManualInputProcessed = gameProcessed == true
            local rootText = root and string.format("(%.1f, %.1f, %.1f)", root.Position.X, root.Position.Y, root.Position.Z) or "unknown"
            local lookText = camera and string.format("(%.2f, %.2f, %.2f)", camera.CFrame.LookVector.X, camera.CFrame.LookVector.Y, camera.CFrame.LookVector.Z) or "unknown"
            recordEvent("INPUT", "MouseButton1 input began", "Count=" .. tostring(manualMouseDownCount)
                .. " | GameProcessed=" .. tostring(gameProcessed == true)
                .. " | EquippedTool=" .. tostring(tool and tool.Name or "None")
                .. " | Root=" .. rootText .. " | CameraLook=" .. lookText
                .. " | Running=" .. tostring(running) .. " | Paused=" .. tostring(paused)
                .. " | Target=" .. tostring(currentTarget))
        elseif inputType == Enum.UserInputType.Touch then
            manualTouchCount = manualTouchCount + 1
            local character = LocalPlayer.Character
            local tool = character and character:FindFirstChildOfClass("Tool")
            local root = character and character:FindFirstChild("HumanoidRootPart")
            local camera = Workspace.CurrentCamera
            if tool and not gameProcessed then
                lastManualInputAt = os.clock()
                lastManualInputKind = "Touch"
            end
            lastManualInputProcessed = gameProcessed == true
            local rootText = root and string.format("(%.1f, %.1f, %.1f)", root.Position.X, root.Position.Y, root.Position.Z) or "unknown"
            local lookText = camera and string.format("(%.2f, %.2f, %.2f)", camera.CFrame.LookVector.X, camera.CFrame.LookVector.Y, camera.CFrame.LookVector.Z) or "unknown"
            recordEvent("INPUT", "Touch input began", "Count=" .. tostring(manualTouchCount)
                .. " | GameProcessed=" .. tostring(gameProcessed == true)
                .. " | EquippedTool=" .. tostring(tool and tool.Name or "None")
                .. " | Root=" .. rootText .. " | CameraLook=" .. lookText
                .. " | Running=" .. tostring(running) .. " | Paused=" .. tostring(paused)
                .. " | Target=" .. tostring(currentTarget))
        end
    end)
    UserInputService.InputEnded:Connect(function(input, gameProcessed)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            manualMouseUpCount = manualMouseUpCount + 1
            recordThrottled("mouse1-up", 0.08, "INPUT", "MouseButton1 input ended",
                "Count=" .. tostring(manualMouseUpCount) .. " | GameProcessed=" .. tostring(gameProcessed == true))
        end
    end)
    recordEvent("INPUT", "Manual input observer active", "Observes MouseButton1 and Touch only; no input interception or synthetic input")
end

local function startToolMonitoring()
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack") or LocalPlayer:FindFirstChild("Backpack")
    if not backpack then
        backpack = LocalPlayer:WaitForChild("Backpack", 10)
    end
    monitorToolContainer(backpack)
    monitorToolContainer(LocalPlayer.Character)
    recordEvent("WEAPON", "Native tool activation monitoring active", "Monitoring Tool.Activated, Equipped/Unequipped, Enabled and physical mouse/touch input; no input interception")
end

local function hookPlayerGui()
    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 10)
    if not playerGui then
        return
    end
    for _, descendant in ipairs(playerGui:GetDescendants()) do
        trackTextLabel(descendant)
    end
    playerGui.DescendantAdded:Connect(function(descendant)
        if descendant:IsA("TextLabel") then
            trackTextLabel(descendant)
        end
    end)
end

-- Minimal control panel.
local guiParent
if type(gethui) == "function" then
    pcall(function() guiParent = gethui() end)
end
if not guiParent then
    guiParent = LocalPlayer:WaitForChild("PlayerGui")
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "LastStopAlienFarmerV1"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.Parent = guiParent

local frame = Instance.new("Frame")
frame.Name = "Main"
frame.Size = UDim2.new(0, 330, 0, 220)
frame.Position = UDim2.new(0, 20, 0.35, 0)
frame.BackgroundColor3 = Color3.fromRGB(18, 22, 28)
frame.BorderSizePixel = 0
frame.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 9)
corner.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -16, 0, 28)
title.Position = UDim2.new(0, 8, 0, 6)
title.BackgroundTransparency = 1
title.Text = "LAST STOP - ALIEN FARMER"
title.TextColor3 = Color3.fromRGB(115, 235, 150)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -16, 0, 34)
statusLabel.Position = UDim2.new(0, 8, 0, 36)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Initializing..."
statusLabel.TextColor3 = Color3.fromRGB(225, 230, 235)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 11
statusLabel.TextWrapped = true
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Parent = frame

local statsLabel = Instance.new("TextLabel")
statsLabel.Size = UDim2.new(1, -16, 0, 108)
statsLabel.Position = UDim2.new(0, 8, 0, 72)
statsLabel.BackgroundTransparency = 1
statsLabel.Text = "Alien kills: 0\nToken pickups confirmed: 0\nReward toast estimate: 0"
statsLabel.TextColor3 = Color3.fromRGB(190, 200, 210)
statsLabel.Font = Enum.Font.Code
statsLabel.TextSize = 11
statsLabel.TextXAlignment = Enum.TextXAlignment.Left
statsLabel.TextYAlignment = Enum.TextYAlignment.Top
statsLabel.Parent = frame

local pauseButton = Instance.new("TextButton")
pauseButton.Size = UDim2.new(0.31, -6, 0, 30)
pauseButton.Position = UDim2.new(0, 8, 1, -38)
pauseButton.BackgroundColor3 = Color3.fromRGB(54, 86, 120)
pauseButton.TextColor3 = Color3.new(1, 1, 1)
pauseButton.Font = Enum.Font.GothamBold
pauseButton.TextSize = 11
pauseButton.Text = "PAUSE"
pauseButton.Parent = frame
local pauseCorner = Instance.new("UICorner")
pauseCorner.CornerRadius = UDim.new(0, 6)
pauseCorner.Parent = pauseButton

local stopButton = Instance.new("TextButton")
stopButton.Size = UDim2.new(0.31, -6, 0, 30)
stopButton.Position = UDim2.new(0.345, -2, 1, -38)
stopButton.BackgroundColor3 = Color3.fromRGB(130, 55, 55)
stopButton.TextColor3 = Color3.new(1, 1, 1)
stopButton.Font = Enum.Font.GothamBold
stopButton.TextSize = 11
stopButton.Text = "STOP"
stopButton.Parent = frame
local stopCorner = Instance.new("UICorner")
stopCorner.CornerRadius = UDim.new(0, 6)
stopCorner.Parent = stopButton

local diagButton = Instance.new("TextButton")
diagButton.Size = UDim2.new(0.31, -6, 0, 30)
diagButton.Position = UDim2.new(0.69, -2, 1, -38)
diagButton.BackgroundColor3 = Color3.fromRGB(70, 92, 105)
diagButton.TextColor3 = Color3.new(1, 1, 1)
diagButton.Font = Enum.Font.GothamBold
diagButton.TextSize = 10
diagButton.Text = "DIAGNOSTICS"
diagButton.Parent = frame
local diagButtonCorner = Instance.new("UICorner")
diagButtonCorner.CornerRadius = UDim.new(0, 6)
diagButtonCorner.Parent = diagButton

local diagPanelCorner
local diagScroll
local diagCopyButton
local diagExportButton
local diagCloseButton

diagPanel = Instance.new("Frame")
diagPanel.Name = "Diagnostics"
diagPanel.Size = UDim2.new(0, 440, 0, 310)
diagPanel.Position = UDim2.new(0, 360, 0.35, 0)
diagPanel.BackgroundColor3 = Color3.fromRGB(16, 20, 26)
diagPanel.BorderSizePixel = 0
diagPanel.Visible = false
diagPanel.Parent = screenGui
diagPanelCorner = Instance.new("UICorner")
diagPanelCorner.CornerRadius = UDim.new(0, 9)
diagPanelCorner.Parent = diagPanel

local diagTitle = Instance.new("TextLabel")
diagTitle.Size = UDim2.new(1, -90, 0, 26)
diagTitle.Position = UDim2.new(0, 10, 0, 7)
diagTitle.BackgroundTransparency = 1
diagTitle.Text = "DIAGNOSTICS / EVENT TIMELINE"
diagTitle.TextColor3 = Color3.fromRGB(115, 235, 150)
diagTitle.Font = Enum.Font.GothamBold
diagTitle.TextSize = 12
diagTitle.TextXAlignment = Enum.TextXAlignment.Left
diagTitle.Parent = diagPanel

diagCountLabel = Instance.new("TextLabel")
diagCountLabel.Size = UDim2.new(1, -20, 0, 18)
diagCountLabel.Position = UDim2.new(0, 10, 0, 34)
diagCountLabel.BackgroundTransparency = 1
diagCountLabel.Text = "Events: 0 | Errors: 0"
diagCountLabel.TextColor3 = Color3.fromRGB(180, 190, 200)
diagCountLabel.Font = Enum.Font.Code
diagCountLabel.TextSize = 10
diagCountLabel.TextXAlignment = Enum.TextXAlignment.Left
diagCountLabel.Parent = diagPanel

diagCloseButton = Instance.new("TextButton")
diagCloseButton.Size = UDim2.new(0, 28, 0, 24)
diagCloseButton.Position = UDim2.new(1, -36, 0, 7)
diagCloseButton.BackgroundColor3 = Color3.fromRGB(95, 55, 55)
diagCloseButton.Text = "X"
diagCloseButton.TextColor3 = Color3.new(1, 1, 1)
diagCloseButton.Font = Enum.Font.GothamBold
diagCloseButton.TextSize = 11
diagCloseButton.Parent = diagPanel

local diagScrollCorner

diagScroll = Instance.new("ScrollingFrame")
diagScroll.Size = UDim2.new(1, -20, 1, -104)
diagScroll.Position = UDim2.new(0, 10, 0, 56)
diagScroll.BackgroundColor3 = Color3.fromRGB(25, 30, 38)
diagScroll.BorderSizePixel = 0
diagScroll.ScrollBarThickness = 6
diagScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
diagScroll.Parent = diagPanel
diagScrollCorner = Instance.new("UICorner")
diagScrollCorner.CornerRadius = UDim.new(0, 5)
diagScrollCorner.Parent = diagScroll

diagText = Instance.new("TextLabel")
diagText.Size = UDim2.new(1, -12, 0, 0)
diagText.Position = UDim2.new(0, 6, 0, 6)
diagText.AutomaticSize = Enum.AutomaticSize.Y
diagText.BackgroundTransparency = 1
diagText.Text = "Waiting for events..."
diagText.TextColor3 = Color3.fromRGB(205, 215, 225)
diagText.Font = Enum.Font.Code
diagText.TextSize = 10
diagText.TextWrapped = true
diagText.TextXAlignment = Enum.TextXAlignment.Left
diagText.TextYAlignment = Enum.TextYAlignment.Top
diagText.Parent = diagScroll

local function buildVisibleDiagnostics()
    local lines = {}
    local first = math.max(1, #diagEvents - 59)
    for index = first, #diagEvents do
        local event = diagEvents[index]
        local line = string.format("[%s] [%s] %s", event.time, event.category, event.message)
        if event.details ~= "" then
            line = line .. " | " .. event.details
        end
        table.insert(lines, line)
    end
    return #lines > 0 and table.concat(lines, "\n") or "Waiting for events..."
end

refreshDiagPanel = function()
    if not diagPanel or not diagPanel.Parent then
        return
    end
    diagText.Text = buildVisibleDiagnostics()
    diagCountLabel.Text = "Events: " .. tostring(#diagEvents) .. " / " .. tostring(diagMaxEvents) .. " | Errors: " .. tostring(diagErrorCount)
    task.defer(function()
        if diagScroll and diagScroll.Parent and diagText and diagText.Parent then
            local height = diagText.TextBounds.Y + 16
            diagScroll.CanvasSize = UDim2.new(0, 0, 0, height)
            diagScroll.CanvasPosition = Vector2.new(0, math.max(0, height - diagScroll.AbsoluteSize.Y))
        end
    end)
end

local function copyDiagnostics()
    recordEvent("DIAGNOSTICS", "Copy requested", "Preparing current event history")
    local report = buildDiagnosticReport()
    local clipboardFunction = setclipboard or toclipboard
    if type(clipboardFunction) == "function" then
        local ok, copyError = pcall(clipboardFunction, report)
        if ok then
            setStatus("Diagnostics copied to clipboard")
            recordEvent("DIAGNOSTICS", "Diagnostics copied", "Clipboard API returned without error")
        else
            recordEvent("ERROR", "Clipboard copy failed", diagTraceback(copyError))
            setStatus("Clipboard copy failed; use Export Logs")
        end
    else
        setStatus("Clipboard API unavailable; use Export Logs")
        recordEvent("ERROR", "Clipboard API unavailable", "Neither setclipboard nor toclipboard is exposed by this executor")
    end
end

local function exportDiagnostics()
    if type(writefile) ~= "function" then
        recordEvent("ERROR", "File export unavailable", "Executor does not expose writefile")
        setStatus("File export unavailable; try Copy Diagnostics")
        return
    end
    local folderName = "LastStopAlienFarmer"
    local prefix = ""
    if type(makefolder) == "function" then
        local folderReady = false
        if type(isfolder) == "function" then
            local checkOk, exists = pcall(isfolder, folderName)
            folderReady = checkOk and exists == true
        end
        if not folderReady then
            local makeOk = pcall(makefolder, folderName)
            folderReady = makeOk
            if type(isfolder) == "function" then
                local checkOk, exists = pcall(isfolder, folderName)
                folderReady = checkOk and exists == true
            end
        end
        if folderReady then
            prefix = folderName .. "/"
        end
    end
    recordEvent("DIAGNOSTICS", "Export requested", "Writing text and JSON event history")
    local report = buildDiagnosticReport()
    local jsonPayload = ""
    local jsonOk, jsonResult = pcall(function()
        return HttpService:JSONEncode({
            version = "HF9.9-CENTERED-UNDERBODY-TETHER-NEAREST-CONTACT-TARGET-ROTATION-HEALTH-GUARD-ANTIAFK",
            scanAdvanceCount = scanAdvanceCount,
            deferredAlienGuidCount = deferredAlienGuidCount,
            gameId = game.GameId,
            placeId = game.PlaceId,
            status = currentStatus,
            alienKills = alienKills,
            hoverTetherActive = hoverTetherConnection ~= nil,
            hoverTetherTarget = hoverTetherEntry and hoverTetherEntry.model and hoverTetherEntry.model.Name or "None",
            hoverBelowTorso = CONFIG.HOVER_BELOW,
            hoverHorizontalOffset = CONFIG.TORSO_HORIZONTAL_STANDOFF,
            serverDamageEvents = serverDamageEvents,
            serverOnDiedEvents = serverOnDiedEvents,
            serverMeleeEffects = serverMeleeEffects,
            serverConfirmedAlienHitEvents = serverConfirmedAlienHitEvents,
            serverNonAlienMeleeEffects = serverNonAlienMeleeEffects,
            serverAlienDeathEvents = serverAlienDeathEvents,
            serverNonAlienDeathEvents = serverNonAlienDeathEvents,
            monitoredAlienModels = monitoredAlienModelsTotal,
            alienHealthSourcesFound = alienHealthSourcesFound,
            alienDamageEvents = alienDamageEvents,
            alienDeathEvents = alienDeathEvents,
            alienHealthUiEvents = alienHealthUiEvents,
            automatedDamageUiEvents = automatedDamageUiEvents,
            nativeToolActivations = nativeToolActivations,
            automatedAttackRequests = automatedAttackRequests,
            automatedHitRequests = automatedHitRequests,
            toolEquipAttempts = toolEquipAttempts,
            toolEquippedEvents = toolEquippedEvents,
            toolUnequippedEvents = toolUnequippedEvents,
            playerHealthCurrent = playerHealthCurrent,
            playerHealthMax = playerHealthMax,
            playerDeathEvents = playerDeathEvents,
            meleeReplicaId = lastResolvedMeleeReplicaId,
            meleeReplicaIdSource = lastReplicaIdSource,
            replicaControllerPath = replicaControllerPath,
            replicaRegistryIndexed = replicaRegistryIndexed,
            manualMouseDownCount = manualMouseDownCount,
            manualMouseUpCount = manualMouseUpCount,
            manualTouchCount = manualTouchCount,
            lastManualInputKind = lastManualInputKind,
            lastManualInputProcessed = lastManualInputProcessed,
            movementSamples = movementSamples,
            movementAnomalyCount = movementAnomalyCount,
            fallWarningCount = fallWarningCount,
            alienHealthSnapshot = buildAlienHealthSnapshot(),
            tokenAttempts = tokenAttempts,
            tokenPickupsConfirmed = tokenPickupsConfirmed,
            tokenDropCentersQueued = tokenDropCentersQueued,
            tokenDropCentersProcessed = tokenDropCentersProcessed,
            pendingTokenDropCenters = #pendingTokenDropCenters,
            antiAfkAvailable = antiAfkAvailable,
            antiAfkEvents = antiAfkEvents,
            antiAfkErrors = antiAfkErrors,
            rewardToastEstimate = rewardToastEstimate,
            localCallErrors = remoteErrors,
            capturedErrors = diagErrorCount,
            categoryCounts = diagCounts,
            config = CONFIG,
            events = diagEvents,
        })
    end)
    if jsonOk then
        jsonPayload = jsonResult
    else
        recordEvent("ERROR", "JSON serialization failed", diagTraceback(jsonResult))
    end
    local textOk, textError = pcall(writefile, prefix .. "diagnostics.txt", report)
    local dataOk, dataError = false, "JSON serialization unavailable"
    if jsonOk then
        dataOk, dataError = pcall(writefile, prefix .. "diagnostics.json", jsonPayload)
    end
    if textOk and dataOk then
        setStatus("Diagnostics exported to " .. prefix)
        recordEvent("DIAGNOSTICS", "Export completed", "Files=diagnostics.txt, diagnostics.json | Folder=" .. (prefix ~= "" and prefix or "executor root"))
    else
        setStatus("Export failed; inspect diagnostics")
        recordEvent("ERROR", "File export failed", "Text=" .. tostring(textError) .. " | JSON=" .. tostring(dataError))
    end
end

local function refreshGui()
    if statusLabel and statusLabel.Parent then
        statusLabel.Text = currentStatus .. "\nTarget: " .. tostring(currentTarget)
    end
    if statsLabel and statsLabel.Parent then
        statsLabel.Text = "Alien kills: " .. tostring(alienKills)
            .. "\nServer damage: " .. tostring(serverDamageEvents) .. " | Deaths: " .. tostring(serverOnDiedEvents)
            .. "\nToken pickups confirmed: " .. tostring(tokenPickupsConfirmed)
            .. " / attempts: " .. tostring(tokenAttempts)
            .. "\nReward toast estimate: " .. tostring(rewardToastEstimate)
            .. "\nAnti-AFK: " .. (antiAfkAvailable and "ON" or "OFF") .. " | Idle events: " .. tostring(antiAfkEvents)
            .. "\nTool: " .. tostring(equippedToolName)
            .. "\nLap: " .. tostring(lap) .. "  Scan Z: " .. tostring(scanZ)
            .. "\nLocal call errors: " .. tostring(remoteErrors)
            .. " | Diagnostics: " .. tostring(#diagEvents)
            .. " | Captured errors: " .. tostring(diagErrorCount)
    end
    if pauseButton and pauseButton.Parent then
        pauseButton.Text = paused and "RESUME" or "PAUSE"
    end
end

pauseButton.Activated:Connect(function()
    if not running then
        return
    end
    paused = not paused
    setStatus(paused and "Paused" or "Resuming")
    recordEvent("SYSTEM", paused and "Farming paused" or "Farming resumed", "Pause control activated")
    refreshGui()
end)

stopFarm = function(reason)
    local lowHealthStop = reason == "LOW_HEALTH"
    if lowHealthStop then
        recordEvent("SYSTEM", "Automatic low-health emergency stop",
            "Health threshold=" .. tostring(CONFIG.LOW_HEALTH_STOP_PERCENT) .. "% | Farming stopped; movement/collision state restored | No unverified bus teleport attempted")
    else
        recordEvent("SYSTEM", "Stop requested by user", "Emergency stop button activated")
    end
    running = false
    paused = false
    stopAntiAfk()
    for _, connection in ipairs(serverMonitorConnections) do
        pcall(function() connection:Disconnect() end)
    end
    serverMonitorConnections = {}
    restoreMovement()
    restoreFullbright()
    setStatus(lowHealthStop and "Emergency stopped at low health; escape/heal before restarting" or "Stopped by user")
    refreshGui()
end

stopButton.Activated:Connect(function()
    if stopFarm then stopFarm("USER") end
end)

diagButton.Activated:Connect(function()
    diagPanel.Visible = not diagPanel.Visible
    refreshDiagPanel()
end)
diagCloseButton.Activated:Connect(function()
    diagPanel.Visible = false
end)

diagCopyButton = Instance.new("TextButton")
diagCopyButton.Size = UDim2.new(0.48, -6, 0, 30)
diagCopyButton.Position = UDim2.new(0, 10, 1, -38)
diagCopyButton.BackgroundColor3 = Color3.fromRGB(54, 86, 120)
diagCopyButton.TextColor3 = Color3.new(1, 1, 1)
diagCopyButton.Font = Enum.Font.GothamBold
diagCopyButton.TextSize = 10
diagCopyButton.Text = "COPY DIAGNOSTICS"
diagCopyButton.Parent = diagPanel
local diagCopyCorner = Instance.new("UICorner")
diagCopyCorner.CornerRadius = UDim.new(0, 6)
diagCopyCorner.Parent = diagCopyButton

diagExportButton = Instance.new("TextButton")
diagExportButton.Size = UDim2.new(0.48, -6, 0, 30)
diagExportButton.Position = UDim2.new(0.52, -2, 1, -38)
diagExportButton.BackgroundColor3 = Color3.fromRGB(65, 105, 75)
diagExportButton.TextColor3 = Color3.new(1, 1, 1)
diagExportButton.Font = Enum.Font.GothamBold
diagExportButton.TextSize = 10
diagExportButton.Text = "EXPORT LOGS"
diagExportButton.Parent = diagPanel
local diagExportCorner = Instance.new("UICorner")
diagExportCorner.CornerRadius = UDim.new(0, 6)
diagExportCorner.Parent = diagExportButton

diagCopyButton.Activated:Connect(copyDiagnostics)
diagExportButton.Activated:Connect(exportDiagnostics)

LocalPlayer.CharacterAdded:Connect(function(character)
    task.wait(1)
    monitorCharacter(character)
    monitorCharacterMovement(character)
    monitorToolContainer(character)
    recordEvent("PLAYER", "Character respawned", "Character=" .. tostring(character.Name))
    if running then
        setupFlight()
    end
end)
if LocalPlayer.Character then
    task.spawn(monitorCharacter, LocalPlayer.Character)
    task.spawn(monitorCharacterMovement, LocalPlayer.Character)
end

startAlienHealthMonitoring()
startToolMonitoring()
startManualInputMonitoring()
hookPlayerGui()
startAntiAfk()

-- Keep the compact HUD current without scanning the world every frame.
task.spawn(function()
    while screenGui.Parent do
        refreshGui()
        task.wait(0.25)
    end
end)

task.spawn(function()
    while screenGui.Parent do
        local _, root = getCharacter()
        local camera = Workspace.CurrentCamera
        if root and camera then
            local gap = (camera.CFrame.Position - root.Position).Magnitude
            if gap > 100 then
                recordThrottled("camera-root-gap", 2.0, "CAMERA", "Camera/root offset observed (informational; may be intentional safe-hover view)", string.format("Gap=%.1f studs | Root=(%.1f, %.1f, %.1f) | Camera=(%.1f, %.1f, %.1f) | Target=%s | No movement error inferred from camera offset alone", gap, root.Position.X, root.Position.Y, root.Position.Z, camera.CFrame.Position.X, camera.CFrame.Position.Y, camera.CFrame.Position.Z, tostring(currentTarget)))
            end
        end
        task.wait(0.5)
    end
end)

local function startFarm()
    if running then
        return
    end
    local _, _, startHumanoid = getCharacter()
    if startHumanoid and startHumanoid.MaxHealth > 0 then
        local startHealthPercent = (startHumanoid.Health / startHumanoid.MaxHealth) * 100
        if startHealthPercent <= CONFIG.LOW_HEALTH_STOP_PERCENT then
            lowHealthStopTriggered = true
            recordEvent("PLAYER", "Automatic start blocked by low-health safety threshold",
                string.format("Health=%.1f/%.1f | Current=%.1f%% | RequiredAbove=%.0f%%", startHumanoid.Health, startHumanoid.MaxHealth, startHealthPercent, CONFIG.LOW_HEALTH_STOP_PERCENT))
            setStatus("Start blocked: heal above " .. tostring(CONFIG.LOW_HEALTH_STOP_PERCENT) .. "% health first")
            refreshGui()
            return
        end
    end
    lowHealthStopTriggered = false
    running = true
    paused = false
    startAntiAfk()
    recordEvent("SYSTEM", "Farming started", "Automatic scan/combat/token loop started")
    applyFullbright()
    setupFlight()
    if mainLoopThread then
        mainLoopThread = nil
    end
    mainLoopThread = task.spawn(function()
        local ok, loopError = pcall(mainLoop)
        if not ok then
            recordEvent("ERROR", "Main farming loop crashed", diagTraceback(loopError))
            running = false
            paused = false
            stopAntiAfk()
            restoreMovement()
            restoreFullbright()
            setStatus("Stopped after error - open Diagnostics")
            refreshGui()
        end
    end)
    refreshGui()
end

-- Automatic start: execute one script and the farm begins by itself.
task.delay(2, function()
    if screenGui.Parent and not running then
        startFarm()
    end
end)

recordEvent("SYSTEM", "Script initialization complete", "Automatic start scheduled | Target allowlist=AlienType1/2/3 | Zombie/Parasite marker exclusion + 10-stud non-alien collateral guard | MeleeContactRange=10 (hard ceiling 80) | TargetRotation=" .. tostring(CONFIG.TARGET_STALL_TIMEOUT) .. "s stall / " .. tostring(CONFIG.TARGET_RETRY_COOLDOWN) .. "s retry | LowHealthStop=" .. tostring(CONFIG.LOW_HEALTH_STOP_PERCENT) .. "% | ClusterPolicy=UNLIMITED; no survivor deferral | TokenCollection=death-position centered with retries | AntiAFK=" .. tostring(antiAfkAvailable) .. " | AttackDirection=nearest valid alien contact | Diagnostics=HF9.9 | UnderbodyTether=Heartbeat, 6.5 below torso, zero lateral offset | Hooks=none")
refreshDiagPanel()
log("Loaded HF9.9. Automatic start scheduled. Continuous centered underbody tether (6.5 below torso, zero lateral offset), nearest valid contact selection, target rotation on no confirmed hits, 35% low-health stop, 10-stud collateral guard, full-cluster clearing, death-position token collection/retries, and anti-AFK enabled.")
