--[[
LAST STOP - ALIEN TOKEN FARMER V1.0.1-HF1 (COMBAT HOTFIX; BASELINE PRESERVED)
Standalone experimental build for the Last Stop Roblox experience.

Observed game structures used:
  Workspace.ENTITY_CONTAINER.<GUID>.Dress.AlienType1/2/3
  Workspace.ITEM_CONTAINER.<GUID>.Main.CollectAlienTokenPrompt
  ReplicatedStorage.ClientSource.ReplicaRemoteEvents.Replica_ReplicaSignal

Observed melee signal shape from the supplied V1.2 diagnostics:
  FireServer(120, "Melee", "Attack", direction, 1)
  FireServer(120, "Melee", "Hit", part, hitPosition, normal, material)

No external loaders, no global metamethod hooks, no input hooks.
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
    ENGAGE_TIMEOUT = 18,
    NO_KILL_TIMEOUT = 6,
    MAX_HITS_PER_TARGET = 10,
    MAX_HITS_PER_SWEEP = 36,
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

local function buildDiagnosticReport()
    local lines = {
        "LAST STOP ALIEN FARMER - DIAGNOSTICS",
        "Version: 1.0.1-HF1",
        "GameId: " .. tostring(game.GameId) .. " | PlaceId: " .. tostring(game.PlaceId),
        "Status: " .. tostring(currentStatus) .. " | Running=" .. tostring(running) .. " | Paused=" .. tostring(paused),
        "Current target: " .. tostring(currentTarget) .. " | Equipped tool: " .. tostring(equippedToolName),
        "Lap: " .. tostring(lap) .. " | ScanZ: " .. tostring(scanZ),
        "Alien kill notifications: " .. tostring(alienKills),
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

local function getClosestHitPart(model, origin)
    if not model or not origin then
        return nil, nil
    end

    -- Match the working Auto Kill's "Closest" body-part selection.
    -- Valid targets are the rig's standard body parts or geometry under Dress/AlienTypeX.
    local rigBodyNames = {
        ["Head"] = true,
        ["Torso"] = true,
        ["UpperTorso"] = true,
        ["LowerTorso"] = true,
        ["Right Arm"] = true,
        ["Left Arm"] = true,
        ["Right Leg"] = true,
        ["Left Leg"] = true,
    }
    local blockedNames = {
        ["humanoidrootpart"] = true,
        ["entitydetector"] = true,
        ["handle"] = true,
        ["sword"] = true,
        ["blade"] = true,
        ["hitbox"] = true,
    }

    local bestPart = nil
    local bestDistance = math.huge
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
                if ancestorName == "sword" or ancestorName == "blade" or ancestorName == "weapon" or ancestorName == "accessories" then
                    blocked = true
                    break
                end
                ancestor = ancestor.Parent
            end

            local fullPath = string.lower(descendant:GetFullName())
            local isRigBody = rigBodyNames[descendant.Name] == true
            local isAlienDressGeometry = string.find(fullPath, ".dress.alientype", 1, true) ~= nil
            if not blocked and (isRigBody or isAlienDressGeometry) then
                local distance = (descendant.Position - origin).Magnitude
                if distance < bestDistance then
                    bestPart = descendant
                    bestDistance = distance
                end
            end
        end
    end

    return bestPart, bestDistance
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

local function moveCharacter(position, lookAtPosition)
    if not setupFlight() then
        return false
    end
    local root = activeRoot
    if not root or not root.Parent then
        return false
    end
    local lookAt = lookAtPosition or (position + Vector3.new(0, 0, -1))
    local targetCFrame = CFrame.lookAt(position, lookAt)
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
    recordThrottled("movement-sample", 0.65, "MOVEMENT", "Character repositioned", string.format("Requested=(%.1f, %.1f, %.1f) | Actual=(%.1f, %.1f, %.1f) | CameraRootGap=%s | PlatformStand=%s", position.X, position.Y, position.Z, root.Position.X, root.Position.Y, root.Position.Z, cameraGap, tostring(activeHumanoid and activeHumanoid.PlatformStand)))
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
    local moved = moveCharacter(hoverPosition, targetPosition)
    recordEvent("TARGET", "Hover-below positioning requested", string.format("Variant=%s | Model=%s | Target=(%.1f, %.1f, %.1f) | DesiredPlayerY=%.1f | PreviousDistance=%.1f | Success=%s", entry.variant, entry.model.Name, targetPosition.X, targetPosition.Y, targetPosition.Z, hoverPosition.Y, beforeDistance, tostring(moved)))
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

    -- Equip the one starting weapon (the shovel in hotbar slot 1). Do not gate
    -- on Tool.Enabled: Last Stop toggles that flag during its own cooldown.
    if not ensureToolEquipped() then
        setStatus("Waiting for starting shovel in hotbar slot 1")
        return 0
    end
    local equippedTool = character:FindFirstChildOfClass("Tool")
    if not equippedTool then
        setStatus("Starting shovel is not equipped")
        return 0
    end

    local nearest = getNearestEntry(entries)
    if not nearest or not nearest.root then
        return 0
    end

    local direction = nearest.root.Position - root.Position
    if direction.Magnitude < 0.001 then
        direction = root.CFrame.LookVector
    else
        direction = direction.Unit
    end

    local okAttack, attackError = pcall(function()
        ReplicaSignal:FireServer(120, "Melee", "Attack", direction, 1)
    end)
    if not okAttack then
        remoteErrors = remoteErrors + 1
        recordEvent("ERROR", "Melee Attack call failed locally", diagTraceback(attackError))
        return 0
    end
    recordThrottled("melee-attack-dispatched", 0.05, "COMBAT", "Melee Attack request dispatched", string.format(
        "Target=%s/%s | Tool=%s | ToolEnabled=%s | Interval=%.2fs | Server acceptance unknown",
        nearest.variant, nearest.model.Name, equippedTool.Name, tostring(equippedTool.Enabled), CONFIG.ATTACK_INTERVAL
    ))

    local sentHits = 0
    for _, entry in ipairs(entries) do
        if sentHits >= CONFIG.MAX_HITS_PER_SWEEP then
            break
        end
        if entry.model and entry.model.Parent and entry.root and entry.root.Parent then
            local targetDistance = (entry.root.Position - root.Position).Magnitude
            if targetDistance <= CONFIG.ALIEN_ATTACK_RANGE then
                local hitPart, partDistance = getClosestHitPart(entry.model, root.Position)
                if hitPart and hitPart.Parent then
                    local targetHitCount = 0
                    for hitIndex = 1, CONFIG.MAX_HITS_PER_TARGET do
                        if sentHits >= CONFIG.MAX_HITS_PER_SWEEP then
                            break
                        end
                        if not hitPart.Parent then
                            break
                        end
                        local okHit, hitError = pcall(function()
                            ReplicaSignal:FireServer(
                                120,
                                "Melee",
                                "Hit",
                                hitPart,
                                hitPart.Position,
                                Vector3.new(0, 1, 0),
                                hitPart.Material
                            )
                        end)
                        if okHit then
                            sentHits = sentHits + 1
                            targetHitCount = targetHitCount + 1
                        else
                            remoteErrors = remoteErrors + 1
                            recordEvent("ERROR", "Melee Hit call failed locally", diagTraceback(hitError))
                        end
                    end
                    if targetHitCount > 0 then
                        recordEvent("COMBAT", "Melee closest-part hits dispatched", string.format(
                            "Target=%s/%s | Part=%s | Repeats=%d | PartDistance=%.1f | TargetDistance=%.1f | Local dispatch only; server damage unverified",
                            entry.variant, entry.model.Name, hitPart.Name, targetHitCount,
                            tonumber(partDistance) or -1, targetDistance
                        ))
                    end
                else
                    recordThrottled("no-hit-part:" .. entry.model.Name, 1, "COMBAT", "No valid alien body part found", entry.variant .. "/" .. entry.model.Name)
                end
            end
        end
    end

    recordEvent("COMBAT", "Attack sweep finished", "Closest-part hit requests without local error=" .. tostring(sentHits) .. " | Local call errors=" .. tostring(remoteErrors))
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
                    local moved = moveCharacter(position + Vector3.new(0, 2, 0), position)
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
            setStatus("Attacking " .. tostring(#entries) .. " alien(s) / " .. tostring(hits) .. " hit parts")
        else
            setStatus("Alien target found; no hit parts available")
        end

        if alienKills > startKillCount then
            lastProgressTime = os.clock()
            startKillCount = alienKills
        end

        if (os.clock() - lastProgressTime) > CONFIG.NO_KILL_TIMEOUT then
            setStatus("No new alien kill confirmation; ending this engagement")
            break
        end

        task.wait(CONFIG.ATTACK_INTERVAL)
    end

    setStatus("Collecting drops from cleared alien area")
    recordEvent("TARGET", "Alien engagement ended", "Elapsed=" .. string.format("%.2f", os.clock() - startTime) .. "s | KillNotificationDelta=" .. tostring(alienKills - initialKillCount) .. " | CurrentKillNotifications=" .. tostring(alienKills))
    local collected = collectTokensAround(clusterCenter, CONFIG.TOKEN_SEARCH_RADIUS)
    recordEvent("TOKEN", "Cluster collection pass finished", "ConfirmedThisPass=" .. tostring(collected) .. " | TotalConfirmed=" .. tostring(tokenPickupsConfirmed))
    currentTarget = "None"
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
    local moved = moveCharacter(position, position + Vector3.new(0, 0, -1))
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
            local scanPosition = getCurrentScanPosition()
            moveCharacter(scanPosition, scanPosition + Vector3.new(0, 0, -1))
            task.wait(0.25)

            local aliens = getAliensNear(scanPosition, CONFIG.SCAN_DETECT_RADIUS)
            if #aliens > 0 then
                local variantCounts = {AlienType1 = 0, AlienType2 = 0, AlienType3 = 0}
                for _, entry in ipairs(aliens) do
                    variantCounts[entry.variant] = (variantCounts[entry.variant] or 0) + 1
                end
                recordEvent("SCAN", "Alien cluster detected", string.format("Total=%d | AlienType1=%d | AlienType2=%d | AlienType3=%d | ScanPosition=(%.1f, %.1f, %.1f)", #aliens, variantCounts.AlienType1, variantCounts.AlienType2, variantCounts.AlienType3, scanPosition.X, scanPosition.Y, scanPosition.Z))
                setStatus("Detected " .. tostring(#aliens) .. " alien(s)")
                engageAliens(aliens)
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
            version = "1.0.1-HF1",
            gameId = game.GameId,
            placeId = game.PlaceId,
            status = currentStatus,
            alienKills = alienKills,
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
    recordEvent("PLAYER", "Character respawned", "Character=" .. tostring(character.Name))
    if running then
        setupFlight()
    end
end)
if LocalPlayer.Character then
    task.spawn(monitorCharacter, LocalPlayer.Character)
end

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
                recordThrottled("camera-root-gap", 0.75, "CAMERA", "Large camera/root separation observed", string.format("Gap=%.1f studs | Root=(%.1f, %.1f, %.1f) | Camera=(%.1f, %.1f, %.1f)", gap, root.Position.X, root.Position.Y, root.Position.Z, camera.CFrame.Position.X, camera.CFrame.Position.Y, camera.CFrame.Position.Z))
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

recordEvent("SYSTEM", "Script initialization complete", "Automatic start scheduled | Target filter=AlienType1/2/3 only | Diagnostics=integrated | Hooks=none")
refreshDiagPanel()
log("Loaded. Automatic start scheduled. Target filter: AlienType1/2/3 only. Integrated diagnostics enabled.")
