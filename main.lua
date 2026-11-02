--[[
LAST STOP - ALIEN TOKEN FARMER V1.0
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
    ALIEN_ATTACK_RANGE = 120,
    HOVER_BELOW = 10,
    ATTACK_INTERVAL = 0.22,
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

local function log(message)
    pcall(function()
        warn("[LSAF] " .. tostring(message))
    end)
end

local function setStatus(message)
    currentStatus = tostring(message)
end

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

    local equipped = character:FindFirstChildOfClass("Tool")
    if equipped then
        equippedToolName = equipped.Name
        return true
    end

    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack") or LocalPlayer:FindFirstChild("Backpack")
    if not backpack then
        return false
    end

    local candidate = nil
    for _, child in ipairs(backpack:GetChildren()) do
        if child:IsA("Tool") then
            local descriptor = string.lower(child.Name .. " " .. tostring(child.ToolTip or ""))
            if string.find(descriptor, "shovel", 1, true) or string.find(descriptor, "melee", 1, true) then
                candidate = child
                break
            end
            if not candidate then
                candidate = child
            end
        end
    end

    if not candidate then
        return false
    end

    local ok = pcall(function()
        humanoid:EquipTool(candidate)
    end)
    if not ok then
        return false
    end

    task.wait(0.12)
    equipped = character:FindFirstChildOfClass("Tool")
    if equipped then
        equippedToolName = equipped.Name
        return true
    end
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

local function getHitParts(model)
    local parts = {}
    local seen = {}
    local preferredNames = {
        "Head", "Torso", "UpperTorso", "LowerTorso",
        "Right Arm", "Left Arm", "Right Leg", "Left Leg",
    }

    for _, wantedName in ipairs(preferredNames) do
        for _, descendant in ipairs(model:GetDescendants()) do
            if descendant:IsA("BasePart") and descendant.Name == wantedName and not seen[descendant] then
                if descendant.Name ~= "HumanoidRootPart" then
                    seen[descendant] = true
                    table.insert(parts, descendant)
                end
            end
        end
    end

    for _, descendant in ipairs(model:GetDescendants()) do
        if #parts >= CONFIG.MAX_HITS_PER_TARGET then
            break
        end
        if descendant:IsA("BasePart") and descendant.Name ~= "HumanoidRootPart" and not seen[descendant] then
            local parentName = descendant.Parent and string.lower(descendant.Parent.Name) or ""
            local pathText = string.lower(descendant:GetFullName())
            if string.find(pathText, "alientype", 1, true) or parentName == "torso" then
                seen[descendant] = true
                table.insert(parts, descendant)
            end
        end
    end

    return parts
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
    pcall(function()
        root.CFrame = CFrame.lookAt(position, lookAt)
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        if flyVelocity then
            flyVelocity.Velocity = Vector3.zero
        end
        if flyGyro then
            flyGyro.CFrame = CFrame.lookAt(position, lookAt)
        end
    end)
    return true
end

local function moveBelowAlien(entry)
    if not entry or not entry.root or not entry.root.Parent then
        return false
    end
    local targetPosition = entry.root.Position
    local hoverPosition = targetPosition + Vector3.new(0, -CONFIG.HOVER_BELOW, 0)
    currentTarget = entry.variant .. " / " .. entry.model.Name
    return moveCharacter(hoverPosition, targetPosition)
end

local function restoreMovement()
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
    local _, root = getCharacter()
    if not root or not ReplicaSignal then
        return 0
    end
    if not ensureToolEquipped() then
        setStatus("Waiting for a melee-capable tool")
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

    local sentHits = 0
    local okAttack = pcall(function()
        ReplicaSignal:FireServer(120, "Melee", "Attack", direction, 1)
    end)
    if not okAttack then
        remoteErrors = remoteErrors + 1
    end

    for _, entry in ipairs(entries) do
        if sentHits >= CONFIG.MAX_HITS_PER_SWEEP then
            break
        end
        if entry.model and entry.model.Parent and entry.root and entry.root.Parent then
            local distance = (entry.root.Position - root.Position).Magnitude
            if distance <= CONFIG.ALIEN_ATTACK_RANGE then
                local parts = getHitParts(entry.model)
                for _, part in ipairs(parts) do
                    if sentHits >= CONFIG.MAX_HITS_PER_SWEEP then
                        break
                    end
                    if part and part.Parent then
                        local okHit = pcall(function()
                            ReplicaSignal:FireServer(
                                120,
                                "Melee",
                                "Hit",
                                part,
                                part.Position,
                                Vector3.new(0, 1, 0),
                                part.Material
                            )
                        end)
                        if okHit then
                            sentHits = sentHits + 1
                        else
                            remoteErrors = remoteErrors + 1
                        end
                    end
                end
            end
        end
    end
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
    local ok = false
    if type(fireproximityprompt) == "function" then
        ok = pcall(function()
            fireproximityprompt(prompt)
        end)
    else
        ok = pcall(function()
            prompt:InputHoldBegin()
            task.wait(math.max(prompt.HoldDuration, 0.05))
            prompt:InputHoldEnd()
        end)
    end
    return ok
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
                    moveCharacter(position + Vector3.new(0, 2, 0), position)
                    task.wait(0.08)
                    tokenAttempts = tokenAttempts + 1
                    local triggered = activatePrompt(prompt)
                    task.wait(CONFIG.TOKEN_SETTLE_WAIT)
                    if triggered and (not prompt.Parent or not prompt.Enabled) then
                        tokenPickupsConfirmed = tokenPickupsConfirmed + 1
                        confirmed = confirmed + 1
                        setStatus("Collected Alien Token pickup")
                    elseif triggered then
                        setStatus("Token pickup triggered; waiting for confirmation")
                    else
                        remoteErrors = remoteErrors + 1
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
    local startKillCount = alienKills
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
    collectTokensAround(clusterCenter, CONFIG.TOKEN_SEARCH_RADIUS)
    currentTarget = "None"
end

local function getCurrentScanPosition()
    return Vector3.new(CONFIG.SCAN_X, CONFIG.SCAN_Y, scanZ)
end

local function advanceScan()
    scanZ = scanZ - CONFIG.SCAN_STEP
    if scanZ < CONFIG.SCAN_MIN_Z then
        lap = lap + 1
        scanZ = CONFIG.SCAN_START_Z
    end
    local position = getCurrentScanPosition()
    moveCharacter(position, position + Vector3.new(0, 0, -1))
    setStatus("Scanning lap " .. tostring(lap) .. " / Z=" .. tostring(scanZ))
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
                setStatus("Detected " .. tostring(#aliens) .. " alien(s)")
                engageAliens(aliens)
            else
                local looseTokens = getAlienTokenPrompts(scanPosition, 80)
                if #looseTokens > 0 then
                    setStatus("Loose Alien Tokens detected")
                    collectTokensAround(scanPosition, 100)
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
        local lowerText = string.lower(textValue)
        local oldText = lastLabelText[label]

        if string.find(lowerText, "killed:%s*alien") then
            if not oldText or not string.find(string.lower(oldText), "killed:%s*alien") then
                alienKills = alienKills + 1
                lastAlienKillAt = os.clock()
            end
        end

        if string.find(lowerText, "alien token", 1, true) then
            local amount = tonumber(string.match(textValue, "%+%s*(%d+)"))
            local frame = label.Parent
            if amount and frame and not rewardFramesSeen[frame] then
                rewardToastEstimate = rewardToastEstimate + amount
                rewardFramesSeen[frame] = true
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
frame.Size = UDim2.new(0, 285, 0, 190)
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
statusLabel.Size = UDim2.new(1, -16, 0, 32)
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
statsLabel.Size = UDim2.new(1, -16, 0, 64)
statsLabel.Position = UDim2.new(0, 8, 0, 72)
statsLabel.BackgroundTransparency = 1
statsLabel.Text = "Aliens killed: 0\nToken pickups confirmed: 0\nReward toast estimate: 0"
statsLabel.TextColor3 = Color3.fromRGB(190, 200, 210)
statsLabel.Font = Enum.Font.Code
statsLabel.TextSize = 11
statsLabel.TextXAlignment = Enum.TextXAlignment.Left
statsLabel.TextYAlignment = Enum.TextYAlignment.Top
statsLabel.Parent = frame

local pauseButton = Instance.new("TextButton")
pauseButton.Size = UDim2.new(0.48, -6, 0, 30)
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
stopButton.Size = UDim2.new(0.48, -6, 0, 30)
stopButton.Position = UDim2.new(0.52, -2, 1, -38)
stopButton.BackgroundColor3 = Color3.fromRGB(130, 55, 55)
stopButton.TextColor3 = Color3.new(1, 1, 1)
stopButton.Font = Enum.Font.GothamBold
stopButton.TextSize = 11
stopButton.Text = "STOP"
stopButton.Parent = frame
local stopCorner = Instance.new("UICorner")
stopCorner.CornerRadius = UDim.new(0, 6)
stopCorner.Parent = stopButton

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
            .. "\nRemote errors: " .. tostring(remoteErrors)
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
    refreshGui()
end)

local function stopFarm()
    running = false
    paused = false
    restoreMovement()
    restoreFullbright()
    setStatus("Stopped by user")
    refreshGui()
end

stopButton.Activated:Connect(stopFarm)

LocalPlayer.CharacterAdded:Connect(function()
    task.wait(1)
    if running then
        setupFlight()
    end
end)

hookPlayerGui()

-- Keep the compact HUD current without scanning the world every frame.
task.spawn(function()
    while screenGui.Parent do
        refreshGui()
        task.wait(0.25)
    end
end)

local function startFarm()
    if running then
        return
    end
    running = true
    paused = false
    applyFullbright()
    setupFlight()
    if mainLoopThread then
        mainLoopThread = nil
    end
    mainLoopThread = task.spawn(mainLoop)
    refreshGui()
end

-- Automatic start: execute one script and the farm begins by itself.
task.delay(2, function()
    if screenGui.Parent and not running then
        startFarm()
    end
end)

log("Loaded. Automatic start scheduled. Target filter: AlienType1/2/3 only.")
