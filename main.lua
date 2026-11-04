--[[
LAST STOP - ALIEN TOKEN FARMER V1.0.1-HF5.4 (SAFE HOVER + SURFACE CONTACT)
Standalone experimental build for the Last Stop Roblox experience.

Observed game structures used:
  Workspace.ENTITY_CONTAINER.<GUID>.Dress.AlienType1/2/3
  Workspace.ITEM_CONTAINER.<GUID>.Main.CollectAlienTokenPrompt
  ReplicatedStorage.ClientSource.ReplicaRemoteEvents.Replica_ReplicaSignal

Observed melee signal shape from the supplied V1.2 diagnostics:
  FireServer(120, "Melee", "Attack", direction, 1)
  FireServer(120, "Melee", "Hit", part, hitPosition, normal, material)

No external loaders, no global metamethod hooks, no input interception.
Passive UserInputService event listeners are used for diagnostics; no synthetic input is sent.
The attack signal is based on observed traffic, but still needs in-game validation.
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
    ALIEN_ATTACK_RANGE = 50,
    HOVER_BELOW = 6.5,
    ATTACK_INTERVAL = 0.05,
    MELEE_HIT_DELAY = 0.026, -- observed Attack -> first Hit delay in the working Auto Kill traffic
    ENGAGE_TIMEOUT = 45,
    NO_KILL_TIMEOUT = 8,
    MAX_HITS_PER_TARGET = 10,
    MAX_TARGETS_PER_SWEEP = 3,
    MAX_HITS_PER_SWEEP = 30,
    MELEE_HIT_MAX_DISTANCE = 10.5,
    TOKEN_SEARCH_RADIUS = 260,
    TOKEN_PROMPT_DISTANCE = 14,
    TOKEN_SETTLE_WAIT = 0.18,
    MAX_TOKEN_PICKUPS_PER_PASS = 40,
    AUTO_FULLBRIGHT = true,
}

local running = false
local paused = false
local scanZ = CONFIG.SCAN_START_Z
local lap = 1
local alienKills = 0
local tokenAttempts = 0
local tokenPickupsConfirmed = 0
local rewardToastEstimate = 0
local remoteErrors = 0
local currentTarget = "None"
local equippedToolName = "None"
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
local originalLighting = {}
local fullbrightApplied = false
local mainLoopThread = nil
local diagEvents = {}
local diagCounts = {}
local diagLastByKey = {}
local diagMaxEvents = 1800
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
        "Version: 1.0.1-HF5.4-SURFACE-CONTACT",
        "GameId: " .. tostring(game.GameId) .. " | PlaceId: " .. tostring(game.PlaceId),
        "Status: " .. tostring(currentStatus) .. " | Running=" .. tostring(running) .. " | Paused=" .. tostring(paused),
        "Current target: " .. tostring(currentTarget) .. " | Equipped tool: " .. tostring(equippedToolName),
        "Lap: " .. tostring(lap) .. " | ScanZ: " .. tostring(scanZ),
        "Alien kill notifications: " .. tostring(alienKills),
        "Alien monitors: " .. tostring(monitoredAlienModelsTotal) .. " | Numeric health sources: " .. tostring(alienHealthSourcesFound),
        "Alien health-source decrease signals: " .. tostring(alienDamageEvents) .. " | Alien death signals: " .. tostring(alienDeathEvents),
        "Health-bar UI changes: " .. tostring(alienHealthUiEvents) .. " | Auto-correlated foreground damage events: " .. tostring(automatedDamageUiEvents) .. " | Native Tool.Activated signals: " .. tostring(nativeToolActivations),
        "Farmer requests: Attack=" .. tostring(automatedAttackRequests) .. " | Hit=" .. tostring(automatedHitRequests),
        "Manual input: MouseDown=" .. tostring(manualMouseDownCount) .. " | MouseUp=" .. tostring(manualMouseUpCount) .. " | Touch=" .. tostring(manualTouchCount) .. " | Tool.Activated=" .. tostring(nativeToolActivations) .. " | Last=" .. tostring(lastManualInputKind),
        "Movement observer: Samples=" .. tostring(movementSamples) .. " | Unexpected displacement candidates=" .. tostring(movementAnomalyCount) .. " | Fall candidates=" .. tostring(fallWarningCount),
        "Camera/root offset is informational only; under-alien safety camera positioning is intentional and is not classified as an error.",
        "Token attempts: " .. tostring(tokenAttempts) .. " | Confirmed pickups: " .. tostring(tokenPickupsConfirmed),
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
                "  %s/%s | InContainer=%s | Sources=%d | UI=%d | DeadSignal=%s | Removed=%s | LastValue=%s | LastDelta=%s | Attribution=%s | AutoUiDelta=%s | AutoUiAttribution=%s | Max=%s | %s",
                npc.variant, npc.modelName, tostring(npc.inEntityContainer), npc.sourceCount, npc.uiSourceCount,
                tostring(npc.deadSignal), tostring(npc.removed), tostring(npc.lastHealthValue),
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
recordEvent("SYSTEM", "Diagnostics initialized", "Executor=" .. executorName .. " | GameId=" .. tostring(game.GameId) .. " | PlaceId=" .. tostring(game.PlaceId))

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

    -- Last Stop gives the player one starting melee tool: the shovel in hotbar slot 1.
    -- Its runtime name may be a GUID, so do not depend on Name/ToolTip keywords.
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

    recordEvent("WEAPON", "Equipping starting shovel", candidate.Name .. " | Source=Backpack first Tool | HotbarSlot=1")
    local ok, equipError = pcall(function()
        humanoid:EquipTool(candidate)
    end)
    if not ok then
        recordEvent("ERROR", "Starting shovel EquipTool failed", diagTraceback(equipError))
        return false
    end

    task.wait(0.12)
    equipped = character:FindFirstChildOfClass("Tool")
    if equipped then
        equippedToolName = equipped.Name
        recordEvent("WEAPON", "Starting shovel equipped", equippedToolName .. " | Slot=1 | ToolEnabled=" .. tostring(equipped.Enabled))
        return true
    end

    recordThrottled("equip-not-confirmed", 2, "WEAPON", "Starting shovel equip not confirmed", candidate.Name)
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

local function isAlienModel(model)
    if not model or not model:IsA("Model") then
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

local function isModelAlive(model)
    if not model or not model.Parent then
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

local function getAliensNear(position, radius)
    local results = {}
    if not ENTITY_CONTAINER or not position then
        return results
    end
    for _, model in ipairs(ENTITY_CONTAINER:GetChildren()) do
        local variant = isAlienModel(model)
        if variant and isModelAlive(model) then
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

    local record = {
        model = model,
        variant = variant,
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

local function getSurfaceHit(part, origin)
    if not part or not part.Parent or not origin then
        return nil
    end

    local offset = part.Position - origin
    if offset.Magnitude < 0.001 then
        return nil
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Include
    params.FilterDescendantsInstances = { part }
    params.IgnoreWater = true

    local castLength = offset.Magnitude + part.Size.Magnitude + 1
    local result = Workspace:Raycast(origin, offset.Unit * castLength, params)
    if not result or result.Instance ~= part then
        return nil
    end

    return {
        part = part,
        position = result.Position,
        normal = result.Normal,
        material = result.Material,
        distance = (result.Position - origin).Magnitude,
    }
end

local function getClosestMeleeContact(model, origin, maxDistance)
    if not model or not origin then
        return nil
    end

    -- The external hub exposed "Closest (Recommended)" body-part targeting.
    -- The observer captured real contacts on Cylinder.008 and arm parts, but
    -- did not establish a fixed preference order. Choose the nearest valid
    -- surface contact rather than forcing one body part for every alien.
    local rigBodyNames = {
        ["head"] = true,
        ["torso"] = true,
        ["uppertorso"] = true,
        ["lowertorso"] = true,
        ["right arm"] = true,
        ["left arm"] = true,
        ["right leg"] = true,
        ["left leg"] = true,
    }
    local blockedNames = {
        ["humanoidrootpart"] = true,
        ["entitydetector"] = true,
        ["handle"] = true,
        ["sword"] = true,
        ["blade"] = true,
        ["hitbox"] = true,
    }

    local bestContact = nil
    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("BasePart") then
            local lowerName = string.lower(descendant.Name)
            local blocked = blockedNames[lowerName] == true
            local ancestor = descendant.Parent
            while ancestor and ancestor ~= model do
                if ancestor:IsA("Accessory") or ancestor:IsA("Tool") then
                    blocked = true
                    break
                end
                local ancestorName = string.lower(ancestor.Name)
                if ancestorName == "sword" or ancestorName == "blade"
                    or ancestorName == "weapon" or ancestorName == "accessories" then
                    blocked = true
                    break
                end
                ancestor = ancestor.Parent
            end

            local fullPath = string.lower(descendant:GetFullName())
            local isRigBody = rigBodyNames[lowerName] == true
            local isAlienDressGeometry = string.find(fullPath, ".dress.alientype", 1, true) ~= nil
            if not blocked and (isRigBody or isAlienDressGeometry) then
                local contact = getSurfaceHit(descendant, origin)
                if contact and (maxDistance == nil or contact.distance <= maxDistance) then
                    if not bestContact or contact.distance < bestContact.distance then
                        bestContact = contact
                    end
                end
            end
        end
    end

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

local function moveCharacter(position, lookAtPosition, moveReason)
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

local function moveBelowAlien(entry)
    if not entry or not entry.root or not entry.root.Parent then
        return false
    end
    local targetPosition = entry.root.Position
    local hoverPosition = targetPosition + Vector3.new(0, -CONFIG.HOVER_BELOW, 0)
    currentTarget = entry.variant .. " / " .. entry.model.Name
    local _, playerRoot = getCharacter()
    local beforeDistance = playerRoot and (playerRoot.Position - targetPosition).Magnitude or -1
    local moved = moveCharacter(hoverPosition, targetPosition, "SAFE_HOVER_BELOW_ALIEN")
    recordEvent("TARGET", "Hover-below positioning requested", string.format("Variant=%s | Model=%s | Target=(%.1f, %.1f, %.1f) | DesiredPlayerY=%.1f | HoverBelow=%.1f | PreviousDistance=%.1f | Success=%s", entry.variant, entry.model.Name, targetPosition.X, targetPosition.Y, targetPosition.Z, hoverPosition.Y, CONFIG.HOVER_BELOW, beforeDistance, tostring(moved)))
    return moved
end

local function restoreMovement()
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

local function sendMeleeSweep(entries)
    local character, root = getCharacter()
    if not character or not root or not ReplicaSignal then
        return 0
    end

    -- Last Stop's only starting weapon is the shovel in hotbar slot 1.
    -- Tool.Enabled is recorded for diagnostics but is not used as an attack gate.
    if not ensureToolEquipped() then
        setStatus("Waiting for starting shovel in hotbar slot 1")
        return 0
    end
    local equippedTool = character:FindFirstChildOfClass("Tool")
    if not equippedTool then
        setStatus("Starting shovel is not equipped")
        return 0
    end

    local candidates = {}
    for _, entry in ipairs(entries) do
        if entry.model and entry.model.Parent and entry.root and entry.root.Parent then
            local contact = getClosestMeleeContact(entry.model, root.Position, CONFIG.MELEE_HIT_MAX_DISTANCE)
            if contact and contact.part and contact.part.Parent then
                contact.entry = entry
                table.insert(candidates, contact)
            else
                recordThrottled(
                    "melee-no-surface-contact:" .. entry.model.Name,
                    1,
                    "COMBAT",
                    "Alien skipped: no raycast surface contact in reach",
                    entry.variant .. "/" .. entry.model.Name .. " | MaxSurfaceDistance=" .. tostring(CONFIG.MELEE_HIT_MAX_DISTANCE)
                )
            end
        end
    end

    table.sort(candidates, function(a, b)
        return a.distance < b.distance
    end)

    local maxTargets = math.min(#candidates, CONFIG.MAX_TARGETS_PER_SWEEP)
    if maxTargets == 0 then
        recordThrottled(
            "melee-no-valid-contact",
            0.75,
            "COMBAT",
            "No valid shovel contact in reach",
            "No valid body-part surface contact within " .. tostring(CONFIG.MELEE_HIT_MAX_DISTANCE) .. " studs"
        )
        return 0
    end

    -- Aim at the first selected body contact. The observer capture shows the
    -- Attack direction leading to the first Hit part, followed by Hit calls.
    local nearestContact = candidates[1]
    local direction = nearestContact.position - root.Position
    if direction.Magnitude < 0.001 then
        direction = root.CFrame.LookVector
    else
        direction = direction.Unit
    end

    lastAutoAttackAt = os.clock()
    automatedAttackRequests = automatedAttackRequests + 1
    local okAttack, attackError = pcall(function()
        ReplicaSignal:FireServer(120, "Melee", "Attack", direction, 1)
    end)
    if not okAttack then
        remoteErrors = remoteErrors + 1
        recordEvent("ERROR", "Melee Attack call failed locally", diagTraceback(attackError))
        return 0
    end

    -- The captured working sequence had approximately 26 ms between Attack
    -- and the first Hit event.
    task.wait(CONFIG.MELEE_HIT_DELAY)
    recordThrottled(
        "melee-attack-dispatched",
        0.25,
        "COMBAT",
        "Melee Attack request dispatched",
        string.format(
            "Nearest=%s/%s | ContactPart=%s | ContactPath=%s | SurfaceDistance=%.2f | SurfacePosition=(%.2f, %.2f, %.2f) | SurfaceNormal=(%.2f, %.2f, %.2f) | Root=(%.2f, %.2f, %.2f) | Direction=(%.3f, %.3f, %.3f) | Tool=%s | ToolEnabled=%s | Server acceptance unknown",
            nearestContact.entry.variant,
            nearestContact.entry.model.Name,
            nearestContact.part.Name,
            nearestContact.part:GetFullName(),
            nearestContact.distance,
            nearestContact.position.X, nearestContact.position.Y, nearestContact.position.Z,
            nearestContact.normal.X, nearestContact.normal.Y, nearestContact.normal.Z,
            root.Position.X, root.Position.Y, root.Position.Z,
            direction.X, direction.Y, direction.Z,
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
        if contact.part and contact.part.Parent and entry.model and entry.model.Parent then
            local targetHitCount = 0
            for hitIndex = 1, CONFIG.MAX_HITS_PER_TARGET do
                if sentHits >= CONFIG.MAX_HITS_PER_SWEEP or not contact.part.Parent then
                    break
                end

                local okHit, hitError = pcall(function()
                    -- Send the raycast's actual contact point, surface normal,
                    -- and material instead of the part center and a guessed normal.
                    ReplicaSignal:FireServer(
                        120,
                        "Melee",
                        "Hit",
                        contact.part,
                        contact.position,
                        contact.normal,
                        contact.material
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
            end

            if targetHitCount > 0 then
                recordThrottled(
                    "melee-hit-summary:" .. entry.model.Name,
                    0.5,
                    "COMBAT",
                    "Melee surface hits dispatched",
                    string.format(
                        "Target=%s/%s | Part=%s | Repeats=%d | SurfacePosition=(%.2f, %.2f, %.2f) | Normal=(%.2f, %.2f, %.2f) | Material=%s | Server damage unverified",
                        entry.variant,
                        entry.model.Name,
                        contact.part.Name,
                        targetHitCount,
                        contact.position.X,
                        contact.position.Y,
                        contact.position.Z,
                        contact.normal.X,
                        contact.normal.Y,
                        contact.normal.Z,
                        tostring(contact.material)
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
        "Surface-hit requests without local error=" .. tostring(sentHits) .. " | Targets=" .. tostring(maxTargets) .. " | Local call errors=" .. tostring(remoteErrors)
    )
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

local function activatePrompt(prompt)
    if not prompt or not prompt.Parent or not prompt.Enabled then
        return false
    end
    local ok, activationError = false, nil
    if type(fireproximityprompt) == "function" then
        ok, activationError = pcall(function()
            fireproximityprompt(prompt)
        end)
    else
        ok, activationError = pcall(function()
            prompt:InputHoldBegin()
            task.wait(math.max(prompt.HoldDuration, 0.05))
            prompt:InputHoldEnd()
        end)
    end
    return ok, activationError
end

local function collectTokensAround(center, radius)
    if not center then
        return 0
    end
    local confirmed = 0
    local collectedThisPass = {}
    local idlePasses = 0

    while running and not paused and idlePasses < 3 and confirmed < CONFIG.MAX_TOKEN_PICKUPS_PER_PASS do
        local prompts = getAlienTokenPrompts(center, radius)
        local foundNew = false

        for _, item in ipairs(prompts) do
            local prompt = item.prompt
            if prompt and prompt.Parent and not collectedThisPass[prompt] then
                foundNew = true
                collectedThisPass[prompt] = true
                local position = getPromptPosition(prompt) or item.position
                if position then
                    local promptPath = "unknown"
                    pcall(function() promptPath = prompt:GetFullName() end)
                    recordEvent("TOKEN", "Alien Token pickup detected", string.format("Path=%s | Position=(%.1f, %.1f, %.1f) | DistanceFromCluster=%.1f | MaxActivationDistance=%.1f", promptPath, position.X, position.Y, position.Z, item.distance, prompt.MaxActivationDistance))
                    local moved = moveCharacter(position + Vector3.new(0, 2, 0), position, "TOKEN_PICKUP")
                    task.wait(0.08)
                    tokenAttempts = tokenAttempts + 1
                    recordEvent("TOKEN", "Pickup attempt started", "Path=" .. promptPath .. " | MoveToPickup=" .. tostring(moved) .. " | Attempt=" .. tostring(tokenAttempts))
                    local triggered, triggerError = activatePrompt(prompt)
                    recordEvent("TOKEN", triggered and "Prompt activation call returned" or "Prompt activation call failed", "Path=" .. promptPath .. " | LocalResult=" .. tostring(triggered) .. (triggerError and " | Error=" .. diagTraceback(triggerError) or ""))
                    task.wait(CONFIG.TOKEN_SETTLE_WAIT)
                    if triggered and (not prompt.Parent or not prompt.Enabled) then
                        tokenPickupsConfirmed = tokenPickupsConfirmed + 1
                        confirmed = confirmed + 1
                        setStatus("Collected Alien Token pickup")
                        recordEvent("TOKEN", "Pickup confirmed by prompt removal/disable", "Path=" .. promptPath .. " | ConfirmedThisPass=" .. tostring(confirmed) .. " | TotalConfirmed=" .. tostring(tokenPickupsConfirmed))
                    elseif triggered then
                        setStatus("Token pickup triggered; waiting for confirmation")
                        recordThrottled("token-unconfirmed:" .. promptPath, 1, "TOKEN", "Pickup not confirmed", "Prompt remained present and enabled after activation")
                    else
                        remoteErrors = remoteErrors + 1
                        recordEvent("ERROR", "Token pickup activation failed", "Path=" .. promptPath .. " | " .. diagTraceback(triggerError))
                    end
                end
            end
        end

        if foundNew then
            idlePasses = 0
        else
            idlePasses = idlePasses + 1
            task.wait(0.25)
        end
    end

    return confirmed
end

local function engageAliens(seedEntries)
    if not seedEntries or #seedEntries == 0 then
        return
    end

    local firstTarget = seedEntries[1]
    if not firstTarget.root or not firstTarget.root.Parent then
        return
    end

    local clusterCenter = firstTarget.root.Position
    local startTime = os.clock()
    local initialKillCount = alienKills
    local startKillCount = initialKillCount
    recordEvent("TARGET", "Alien cluster engagement started", string.format("InitialTarget=%s/%s | Count=%d | Center=(%.1f, %.1f, %.1f)", firstTarget.variant, firstTarget.model.Name, #seedEntries, clusterCenter.X, clusterCenter.Y, clusterCenter.Z))
    local lastProgressTime = os.clock()
    setStatus("Engaging alien cluster")

    while running and not paused and (os.clock() - startTime) < CONFIG.ENGAGE_TIMEOUT do
        local entries = getAliensNear(clusterCenter, CONFIG.ALIEN_ATTACK_RANGE)
        if #entries == 0 then
            break
        end

        local nearest = getNearestEntry(entries)
        if not nearest then
            break
        end

        recordThrottled("target-selection", 0.75, "TARGET", "Alien target selected", "Variant=" .. nearest.variant .. " | Model=" .. nearest.model.Name .. " | ClusterTargets=" .. tostring(#entries))
        moveBelowAlien(nearest)
        local hits = sendMeleeSweep(entries)
        if hits > 0 then
            setStatus("Attacking " .. tostring(#entries) .. " alien(s) / " .. tostring(hits) .. " surface hits")
        else
            setStatus("Alien target found; no hit parts available")
        end

        if alienKills > startKillCount then
            lastProgressTime = os.clock()
            startKillCount = alienKills
        end

        -- Health bars are custom UI in this game. Count a foreground Bar
        -- decrease as progress only when it follows this farmer's Hit request
        -- and is not temporally mixed with manual input.
        local latestAutoUiDamage = nil
        for _, entry in ipairs(entries) do
            local healthRecord = monitoredAliens[entry.model]
            if healthRecord and healthRecord.lastAutoUiDamageAt
                and healthRecord.lastAutoUiDamageAt > lastProgressTime then
                if not latestAutoUiDamage or healthRecord.lastAutoUiDamageAt > latestAutoUiDamage.at then
                    latestAutoUiDamage = {
                        at = healthRecord.lastAutoUiDamageAt,
                        model = entry.model,
                        variant = entry.variant,
                        delta = healthRecord.lastAutoUiDamageDelta,
                    }
                end
            end
        end
        if latestAutoUiDamage then
            lastProgressTime = latestAutoUiDamage.at
            recordThrottled(
                "auto-ui-progress:" .. latestAutoUiDamage.model.Name,
                0.5,
                "COMBAT",
                "Automated health-bar progress observed",
                string.format("Target=%s/%s | ForegroundWidthDrop=%.5f | ProgressTimerReset=true | Timing correlation, not server-side health proof",
                    latestAutoUiDamage.variant, latestAutoUiDamage.model.Name, tonumber(latestAutoUiDamage.delta) or 0)
            )
        end

        if (os.clock() - lastProgressTime) > CONFIG.NO_KILL_TIMEOUT then
            setStatus("No new alien kill confirmation; ending this engagement")
            break
        end

        task.wait(math.max(0, CONFIG.ATTACK_INTERVAL - CONFIG.MELEE_HIT_DELAY))
    end

    setStatus("Collecting drops from cleared alien area")
    recordEvent("TARGET", "Alien engagement ended", "Elapsed=" .. string.format("%.2f", os.clock() - startTime) .. "s | KillNotificationDelta=" .. tostring(alienKills - initialKillCount) .. " | CurrentKillNotifications=" .. tostring(alienKills))
    local collected = collectTokensAround(clusterCenter, CONFIG.TOKEN_SEARCH_RADIUS)
    recordEvent("TOKEN", "Cluster collection pass finished", "ConfirmedThisPass=" .. tostring(collected) .. " | TotalConfirmed=" .. tostring(tokenPickupsConfirmed))
    local remaining = getAliensNear(clusterCenter, CONFIG.ALIEN_ATTACK_RANGE)
    local clusterCleared = (#remaining == 0)
    recordEvent("TARGET", "Cluster clearance check", "RemainingAliens=" .. tostring(#remaining) .. " | Cleared=" .. tostring(clusterCleared))
    currentTarget = "None"
    return clusterCleared
end

local function getCurrentScanPosition()
    return Vector3.new(CONFIG.SCAN_X, CONFIG.SCAN_Y, scanZ)
end

local function advanceScan()
    local oldZ = scanZ
    local oldLap = lap
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
    setStatus("Automatic farming started")
    recordEvent("SCAN", "Initial scan route ready", string.format("Start=(%.1f, %.1f, %.1f) | Step=%d | DetectionRadius=%.1f | Wait=%.2fs", CONFIG.SCAN_X, CONFIG.SCAN_Y, scanZ, CONFIG.SCAN_STEP, CONFIG.SCAN_DETECT_RADIUS, CONFIG.SCAN_WAIT))

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
                -- Do not teleport back to the scan waypoint while living
                -- aliens remain. Resume the same cluster from the current
                -- safe-hover position and only advance after it is cleared.
                local pendingAliens = getAliensNear(pendingClusterCenter, CONFIG.SCAN_DETECT_RADIUS)
                if #pendingAliens == 0 then
                    recordEvent("TARGET", "Pending alien cluster cleared", "No AlienType1/2/3 models remain within the active scan radius")
                    pendingClusterCenter = nil
                    advanceScan()
                else
                    recordEvent("TARGET", "Retrying active alien cluster in place", "RemainingInScanRadius=" .. tostring(#pendingAliens) .. " | Scan-point teleport suppressed")
                    local passCleared = engageAliens(pendingAliens)
                    local stillPending = getAliensNear(pendingClusterCenter, CONFIG.SCAN_DETECT_RADIUS)
                    if passCleared and #stillPending == 0 then
                        pendingClusterCenter = nil
                        advanceScan()
                    else
                        setStatus("Aliens remain; continuing current cluster without scan-point teleport")
                        task.wait(0.5)
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
                    recordEvent("SCAN", "Alien cluster detected", string.format("Total=%d | AlienType1=%d | AlienType2=%d | AlienType3=%d | ScanPosition=(%.1f, %.1f, %.1f)", #aliens, variantCounts.AlienType1, variantCounts.AlienType2, variantCounts.AlienType3, scanPosition.X, scanPosition.Y, scanPosition.Z))
                    setStatus("Detected " .. tostring(#aliens) .. " alien(s)")
                    local passCleared = engageAliens(aliens)
                    local stillPending = getAliensNear(pendingClusterCenter, CONFIG.SCAN_DETECT_RADIUS)
                    if passCleared and #stillPending == 0 then
                        pendingClusterCenter = nil
                        advanceScan()
                    else
                        setStatus("Aliens remain; continuing current cluster without scan-point teleport")
                        task.wait(0.5)
                    end
                else
                    recordEvent("SCAN", "No alien target at scan point", "Lap=" .. tostring(lap) .. " | Z=" .. tostring(scanZ) .. " | DetectionRadius=" .. tostring(CONFIG.SCAN_DETECT_RADIUS))
                    local looseTokens = getAlienTokenPrompts(scanPosition, 80)
                    if #looseTokens > 0 then
                        recordEvent("TOKEN", "Loose Alien Tokens found during scan", "Count=" .. tostring(#looseTokens) .. " | ScanZ=" .. tostring(scanZ))
                        setStatus("Loose Alien Tokens detected")
                        local collected = collectTokensAround(scanPosition, 100)
                        recordEvent("TOKEN", "Loose-token collection pass finished", "ConfirmedThisPass=" .. tostring(collected))
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
    recordEvent("PLAYER", "Character monitor attached", "Health=" .. tostring(humanoid.Health) .. "/" .. tostring(humanoid.MaxHealth))
    local previousHealth = humanoid.Health
    humanoid.HealthChanged:Connect(function(newHealth)
        if newHealth < previousHealth then
            recordEvent("PLAYER", "Player health decreased", string.format("Health=%.1f->%.1f", previousHealth, newHealth))
        elseif newHealth > previousHealth then
            recordThrottled("health-heal", 0.5, "PLAYER", "Player health increased", string.format("Health=%.1f->%.1f", previousHealth, newHealth))
        end
        previousHealth = newHealth
    end)
    humanoid.Died:Connect(function()
        recordEvent("PLAYER", "Player humanoid died", "Health=" .. tostring(humanoid.Health))
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
            recordEvent("WEAPON", "Tool Equipped event observed", "Tool=" .. tostring(tool.Name)
                .. " | Parent=" .. tostring(tool.Parent and tool.Parent.Name))
        end)
    end)
    if equippedOk and equippedConnection then table.insert(monitoredTools[tool].connections, equippedConnection) end
    local unequippedOk, unequippedConnection = pcall(function()
        return tool.Unequipped:Connect(function()
            recordEvent("WEAPON", "Tool Unequipped event observed", "Tool=" .. tostring(tool.Name))
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
statsLabel.Size = UDim2.new(1, -16, 0, 100)
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
            version = "1.0.1-HF5.4-SURFACE-CONTACT",
            gameId = game.GameId,
            placeId = game.PlaceId,
            status = currentStatus,
            alienKills = alienKills,
            monitoredAlienModels = monitoredAlienModelsTotal,
            alienHealthSourcesFound = alienHealthSourcesFound,
            alienDamageEvents = alienDamageEvents,
            alienDeathEvents = alienDeathEvents,
            alienHealthUiEvents = alienHealthUiEvents,
            automatedDamageUiEvents = automatedDamageUiEvents,
            nativeToolActivations = nativeToolActivations,
            automatedAttackRequests = automatedAttackRequests,
            automatedHitRequests = automatedHitRequests,
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
            .. "\nToken pickups confirmed: " .. tostring(tokenPickupsConfirmed)
            .. " / attempts: " .. tostring(tokenAttempts)
            .. "\nReward toast estimate: " .. tostring(rewardToastEstimate)
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

local function stopFarm()
    recordEvent("SYSTEM", "Stop requested by user", "Emergency stop button activated")
    running = false
    paused = false
    restoreMovement()
    restoreFullbright()
    setStatus("Stopped by user")
    refreshGui()
end

stopButton.Activated:Connect(stopFarm)

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
    running = true
    paused = false
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

recordEvent("SYSTEM", "Script initialization complete", "Automatic start scheduled | Target filter=AlienType1/2/3 only | Diagnostics=HF5.4 safe-hover/surface-contact/health/input/movement monitoring | Hooks=none")
refreshDiagPanel()
log("Loaded. Automatic start scheduled. Target filter: AlienType1/2/3 only. Integrated diagnostics enabled.")
