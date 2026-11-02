--[=[
LAST STOP OBSERVER V1.0
Target: Project Real (capability-gated)
Purpose: Passive client-side diagnostics for Last Stop.

SAFETY / SCOPE
- Does NOT attack, move, teleport, collect, fire remotes, or change game state.
- Observes client-visible entities, health changes, tools, prompts, loot-like objects,
  selected UI counters, movement/property changes, and RemoteEvent/RemoteFunction calls.
- Remote and __newindex hooks are pass-through only. If a hook cannot be installed,
  the rest of the observer continues without it.
- It cannot see server-only logic or every internal operation of another script.
]=]

local ENV = (type(getgenv) == "function" and getgenv()) or _G
if type(ENV.__LAST_STOP_OBSERVER_V1) == "table" then
    local old = ENV.__LAST_STOP_OBSERVER_V1
    if type(old.Unload) == "function" then
        pcall(old.Unload)
    end
end

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local Lighting = game:GetService("Lighting")
local LogService = game:GetService("LogService")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local State = {
    Alive = true,
    Recording = true,
    HookBusy = false,
    Events = {},
    Connections = {},
    Entities = {},
    SeenTools = {},
    SeenControllers = {},
    SeenVisuals = {},
    SeenPrompts = {},
    SeenObjects = {},
    SeenValues = {},
    SeenTexts = {},
    RemoteDedupe = {},
    PropertyDedupe = {},
    UI = {},
    Rows = {},
    Counters = {
        NPCs = 0,
        Remotes = 0,
        RemoteCalls = 0,
        Loot = 0,
        TokenChanges = 0,
        Kills = 0,
        ToolActivations = 0,
        PropertyWrites = 0,
        Errors = 0,
    },
    LastMovement = nil,
    BelowTargetSince = nil,
    BelowTargetName = nil,
    Hooks = {
        Namecall = false,
        NewIndex = false,
        Functions = 0,
    },
}
ENV.__LAST_STOP_OBSERVER_V1 = State

local MAX_EVENTS = 5000
local UI_ROW_COUNT = 13
local REMOTE_DEDUPE_WINDOW = 0.10
local MOVEMENT_SAMPLE_INTERVAL = 0.20

local function safeString(value)
    local ok, result = pcall(function()
        return tostring(value)
    end)
    if ok then
        return result
    end
    return "<unprintable>"
end

local function safeFullName(instance)
    local ok, result = pcall(function()
        return instance:GetFullName()
    end)
    if ok then
        return result
    end
    return safeString(instance)
end

local function isInstance(value)
    local ok, result = pcall(function()
        return typeof(value) == "Instance"
    end)
    return ok and result
end

local function lower(value)
    return string.lower(safeString(value or ""))
end

local function containsAny(value, words)
    local text = lower(value)
    for _, word in ipairs(words) do
        if string.find(text, word, 1, true) then
            return true
        end
    end
    return false
end

local function classifyName(name)
    local text = lower(name)
    if containsAny(text, {"alien", "ufo", "extraterrestrial", "martian", "invader"}) then
        return "ALIEN"
    elseif containsAny(text, {"zombie", "undead", "infected", "ghoul", "walker"}) then
        return "ZOMBIE"
    elseif containsAny(text, {"boss", "mutant", "brute", "monster"}) then
        return "SPECIAL NPC"
    end
    return "NPC"
end

local function serializeValue(value, depth)
    depth = depth or 0
    local valueType = "unknown"
    pcall(function()
        valueType = typeof(value)
    end)

    if valueType == "Instance" then
        local className = "Instance"
        local name = "?"
        pcall(function()
            className = value.ClassName
            name = value.Name
        end)
        return "<" .. className .. ":" .. name .. " @ " .. safeFullName(value) .. ">"
    elseif valueType == "Vector3" then
        return string.format("Vector3(%.2f, %.2f, %.2f)", value.X, value.Y, value.Z)
    elseif valueType == "Vector2" then
        return string.format("Vector2(%.2f, %.2f)", value.X, value.Y)
    elseif valueType == "CFrame" then
        local position = value.Position
        return string.format("CFrame(%.2f, %.2f, %.2f)", position.X, position.Y, position.Z)
    elseif valueType == "EnumItem" then
        return safeString(value)
    elseif type(value) == "string" then
        if #value > 140 then
            return string.sub(value, 1, 140) .. "...<truncated>"
        end
        return string.format("%q", value)
    elseif type(value) == "table" then
        if depth >= 2 then
            return "<table>"
        end
        local parts = {}
        local count = 0
        for key, item in pairs(value) do
            count = count + 1
            if count > 8 then
                table.insert(parts, "...")
                break
            end
            table.insert(parts, "[" .. serializeValue(key, depth + 1) .. "]=" .. serializeValue(item, depth + 1))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end

    return safeString(value)
end

local function push(category, message, details)
    if not State.Alive or not State.Recording then
        return nil
    end

    local timestamp = os.date("%H:%M:%S")
    local event = {
        time = timestamp,
        clock = os.clock(),
        category = safeString(category),
        message = safeString(message),
        details = safeString(details or ""),
    }

    table.insert(State.Events, event)
    if #State.Events > MAX_EVENTS then
        table.remove(State.Events, 1)
    end

    if category == "REMOTE" then
        State.Counters.Remotes = State.Counters.Remotes + 1
    elseif category == "LOOT" then
        State.Counters.Loot = State.Counters.Loot + 1
    elseif category == "TOKEN" then
        State.Counters.TokenChanges = State.Counters.TokenChanges + 1
    elseif category == "KILL" then
        State.Counters.Kills = State.Counters.Kills + 1
    elseif category == "WEAPON" and string.find(safeString(message), "Tool Activated", 1, true) then
        State.Counters.ToolActivations = State.Counters.ToolActivations + 1
    elseif category == "PROPERTY" then
        State.Counters.PropertyWrites = State.Counters.PropertyWrites + 1
    elseif category == "ERROR" then
        State.Counters.Errors = State.Counters.Errors + 1
    end

    State.LastEvent = event
    return event
end

local function keepConnection(connection)
    if connection then
        table.insert(State.Connections, connection)
    end
    return connection
end

local function connectSignal(signal, callback)
    local ok, connection = pcall(function()
        return signal:Connect(callback)
    end)
    if ok then
        keepConnection(connection)
        return true
    end
    return false
end

local function connectNamedSignal(object, signalName, callback)
    local ok, signal = pcall(function()
        return object[signalName]
    end)
    if ok and signal then
        return connectSignal(signal, callback)
    end
    return false
end

local function getPosition(instance)
    if not isInstance(instance) then
        return nil
    end
    local ok, result = pcall(function()
        if instance:IsA("BasePart") then
            return instance.Position
        elseif instance:IsA("Model") then
            local root = instance:FindFirstChild("HumanoidRootPart") or instance.PrimaryPart
            if root and root:IsA("BasePart") then
                return root.Position
            end
            return instance:GetPivot().Position
        elseif instance:IsA("Attachment") then
            return instance.WorldPosition
        end
        local parent = instance.Parent
        if parent and parent:IsA("BasePart") then
            return parent.Position
        end
        if parent and parent:IsA("Model") then
            local root = parent:FindFirstChild("HumanoidRootPart") or parent.PrimaryPart
            if root and root:IsA("BasePart") then
                return root.Position
            end
        end
        return nil
    end)
    if ok then
        return result
    end
    return nil
end

local function findHumanoid(model)
    local ok, humanoid = pcall(function()
        return model:FindFirstChildOfClass("Humanoid") or model:FindFirstChildWhichIsA("Humanoid", true)
    end)
    if ok then
        return humanoid
    end
    return nil
end

local function findModelRoot(model)
    local ok, root = pcall(function()
        local candidate = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
        if candidate and candidate:IsA("BasePart") then
            return candidate
        end
        return model:FindFirstChildWhichIsA("BasePart", true)
    end)
    if ok then
        return root
    end
    return nil
end

local function isPlayerCharacter(model)
    local ok, result = pcall(function()
        return Players:GetPlayerFromCharacter(model) ~= nil
    end)
    return ok and result
end

local function trackModel(model)
    if not State.Alive or not isInstance(model) then
        return
    end
    local ok, isModel = pcall(function()
        return model:IsA("Model")
    end)
    if not ok or not isModel then
        return
    end
    if model == (LocalPlayer and LocalPlayer.Character) or isPlayerCharacter(model) then
        return
    end
    if State.Entities[model] then
        return
    end

    local humanoid = findHumanoid(model)
    if not humanoid then
        return
    end

    local root = findModelRoot(model)
    local name = safeString(model.Name)
    local category = classifyName(name)
    local record = {
        Model = model,
        Humanoid = humanoid,
        Root = root,
        Name = name,
        Category = category,
        LastHealth = humanoid.Health,
        Dead = humanoid.Health <= 0,
        Connections = {},
    }
    State.Entities[model] = record
    State.Counters.NPCs = State.Counters.NPCs + 1

    local rootPosition = root and getPosition(root) or nil
    push("NPC", "Detected " .. category .. ": " .. name,
        "Health=" .. safeString(humanoid.Health) .. "/" .. safeString(humanoid.MaxHealth)
        .. " | Position=" .. (rootPosition and serializeValue(rootPosition) or "unknown")
        .. " | Model=" .. safeFullName(model)
        .. " | Root=" .. (root and safeFullName(root) or "not found"))

    local healthConnection = connectSignal(humanoid.HealthChanged, function(newHealth)
        if not State.Alive or not State.Recording then
            record.LastHealth = newHealth
            return
        end
        local oldHealth = record.LastHealth
        record.LastHealth = newHealth
        local delta = newHealth - oldHealth
        if math.abs(delta) >= 0.01 then
            local changeType = delta < 0 and "DAMAGE" or "HEAL"
            push(changeType, record.Name .. " health " .. string.format("%.1f -> %.1f", oldHealth, newHealth),
                "Delta=" .. string.format("%+.1f", delta) .. " | Class=" .. record.Category)
        end
        if newHealth <= 0 and not record.Dead then
            record.Dead = true
            push("KILL", "NPC reached zero health: " .. record.Name, "Class=" .. record.Category .. " | " .. safeFullName(model))
        end
    end)
    if healthConnection then
        table.insert(record.Connections, healthConnection)
    end

    local diedConnection = connectSignal(humanoid.Died, function()
        if not record.Dead then
            record.Dead = true
            push("KILL", "NPC Died event: " .. record.Name, "Class=" .. record.Category .. " | " .. safeFullName(model))
        end
    end)
    if diedConnection then
        table.insert(record.Connections, diedConnection)
    end
end

local function removeModel(model)
    local record = State.Entities[model]
    if not record then
        return
    end
    push("NPC", "Removed from Workspace: " .. record.Name, "Class=" .. record.Category)
    for _, connection in ipairs(record.Connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    State.Entities[model] = nil
end

local function logPrompt(prompt, eventName)
    if not isInstance(prompt) then
        return
    end
    local actionText = ""
    local objectText = ""
    local holdDuration = "?"
    local distance = "?"
    local enabled = "?"
    pcall(function()
        actionText = prompt.ActionText
        objectText = prompt.ObjectText
        holdDuration = prompt.HoldDuration
        distance = prompt.MaxActivationDistance
        enabled = prompt.Enabled
    end)
    local path = safeFullName(prompt)
    local isTokenRelated = containsAny(path .. " " .. actionText .. " " .. objectText, {"alien", "token"})
    push(isTokenRelated and "TOKEN" or "PROMPT", eventName .. ": " .. (objectText ~= "" and objectText or prompt.Name),
        "Action=" .. safeString(actionText) .. " | Hold=" .. safeString(holdDuration)
        .. " | MaxDistance=" .. safeString(distance) .. " | Enabled=" .. safeString(enabled)
        .. " | Path=" .. path)
end

local function trackPrompt(prompt)
    if not isInstance(prompt) or State.SeenPrompts[prompt] then
        return
    end
    local ok, isPrompt = pcall(function()
        return prompt:IsA("ProximityPrompt")
    end)
    if not ok or not isPrompt then
        return
    end
    State.SeenPrompts[prompt] = true
    logPrompt(prompt, "Prompt discovered")
end

local VISUAL_CLASSES = {
    Highlight = true,
    BillboardGui = true,
    BoxHandleAdornment = true,
    SelectionBox = true,
    Beam = true,
    Trail = true,
    ParticleEmitter = true,
    PointLight = true,
    SpotLight = true,
    SurfaceLight = true,
}

local function trackVisualObject(instance)
    if not isInstance(instance) or State.SeenVisuals[instance] then
        return
    end
    local className = ""
    pcall(function() className = instance.ClassName end)
    if not VISUAL_CLASSES[className] then
        return
    end
    State.SeenVisuals[instance] = true
    local properties = {}
    local propertyNames = {"Adornee", "Enabled", "AlwaysOnTop", "FillColor", "OutlineColor",
        "FillTransparency", "OutlineTransparency", "Size", "StudsOffset", "Color", "Brightness",
        "Range", "Transparency", "Texture", "Rate", "Lifetime"}
    for _, propertyName in ipairs(propertyNames) do
        local ok, value = pcall(function() return instance[propertyName] end)
        if ok and value ~= nil then
            table.insert(properties, propertyName .. "=" .. serializeValue(value))
        end
    end
    push("VISUAL", "Visual/effect object detected: " .. className .. " / " .. safeString(instance.Name),
        table.concat(properties, " | ") .. " | Path=" .. safeFullName(instance))
end

local function trackInterestingObject(instance)
    if not isInstance(instance) or State.SeenObjects[instance] then
        return
    end
    local name = ""
    local className = ""
    pcall(function()
        name = instance.Name
        className = instance.ClassName
    end)
    local path = safeFullName(instance)
    if not containsAny(name .. " " .. path, {"alien", "token", "pickup", "drop", "collect", "loot"}) then
        return
    end
    State.SeenObjects[instance] = true
    local position = getPosition(instance)
    push("LOOT", "Object detected: " .. name,
        "Class=" .. className .. " | Position=" .. (position and serializeValue(position) or "unknown") .. " | Path=" .. path)
end

local function watchValueObject(valueObject)
    if not isInstance(valueObject) or State.SeenValues[valueObject] then
        return
    end
    local ok, isValue = pcall(function()
        return valueObject:IsA("ValueBase")
    end)
    if not ok or not isValue then
        return
    end
    local name = safeString(valueObject.Name)
    if not containsAny(name, {"alien", "token"}) then
        return
    end
    State.SeenValues[valueObject] = true
    local previous = "?"
    pcall(function()
        previous = serializeValue(valueObject.Value)
    end)
    push("TOKEN", "Token-like value found: " .. name, "Value=" .. previous .. " | Path=" .. safeFullName(valueObject))
    connectSignal(valueObject.Changed, function(newValue)
        push("TOKEN", name .. " changed", "Old=" .. previous .. " | New=" .. serializeValue(newValue) .. " | Path=" .. safeFullName(valueObject))
        previous = serializeValue(newValue)
    end)
end

local function watchTextObject(textObject)
    if not isInstance(textObject) or State.SeenTexts[textObject] then
        return
    end
    local ok, isText = pcall(function()
        return textObject:IsA("TextLabel") or textObject:IsA("TextButton") or textObject:IsA("TextBox")
    end)
    if not ok or not isText then
        return
    end
    local name = ""
    local textValue = ""
    pcall(function()
        name = textObject.Name
        textValue = textObject.Text
    end)
    local path = safeFullName(textObject)
    local combined = name .. " " .. textValue .. " " .. path
    local tokenRelated = containsAny(combined, {"alien", "token"})
    local gameStateRelated = containsAny(combined, {"wave", "round", "boss", "bus", "quest", "mission", "extracted", "game over", "victory", "defeat", "ufo"})
    local hudRelated = containsAny(path, {"hud", "currency", "counter", "topbar", "status"})
    if not tokenRelated and not gameStateRelated and not hudRelated then
        return
    end
    State.SeenTexts[textObject] = true
    local previous = textValue
    push(tokenRelated and "TOKEN" or "GUI", "UI text tracked: " .. name,
        "Text=" .. string.sub(textValue, 1, 160) .. " | Path=" .. path)
    local changedSignalOk, changedSignal = pcall(function()
        return textObject:GetPropertyChangedSignal("Text")
    end)
    if changedSignalOk and changedSignal then
        connectSignal(changedSignal, function()
            local current = ""
            pcall(function()
                current = textObject.Text
            end)
            if current ~= previous then
                push(tokenRelated and "TOKEN" or "GUI", "UI text changed: " .. name,
                    "Old=" .. string.sub(previous, 1, 120) .. " | New=" .. string.sub(current, 1, 120) .. " | Path=" .. path)
                previous = current
            end
        end)
    end
end

local function watchTool(tool)
    if not isInstance(tool) or State.SeenTools[tool] then
        return
    end
    local ok, isTool = pcall(function()
        return tool:IsA("Tool")
    end)
    if not ok or not isTool then
        return
    end
    State.SeenTools[tool] = true
    push("WEAPON", "Tool available: " .. safeString(tool.Name), "Path=" .. safeFullName(tool))

    connectNamedSignal(tool, "Activated", function()
        push("WEAPON", "Tool Activated: " .. safeString(tool.Name), "Path=" .. safeFullName(tool))
    end)
    connectNamedSignal(tool, "Equipped", function()
        push("WEAPON", "Tool Equipped: " .. safeString(tool.Name), "Path=" .. safeFullName(tool))
    end)
    connectNamedSignal(tool, "Unequipped", function()
        push("WEAPON", "Tool Unequipped: " .. safeString(tool.Name), "Path=" .. safeFullName(tool))
    end)

    local descendants = {}
    pcall(function()
        descendants = tool:GetDescendants()
    end)
    for _, child in ipairs(descendants) do
        watchValueObject(child)
    end
end

local function trackRemoteContainer(container)
    local descendants = {}
    pcall(function()
        descendants = container:GetDescendants()
    end)
    local count = 0
    for _, instance in ipairs(descendants) do
        local className = ""
        pcall(function()
            className = instance.ClassName
        end)
        if className == "RemoteEvent" or className == "RemoteFunction" then
            count = count + 1
            push("REMOTE", "Remote discovered: " .. safeString(instance.Name),
                "Class=" .. className .. " | Path=" .. safeFullName(instance))
        end
    end
    push("SYSTEM", "Remote inventory scanned: " .. safeFullName(container), "Count=" .. safeString(count))
end

local function getNearestTrackedNPC(origin)
    local nearest = nil
    local nearestDistance = math.huge
    for model, record in pairs(State.Entities) do
        if record and not record.Dead and model and model.Parent then
            local root = record.Root or findModelRoot(model)
            if root then
                local ok, position = pcall(function()
                    return root.Position
                end)
                if ok and position then
                    local distance = (position - origin).Magnitude
                    if distance < nearestDistance then
                        nearestDistance = distance
                        nearest = {
                            Model = model,
                            Record = record,
                            Root = root,
                            Position = position,
                            Distance = distance,
                        }
                    end
                end
            end
        end
    end
    return nearest
end

local MOVEMENT_CONTROLLER_CLASSES = {
    BodyPosition = true,
    BodyVelocity = true,
    BodyGyro = true,
    BodyAngularVelocity = true,
    BodyForce = true,
    VectorForce = true,
    LinearVelocity = true,
    AngularVelocity = true,
    AlignPosition = true,
    AlignOrientation = true,
    Torque = true,
    LineForce = true,
}

local MOVEMENT_CONTROLLER_PROPERTIES = {
    "Position", "Velocity", "MaxForce", "MaxTorque", "P", "D", "Responsiveness",
    "MaxVelocity", "Enabled", "Attachment0", "Attachment1", "RigidityEnabled",
    "VectorVelocity", "LineVelocity", "Force", "RelativeTo", "Mode", "TargetPosition",
}

local function watchMovementController(instance)
    if not isInstance(instance) or State.SeenControllers[instance] then
        return
    end
    local className = ""
    pcall(function() className = instance.ClassName end)
    if not MOVEMENT_CONTROLLER_CLASSES[className] then
        return
    end
    State.SeenControllers[instance] = true
    local details = {"Parent=" .. safeFullName(instance.Parent)}
    for _, propertyName in ipairs(MOVEMENT_CONTROLLER_PROPERTIES) do
        local ok, value = pcall(function() return instance[propertyName] end)
        if ok and value ~= nil then
            table.insert(details, propertyName .. "=" .. serializeValue(value))
        end
    end
    push("MOVEMENT", "Movement controller detected: " .. className,
        table.concat(details, " | ") .. " | Path=" .. safeFullName(instance))
end

local function watchCharacter(character)
    if not character then
        return
    end
    push("PLAYER", "Character active", "Path=" .. safeFullName(character))
    local humanoid = findHumanoid(character)
    local root = findModelRoot(character)
    if humanoid then
        push("PLAYER", "Player humanoid", "Health=" .. safeString(humanoid.Health) .. "/" .. safeString(humanoid.MaxHealth)
            .. " | WalkSpeed=" .. safeString(humanoid.WalkSpeed) .. " | HipHeight=" .. safeString(humanoid.HipHeight))
        connectSignal(humanoid.HealthChanged, function(newHealth)
            push("PLAYER", "Player health changed", "Health=" .. safeString(newHealth))
        end)
        connectSignal(humanoid.StateChanged, function(oldState, newState)
            push("MOVEMENT", "Humanoid state changed", "Old=" .. safeString(oldState) .. " | New=" .. safeString(newState))
        end)
    end
    if root then
        push("MOVEMENT", "Root part found", "Part=" .. safeFullName(root) .. " | Position=" .. serializeValue(root.Position))
    end

    local children = {}
    pcall(function()
        children = character:GetChildren()
    end)
    for _, child in ipairs(children) do
        watchTool(child)
    end
    local characterDescendants = {}
    pcall(function()
        characterDescendants = character:GetDescendants()
    end)
    for _, descendant in ipairs(characterDescendants) do
        watchMovementController(descendant)
        watchValueObject(descendant)
    end
    connectSignal(character.DescendantAdded, function(descendant)
        watchMovementController(descendant)
        watchValueObject(descendant)
        watchTool(descendant)
    end)
    connectSignal(character.ChildAdded, function(child)
        watchTool(child)
        watchValueObject(child)
    end)
    connectSignal(character.ChildRemoved, function(child)
        if child:IsA("Tool") then
            push("WEAPON", "Tool removed from character: " .. safeString(child.Name))
        end
    end)
end

local function watchBackpack()
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    if not backpack then
        return
    end
    local children = {}
    pcall(function()
        children = backpack:GetChildren()
    end)
    for _, child in ipairs(children) do
        watchTool(child)
    end
    connectSignal(backpack.ChildAdded, function(child)
        watchTool(child)
    end)
end

local function watchPlayerAttributes()
    local attributes = {}
    pcall(function()
        attributes = LocalPlayer:GetAttributes()
    end)
    for attributeName, attributeValue in pairs(attributes) do
        if containsAny(attributeName, {"alien", "token"}) then
            push("TOKEN", "Player attribute found: " .. safeString(attributeName), "Value=" .. serializeValue(attributeValue))
            local ok, signal = pcall(function()
                return LocalPlayer:GetAttributeChangedSignal(attributeName)
            end)
            if ok and signal then
                connectSignal(signal, function()
                    local newValue = nil
                    pcall(function()
                        newValue = LocalPlayer:GetAttribute(attributeName)
                    end)
                    push("TOKEN", "Player attribute changed: " .. safeString(attributeName), "New=" .. serializeValue(newValue))
                end)
            end
        end
    end
end

local function watchGuiTree(root)
    if not root then
        return
    end
    local descendants = {}
    pcall(function()
        descendants = root:GetDescendants()
    end)
    for _, child in ipairs(descendants) do
        watchTextObject(child)
        watchValueObject(child)
    end
    connectSignal(root.DescendantAdded, function(child)
        watchTextObject(child)
        watchValueObject(child)
    end)
end

local function collectReferencedNPCs(value, output, depth)
    depth = depth or 0
    if depth > 2 then
        return
    end
    if isInstance(value) then
        local candidate = value
        while candidate and candidate ~= Workspace do
            local record = State.Entities[candidate]
            if record then
                local label = record.Category .. ":" .. record.Name .. " @ " .. safeFullName(candidate)
                for _, existing in ipairs(output) do
                    if existing == label then
                        return
                    end
                end
                table.insert(output, label)
                return
            end
            local ok, parent = pcall(function() return candidate.Parent end)
            candidate = ok and parent or nil
        end
    elseif type(value) == "table" then
        local count = 0
        for _, item in pairs(value) do
            count = count + 1
            if count > 8 then break end
            collectReferencedNPCs(item, output, depth + 1)
        end
    end
end

local function installRemoteHook()
    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
        push("SYSTEM", "Remote hook unavailable", "Missing hookmetamethod or getnamecallmethod; remote calls will not be intercepted.")
        return
    end

    local wrap = type(newcclosure) == "function" and newcclosure or function(fn)
        return fn
    end

    local original
    local ok, result = pcall(function()
        original = hookmetamethod(game, "__namecall", wrap(function(self, ...)
            local packedArgs = table.pack(...)
            if State.Alive and State.Recording and not State.HookBusy then
                local method = nil
                pcall(function()
                    method = getnamecallmethod()
                end)
                if method == "FireServer" or method == "InvokeServer" then
                    local className = ""
                    pcall(function()
                        className = self.ClassName
                    end)
                    if className == "RemoteEvent" or className == "RemoteFunction" then
                        State.Counters.RemoteCalls = State.Counters.RemoteCalls + 1
                        State.HookBusy = true
                        pcall(function()
                            local serialized = {}
                            local referencedNPCs = {}
                            for index = 1, math.min(packedArgs.n, 8) do
                                table.insert(serialized, tostring(index) .. "=" .. serializeValue(packedArgs[index], 0))
                                collectReferencedNPCs(packedArgs[index], referencedNPCs, 0)
                            end
                            local caller = "nil"
                            if type(getcallingscript) == "function" then
                                local callerScript = nil
                                pcall(function()
                                    callerScript = getcallingscript()
                                end)
                                if callerScript then
                                    caller = safeFullName(callerScript)
                                end
                            end
                            local executorContext = "unknown"
                            if type(checkcaller) == "function" then
                                local callerFlag = nil
                                pcall(function()
                                    callerFlag = checkcaller()
                                end)
                                executorContext = safeString(callerFlag)
                            end
                            local remotePath = safeFullName(self)
                            local details = "Class=" .. className .. " | CallerScript=" .. caller
                                .. " | checkcaller=" .. executorContext
                                .. " | ReferencedNPCs=" .. (#referencedNPCs > 0 and table.concat(referencedNPCs, " ; ") or "none")
                                .. " | Args=" .. table.concat(serialized, " ; ")
                            local signature = remotePath .. "|" .. safeString(method) .. "|" .. table.concat(serialized, "|")
                            local now = os.clock()
                            local previous = State.RemoteDedupe[signature]
                            if previous and (now - previous.clock) <= REMOTE_DEDUPE_WINDOW then
                                previous.count = previous.count + 1
                                previous.clock = now
                                previous.event.details = details .. " | Repeated=" .. safeString(previous.count)
                            else
                                local event = push("REMOTE", safeString(method) .. " -> " .. remotePath, details)
                                State.RemoteDedupe[signature] = {clock = now, count = 1, event = event}
                            end
                        end)
                        State.HookBusy = false
                    end
                elseif method == "PivotTo" or method == "SetPrimaryPartCFrame" or method == "MoveTo"
                    or method == "ChangeState" or method == "SetStateEnabled" or method == "Move"
                    or method == "ApplyImpulse" or method == "ApplyAngularImpulse" then
                    State.HookBusy = true
                    pcall(function()
                        local character = LocalPlayer and LocalPlayer.Character
                        local relevant = false
                        if character then
                            if self == character then
                                relevant = true
                            else
                                relevant = self:IsDescendantOf(character)
                            end
                        end
                        local executorCall = false
                        if type(checkcaller) == "function" then
                            pcall(function() executorCall = checkcaller() end)
                        end
                        if relevant and executorCall then
                            local serialized = {}
                            for index = 1, math.min(packedArgs.n, 6) do
                                table.insert(serialized, tostring(index) .. "=" .. serializeValue(packedArgs[index], 0))
                            end
                            push("MOVEMENT", "Executor method call: " .. safeString(method) .. " on " .. safeFullName(self),
                                "Args=" .. table.concat(serialized, " ; "))
                        end
                    end)
                    State.HookBusy = false
                elseif method == "InputHoldBegin" or method == "InputHoldEnd" then
                    local className = ""
                    pcall(function() className = self.ClassName end)
                    local executorCall = false
                    if type(checkcaller) == "function" then
                        pcall(function() executorCall = checkcaller() end)
                    end
                    if className == "ProximityPrompt" and executorCall then
                        State.HookBusy = true
                        pcall(function()
                            logPrompt(self, "Executor prompt method " .. safeString(method))
                        end)
                        State.HookBusy = false
                    end
                end
            end
            return original(self, table.unpack(packedArgs, 1, packedArgs.n))
        end))
        return true
    end)

    if ok and result then
        State.Hooks.Namecall = true
        push("SYSTEM", "Remote observer hook installed", "FireServer and InvokeServer are logged passively.")
    else
        push("ERROR", "Remote observer hook failed", safeString(result))
    end
end

local WATCHED_CHARACTER_PROPERTIES = {
    CFrame = true,
    Position = true,
    Anchored = true,
    CanCollide = true,
    AssemblyLinearVelocity = true,
    AssemblyAngularVelocity = true,
    WalkSpeed = true,
    JumpPower = true,
    JumpHeight = true,
    HipHeight = true,
    PlatformStand = true,
    AutoRotate = true,
    Sit = true,
    Health = true,
    Velocity = true,
    MaxForce = true,
    MaxTorque = true,
    P = true,
    D = true,
    Responsiveness = true,
    MaxVelocity = true,
    Enabled = true,
    Attachment0 = true,
    Attachment1 = true,
    RigidityEnabled = true,
    VectorVelocity = true,
    LineVelocity = true,
    Force = true,
    RelativeTo = true,
    Mode = true,
    TargetPosition = true,
}

local WATCHED_WORLD_PROPERTIES = {
    Gravity = true,
    ClockTime = true,
    TimeOfDay = true,
    Brightness = true,
    GlobalShadows = true,
    Ambient = true,
    OutdoorAmbient = true,
    FogEnd = true,
    ExposureCompensation = true,
}

local WATCHED_CAMERA_PROPERTIES = {
    CFrame = true,
    Focus = true,
    CameraSubject = true,
    CameraType = true,
    FieldOfView = true,
}

local function installPropertyHook()
    if type(hookmetamethod) ~= "function" then
        push("SYSTEM", "Property hook unavailable", "Missing hookmetamethod; movement sampling remains active.")
        return
    end

    local wrap = type(newcclosure) == "function" and newcclosure or function(fn)
        return fn
    end
    local original
    local ok, result = pcall(function()
        original = hookmetamethod(game, "__newindex", wrap(function(self, key, value)
            if State.Alive and State.Recording and not State.HookBusy and type(key) == "string" then
                local shouldLog = false
                local targetLabel = ""
                State.HookBusy = true
                pcall(function()
                    local character = LocalPlayer and LocalPlayer.Character
                    if character and isInstance(self) and self:IsDescendantOf(character) and WATCHED_CHARACTER_PROPERTIES[key] then
                        shouldLog = true
                        targetLabel = "Character " .. safeFullName(self)
                    elseif self == Workspace and WATCHED_WORLD_PROPERTIES[key] then
                        shouldLog = true
                        targetLabel = "Workspace"
                    elseif self == Lighting and WATCHED_WORLD_PROPERTIES[key] then
                        shouldLog = true
                        targetLabel = "Lighting"
                    else
                        local camera = Workspace.CurrentCamera
                        if camera and self == camera and WATCHED_CAMERA_PROPERTIES[key] then
                            local executorCall = false
                            if type(checkcaller) == "function" then
                                pcall(function() executorCall = checkcaller() end)
                            end
                            if executorCall then
                                shouldLog = true
                                targetLabel = "Camera"
                            end
                        end
                    end
                    if shouldLog then
                        local oldValue = "?"
                        pcall(function()
                            oldValue = serializeValue(self[key])
                        end)
                        local newValue = serializeValue(value)
                        local callerContext = "unknown"
                        if type(checkcaller) == "function" then
                            local callerFlag = nil
                            pcall(function() callerFlag = checkcaller() end)
                            callerContext = safeString(callerFlag)
                        end
                        local signature = targetLabel .. "|" .. key
                        local now = os.clock()
                        local previous = State.PropertyDedupe[signature]
                        if previous and (now - previous.clock) <= 0.08 then
                            previous.count = previous.count + 1
                            previous.clock = now
                            previous.event.details = "Old=" .. oldValue .. " | LatestNew=" .. newValue
                                .. " | CallerContext=" .. callerContext .. " | Repeated=" .. safeString(previous.count)
                        else
                            local event = push("PROPERTY", targetLabel .. " property write: " .. key,
                                "Old=" .. oldValue .. " | New=" .. newValue .. " | CallerContext=" .. callerContext)
                            State.PropertyDedupe[signature] = {clock = now, count = 1, event = event}
                        end
                    end
                end)
                State.HookBusy = false
            end
            return original(self, key, value)
        end))
        return true
    end)

    if ok and result then
        State.Hooks.NewIndex = true
        push("SYSTEM", "Property observer hook installed", "Selected character movement and lighting/world writes are logged passively.")
    else
        push("ERROR", "Property observer hook failed", safeString(result))
    end
end

local function installExecutorFunctionHooks()
    if type(hookfunction) ~= "function" then
        push("SYSTEM", "Executor-function hooks unavailable", "Missing hookfunction; executor interaction helpers will not be intercepted.")
        return
    end
    local wrap = type(newcclosure) == "function" and newcclosure or function(fn) return fn end

    local function findGlobal(name)
        local value = nil
        pcall(function() value = ENV[name] end)
        if type(value) ~= "function" then
            pcall(function() value = _G[name] end)
        end
        return value
    end

    local function hookGlobal(name, callback)
        local target = findGlobal(name)
        if type(target) ~= "function" then
            return
        end
        local original = nil
        local ok, result = pcall(function()
            original = hookfunction(target, wrap(function(...)
                local packed = table.pack(...)
                if State.Alive and State.Recording and not State.HookBusy then
                    State.HookBusy = true
                    pcall(callback, packed)
                    State.HookBusy = false
                end
                return original(table.unpack(packed, 1, packed.n))
            end))
            return true
        end)
        if ok and result then
            State.Hooks.Functions = State.Hooks.Functions + 1
            push("SYSTEM", "Executor helper hook installed: " .. name, "Pass-through observation only.")
        else
            push("ERROR", "Executor helper hook failed: " .. name, safeString(result))
        end
    end

    hookGlobal("fireproximityprompt", function(args)
        logPrompt(args[1], "Executor fireproximityprompt")
    end)
    hookGlobal("fireclickdetector", function(args)
        local detector = args[1]
        push("PROMPT", "Executor fireclickdetector", "Target=" .. serializeValue(detector) .. " | Clicks=" .. serializeValue(args[2]))
    end)
    hookGlobal("firetouchinterest", function(args)
        push("LOOT", "Executor firetouchinterest", "Part1=" .. serializeValue(args[1])
            .. " | Part2=" .. serializeValue(args[2]) .. " | TouchState=" .. serializeValue(args[3]))
    end)
    hookGlobal("mouse1click", function(args)
        push("INPUT", "Executor mouse1click", "Args=" .. serializeValue(args[1]))
    end)
    hookGlobal("mouse1press", function(args)
        push("INPUT", "Executor mouse1press", "Args=" .. serializeValue(args[1]))
    end)
    hookGlobal("mouse1release", function(args)
        push("INPUT", "Executor mouse1release", "Args=" .. serializeValue(args[1]))
    end)
    hookGlobal("mousemoverel", function(args)
        push("INPUT", "Executor mousemoverel", "X=" .. serializeValue(args[1]) .. " | Y=" .. serializeValue(args[2]))
    end)
    hookGlobal("mousemoveabs", function(args)
        push("INPUT", "Executor mousemoveabs", "X=" .. serializeValue(args[1]) .. " | Y=" .. serializeValue(args[2]))
    end)

    local drawingTable = nil
    pcall(function() drawingTable = Drawing end)
    if type(drawingTable) == "table" and type(drawingTable.new) == "function" then
        local originalDrawingNew = nil
        local ok, result = pcall(function()
            originalDrawingNew = hookfunction(drawingTable.new, wrap(function(...)
                local packed = table.pack(...)
                local results = table.pack(originalDrawingNew(table.unpack(packed, 1, packed.n)))
                if State.Alive and State.Recording and not State.HookBusy then
                    State.HookBusy = true
                    push("VISUAL", "Executor Drawing.new", "Type=" .. serializeValue(packed[1])
                        .. " | Args=" .. serializeValue(packed[2]))
                    State.HookBusy = false
                end
                return table.unpack(results, 1, results.n)
            end))
            return true
        end)
        if ok and result then
            State.Hooks.Functions = State.Hooks.Functions + 1
            push("SYSTEM", "Executor Drawing.new hook installed", "Drawing overlay creation will be logged when observable.")
        else
            push("SYSTEM", "Drawing.new hook unavailable", safeString(result))
        end
    end
end

local function installPromptSignals()
    connectNamedSignal(ProximityPromptService, "PromptShown", function(prompt)
        logPrompt(prompt, "Prompt shown")
    end)
    connectNamedSignal(ProximityPromptService, "PromptHidden", function(prompt)
        logPrompt(prompt, "Prompt hidden")
    end)
    connectNamedSignal(ProximityPromptService, "PromptButtonHoldBegan", function(prompt)
        logPrompt(prompt, "Prompt hold began")
    end)
    connectNamedSignal(ProximityPromptService, "PromptButtonHoldEnded", function(prompt)
        logPrompt(prompt, "Prompt hold ended")
    end)
    connectNamedSignal(ProximityPromptService, "PromptTriggered", function(prompt, player)
        if player == nil or player == LocalPlayer then
            logPrompt(prompt, "Prompt triggered by local player")
        end
    end)
end

local function installErrorMonitor()
    connectNamedSignal(LogService, "MessageOut", function(message, messageType)
        local kind = safeString(messageType)
        if containsAny(kind, {"error", "warning"}) or containsAny(message, {"error", "failed", "traceback"}) then
            push("ERROR", "Client output " .. kind, string.sub(safeString(message), 1, 260))
        end
    end)
end

local function installEnvironmentMonitor()
    local function watchProperty(object, propertyName, category)
        local ok, signal = pcall(function()
            return object:GetPropertyChangedSignal(propertyName)
        end)
        if ok and signal then
            connectSignal(signal, function()
                local value = "?"
                pcall(function()
                    value = serializeValue(object[propertyName])
                end)
                push(category, safeString(object.Name or object.ClassName) .. " changed: " .. propertyName, "New=" .. value)
            end)
        end
    end

    watchProperty(Workspace, "Gravity", "ENVIRONMENT")
    watchProperty(Lighting, "ClockTime", "ENVIRONMENT")
    watchProperty(Lighting, "TimeOfDay", "ENVIRONMENT")
    watchProperty(Lighting, "Brightness", "ENVIRONMENT")
    watchProperty(Lighting, "GlobalShadows", "ENVIRONMENT")
    watchProperty(Lighting, "Ambient", "ENVIRONMENT")
    watchProperty(Lighting, "OutdoorAmbient", "ENVIRONMENT")
    watchProperty(Lighting, "FogEnd", "ENVIRONMENT")
    watchProperty(Lighting, "ExposureCompensation", "ENVIRONMENT")

    local lightingDescendants = {}
    pcall(function() lightingDescendants = Lighting:GetDescendants() end)
    for _, descendant in ipairs(lightingDescendants) do
        trackVisualObject(descendant)
    end
    connectSignal(Lighting.DescendantAdded, function(descendant)
        trackVisualObject(descendant)
    end)
    connectSignal(Lighting.DescendantRemoving, function(descendant)
        if State.SeenVisuals[descendant] then
            push("ENVIRONMENT", "Lighting effect removed: " .. safeString(descendant.Name), "Class=" .. safeString(descendant.ClassName))
            State.SeenVisuals[descendant] = nil
        end
    end)
end

local function movementSampler()
    while State.Alive do
        if State.Recording then
            local character = LocalPlayer and LocalPlayer.Character
            local root = character and findModelRoot(character)
            local humanoid = character and findHumanoid(character)
            if root and humanoid then
                local position = nil
                local velocity = nil
                local floorMaterial = "?"
                local stateName = "?"
                local health = "?"
                local hipHeight = "?"
                local walkSpeed = "?"
                local platformStand = "?"
                local rootCanCollide = "?"
                pcall(function()
                    position = root.Position
                    velocity = root.AssemblyLinearVelocity
                    floorMaterial = safeString(humanoid.FloorMaterial)
                    stateName = safeString(humanoid:GetState())
                    health = safeString(humanoid.Health)
                    hipHeight = safeString(humanoid.HipHeight)
                    walkSpeed = safeString(humanoid.WalkSpeed)
                    platformStand = safeString(humanoid.PlatformStand)
                    rootCanCollide = safeString(root.CanCollide)
                end)

                if position then
                local nearest = getNearestTrackedNPC(position)
                local targetName = nearest and nearest.Record.Name or "none"
                local targetDistance = nearest and nearest.Distance or -1
                local verticalOffset = nearest and (position.Y - nearest.Position.Y) or 0
                local sample = {
                    Position = position,
                    Velocity = velocity,
                    Floor = floorMaterial,
                    State = stateName,
                    Target = targetName,
                    Distance = targetDistance,
                    VerticalOffset = verticalOffset,
                    Health = health,
                    HipHeight = hipHeight,
                    WalkSpeed = walkSpeed,
                    PlatformStand = platformStand,
                    RootCanCollide = rootCanCollide,
                }

                local previous = State.LastMovement
                local shouldLog = false
                if not previous then
                    shouldLog = true
                else
                    if (position - previous.Position).Magnitude >= 2 then shouldLog = true end
                    if velocity and previous.Velocity and (velocity - previous.Velocity).Magnitude >= 8 then shouldLog = true end
                    if targetName ~= previous.Target then shouldLog = true end
                    if math.abs(targetDistance - previous.Distance) >= 3 then shouldLog = true end
                    if math.abs(verticalOffset - previous.VerticalOffset) >= 2 then shouldLog = true end
                    if floorMaterial ~= previous.Floor or stateName ~= previous.State then shouldLog = true end
                    if health ~= previous.Health or hipHeight ~= previous.HipHeight or walkSpeed ~= previous.WalkSpeed then shouldLog = true end
                    if platformStand ~= previous.PlatformStand or rootCanCollide ~= previous.RootCanCollide then shouldLog = true end
                end

                if shouldLog then
                    push("MOVEMENT", "Player movement sample",
                        "Pos=" .. (position and serializeValue(position) or "?")
                        .. " | Vel=" .. (velocity and serializeValue(velocity) or "?")
                        .. " | Floor=" .. floorMaterial .. " | HumanoidState=" .. stateName
                        .. " | Health=" .. health .. " | WalkSpeed=" .. walkSpeed .. " | HipHeight=" .. hipHeight
                        .. " | PlatformStand=" .. platformStand .. " | RootCanCollide=" .. rootCanCollide
                        .. " | NearestNPC=" .. targetName .. " | NPCPos=" .. (nearest and serializeValue(nearest.Position) or "?")
                        .. " | Distance=" .. (targetDistance >= 0 and string.format("%.1f", targetDistance) or "?")
                        .. " | PlayerY-minus-NPCY=" .. (nearest and string.format("%.1f", verticalOffset) or "?"))
                end

                if nearest and nearest.Distance <= 100 and verticalOffset <= -3 then
                    if State.BelowTargetName ~= targetName then
                        State.BelowTargetName = targetName
                        State.BelowTargetSince = os.clock()
                        State.BelowTargetReported = false
                    elseif State.BelowTargetSince and (os.clock() - State.BelowTargetSince) >= 1.0 then
                        if not State.BelowTargetReported then
                            State.BelowTargetReported = true
                            push("MOVEMENT", "Sustained below-target positioning observed",
                                "Target=" .. targetName .. " | Distance=" .. string.format("%.1f", nearest.Distance)
                                .. " | VerticalOffset=" .. string.format("%.1f", verticalOffset)
                                .. " | This is positional evidence, not proof of the movement method.")
                        end
                    end
                else
                    State.BelowTargetName = nil
                    State.BelowTargetSince = nil
                    State.BelowTargetReported = false
                end

                State.LastMovement = sample
                end
            end
        end
        task.wait(MOVEMENT_SAMPLE_INTERVAL)
    end
end

local function updateUI()
    if not State.UI.Main or not State.UI.Main.Parent then
        return
    end

    local ui = State.UI
    pcall(function()
        ui.Status.Text = State.Recording and "● RECORDING" or "Ⅱ PAUSED"
        ui.Status.TextColor3 = State.Recording and Color3.fromRGB(105, 220, 150) or Color3.fromRGB(245, 190, 95)
        ui.Stats.Text = string.format("NPCs %d     REMOTE CALLS %d     LOOT %d     TOKEN EVENTS %d     KILLS %d",
            State.Counters.NPCs, State.Counters.RemoteCalls, State.Counters.Loot,
            State.Counters.TokenChanges, State.Counters.Kills)
        ui.RecordButton.Text = State.Recording and "PAUSE" or "RESUME"

        local startIndex = math.max(1, #State.Events - UI_ROW_COUNT + 1)
        for rowIndex = 1, UI_ROW_COUNT do
            local eventIndex = startIndex + rowIndex - 1
            local event = State.Events[eventIndex]
            local row = State.Rows[rowIndex]
            if event then
                row.Visible = true
                row.Text = string.format("[%s] %-10s %s", event.time, event.category, event.message)
                if event.category == "ERROR" then
                    row.TextColor3 = Color3.fromRGB(255, 135, 135)
                elseif event.category == "REMOTE" then
                    row.TextColor3 = Color3.fromRGB(160, 190, 255)
                elseif event.category == "TOKEN" or event.category == "KILL" then
                    row.TextColor3 = Color3.fromRGB(130, 225, 165)
                else
                    row.TextColor3 = Color3.fromRGB(218, 218, 228)
                end
            else
                row.Visible = false
                row.Text = ""
            end
        end
        ui.Footer.Text = "PlaceId=" .. safeString(game.PlaceId) .. " | Events=" .. safeString(#State.Events)
            .. " | Hooks: Remote=" .. safeString(State.Hooks.Namecall) .. " Property=" .. safeString(State.Hooks.NewIndex)
            .. " Helpers=" .. safeString(State.Hooks.Functions)
    end)
end

local function exportLogs()
    local lines = {}
    table.insert(lines, "LAST STOP OBSERVER V1.0")
    table.insert(lines, "PlaceId=" .. safeString(game.PlaceId))
    table.insert(lines, "GameId=" .. safeString(game.GameId))
    table.insert(lines, "JobId=" .. safeString(game.JobId))
    table.insert(lines, "Player=" .. safeString(LocalPlayer and LocalPlayer.Name or "unknown"))
    table.insert(lines, "RemoteHook=" .. safeString(State.Hooks.Namecall) .. " | PropertyHook=" .. safeString(State.Hooks.NewIndex)
        .. " | ExecutorHelperHooks=" .. safeString(State.Hooks.Functions))
    table.insert(lines, string.format("Counters: NPCs=%d RemoteEvents=%d RemoteCalls=%d Loot=%d TokenEvents=%d Kills=%d ToolActivations=%d PropertyWrites=%d Errors=%d",
        State.Counters.NPCs, State.Counters.Remotes, State.Counters.RemoteCalls, State.Counters.Loot, State.Counters.TokenChanges,
        State.Counters.Kills, State.Counters.ToolActivations, State.Counters.PropertyWrites, State.Counters.Errors))
    table.insert(lines, "--- EVENT LOG ---")
    for _, event in ipairs(State.Events) do
        table.insert(lines, string.format("[%s] [%.3f] [%s] %s | %s", event.time, event.clock, event.category, event.message, event.details))
    end

    local textOutput = table.concat(lines, "\n")
    local jsonOutput = ""
    pcall(function()
        jsonOutput = HttpService:JSONEncode(State.Events)
    end)

    local wrote = false
    if type(makefolder) == "function" then
        pcall(function()
            if type(isfolder) ~= "function" or not isfolder("LastStopObserver") then
                makefolder("LastStopObserver")
            end
        end)
    end
    if type(writefile) == "function" then
        local okText = pcall(function()
            writefile("LastStopObserver/last_stop_observer_log.txt", textOutput)
        end)
        local okJson = false
        if jsonOutput ~= "" then
            okJson = pcall(function()
                writefile("LastStopObserver/last_stop_observer_events.json", jsonOutput)
            end)
        end
        wrote = okText or okJson
    end

    if not wrote and type(setclipboard) == "function" then
        local ok = pcall(function()
            setclipboard(textOutput)
        end)
        wrote = ok
    end

    if wrote then
        push("SYSTEM", "Diagnostics exported", "Check Real workspace: LastStopObserver/last_stop_observer_log.txt and last_stop_observer_events.json")
    else
        push("ERROR", "Export unavailable", "writefile and setclipboard were unavailable or failed. Use the in-game log / executor console as fallback.")
        if type(warn) == "function" then
            warn(textOutput)
        end
    end
end

local function buildUI()
    local parent = nil
    if type(gethui) == "function" then
        pcall(function()
            parent = gethui()
        end)
    end
    if not parent then
        parent = CoreGui
    end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "LastStopObserverV1"
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = true
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local main = Instance.new("Frame")
    main.Name = "Main"
    main.Size = UDim2.new(0, 570, 0, 410)
    main.Position = UDim2.new(0, 24, 0, 110)
    main.BackgroundColor3 = Color3.fromRGB(19, 20, 29)
    main.BorderSizePixel = 0
    main.Parent = screenGui
    local mainCorner = Instance.new("UICorner")
    mainCorner.CornerRadius = UDim.new(0, 9)
    mainCorner.Parent = main

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(78, 86, 112)
    stroke.Transparency = 0.25
    stroke.Thickness = 1
    stroke.Parent = main

    local top = Instance.new("Frame")
    top.Name = "TopBar"
    top.Size = UDim2.new(1, 0, 0, 38)
    top.BackgroundColor3 = Color3.fromRGB(31, 34, 48)
    top.BorderSizePixel = 0
    top.Parent = main
    local topCorner = Instance.new("UICorner")
    topCorner.CornerRadius = UDim.new(0, 9)
    topCorner.Parent = top

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Position = UDim2.new(0, 13, 0, 0)
    title.Size = UDim2.new(0, 300, 1, 0)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = Color3.fromRGB(242, 242, 250)
    title.Text = "LAST STOP  /  OBSERVER V1.0"
    title.Parent = top

    local status = Instance.new("TextLabel")
    status.BackgroundTransparency = 1
    status.Position = UDim2.new(1, -132, 0, 0)
    status.Size = UDim2.new(0, 120, 1, 0)
    status.Font = Enum.Font.GothamBold
    status.TextSize = 11
    status.TextXAlignment = Enum.TextXAlignment.Right
    status.Text = "● RECORDING"
    status.TextColor3 = Color3.fromRGB(105, 220, 150)
    status.Parent = top

    local stats = Instance.new("TextLabel")
    stats.BackgroundTransparency = 1
    stats.Position = UDim2.new(0, 14, 0, 47)
    stats.Size = UDim2.new(1, -28, 0, 24)
    stats.Font = Enum.Font.GothamSemibold
    stats.TextSize = 11
    stats.TextXAlignment = Enum.TextXAlignment.Left
    stats.TextColor3 = Color3.fromRGB(190, 195, 214)
    stats.Text = "NPCs 0     REMOTES 0     LOOT 0     TOKEN EVENTS 0     KILLS 0"
    stats.Parent = main

    local logFrame = Instance.new("ScrollingFrame")
    logFrame.Name = "EventLog"
    logFrame.Position = UDim2.new(0, 12, 0, 80)
    logFrame.Size = UDim2.new(1, -24, 0, 272)
    logFrame.BackgroundColor3 = Color3.fromRGB(12, 13, 19)
    logFrame.BorderSizePixel = 0
    logFrame.ScrollBarThickness = 5
    logFrame.CanvasSize = UDim2.new(0, 0, 0, UI_ROW_COUNT * 20)
    logFrame.Parent = main
    local logCorner = Instance.new("UICorner")
    logCorner.CornerRadius = UDim.new(0, 6)
    logCorner.Parent = logFrame

    for index = 1, UI_ROW_COUNT do
        local row = Instance.new("TextLabel")
        row.BackgroundTransparency = 1
        row.Position = UDim2.new(0, 8, 0, (index - 1) * 20)
        row.Size = UDim2.new(1, -16, 0, 19)
        row.Font = Enum.Font.Code
        row.TextSize = 10
        row.TextXAlignment = Enum.TextXAlignment.Left
        row.TextYAlignment = Enum.TextYAlignment.Center
        row.TextColor3 = Color3.fromRGB(218, 218, 228)
        row.Text = ""
        row.Visible = false
        row.Parent = logFrame
        table.insert(State.Rows, row)
    end

    local function makeButton(name, text, x, width, color)
        local button = Instance.new("TextButton")
        button.Name = name
        button.Position = UDim2.new(0, x, 0, 362)
        button.Size = UDim2.new(0, width, 0, 30)
        button.BackgroundColor3 = color
        button.BorderSizePixel = 0
        button.Font = Enum.Font.GothamBold
        button.TextSize = 10
        button.TextColor3 = Color3.fromRGB(245, 245, 250)
        button.Text = text
        button.AutoButtonColor = true
        button.Parent = main
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 5)
        corner.Parent = button
        return button
    end

    local recordButton = makeButton("Record", "PAUSE", 12, 92, Color3.fromRGB(69, 83, 119))
    local exportButton = makeButton("Export", "EXPORT LOGS", 112, 112, Color3.fromRGB(52, 112, 91))
    local clearButton = makeButton("Clear", "CLEAR", 232, 82, Color3.fromRGB(91, 75, 112))
    local minimizeButton = makeButton("Minimize", "MINIMIZE", 322, 100, Color3.fromRGB(69, 73, 89))
    local unloadButton = makeButton("Unload", "UNLOAD", 430, 116, Color3.fromRGB(132, 65, 70))

    local footer = Instance.new("TextLabel")
    footer.BackgroundTransparency = 1
    footer.Position = UDim2.new(0, 14, 0, 395)
    footer.Size = UDim2.new(1, -28, 0, 12)
    footer.Font = Enum.Font.Gotham
    footer.TextSize = 9
    footer.TextXAlignment = Enum.TextXAlignment.Left
    footer.TextColor3 = Color3.fromRGB(135, 142, 165)
    footer.Text = "PlaceId=" .. safeString(game.PlaceId) .. " | Events=0"
    footer.Parent = main

    State.UI = {
        Screen = screenGui,
        Main = main,
        Top = top,
        Body = logFrame,
        Status = status,
        Stats = stats,
        Footer = footer,
        RecordButton = recordButton,
    }

    local dragging = false
    local dragInput = nil
    local dragStart = nil
    local startPosition = nil
    connectSignal(top.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPosition = main.Position
            connectSignal(input.Changed, function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    connectSignal(top.InputChanged, function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)
    connectSignal(game:GetService("UserInputService").InputChanged, function(input)
        if dragging and input == dragInput then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X,
                startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
        end
    end)

    connectSignal(recordButton.MouseButton1Click, function()
        State.Recording = not State.Recording
        push("SYSTEM", State.Recording and "Recording resumed" or "Recording paused", "Observer does not stop other scripts.")
        updateUI()
    end)
    connectSignal(exportButton.MouseButton1Click, exportLogs)
    connectSignal(clearButton.MouseButton1Click, function()
        State.Events = {}
        State.Counters = {NPCs = 0, Remotes = 0, RemoteCalls = 0, Loot = 0, TokenChanges = 0, Kills = 0, ToolActivations = 0, PropertyWrites = 0, Errors = 0}
        State.RemoteDedupe = {}
        State.PropertyDedupe = {}
        push("SYSTEM", "Event log cleared", "Existing monitoring connections remain active.")
        updateUI()
    end)
    connectSignal(minimizeButton.MouseButton1Click, function()
        State.UI.Body.Visible = not State.UI.Body.Visible
        State.UI.Stats.Visible = State.UI.Body.Visible
        State.UI.Footer.Visible = State.UI.Body.Visible
        recordButton.Visible = State.UI.Body.Visible
        exportButton.Visible = State.UI.Body.Visible
        clearButton.Visible = State.UI.Body.Visible
        unloadButton.Visible = State.UI.Body.Visible
        State.UI.Status.Visible = State.UI.Body.Visible
        minimizeButton.Text = State.UI.Body.Visible and "MINIMIZE" or "EXPAND"
        if State.UI.Body.Visible then
            minimizeButton.Position = UDim2.new(0, 322, 0, 362)
            minimizeButton.Size = UDim2.new(0, 100, 0, 30)
            main.Size = UDim2.new(0, 570, 0, 410)
        else
            minimizeButton.Position = UDim2.new(1, -98, 0, 4)
            minimizeButton.Size = UDim2.new(0, 90, 0, 30)
            main.Size = UDim2.new(0, 570, 0, 38)
        end
    end)

    local function unload()
        if not State.Alive then
            return
        end
        State.Alive = false
        State.Recording = false
        for _, connection in ipairs(State.Connections) do
            pcall(function()
                connection:Disconnect()
            end)
        end
        State.Connections = {}
        pcall(function()
            screenGui:Destroy()
        end)
        push("SYSTEM", "Observer unloaded", "Metamethod wrappers, if installed, remain pass-through and inactive.")
        ENV.__LAST_STOP_OBSERVER_V1 = nil
    end
    State.Unload = unload
    connectSignal(unloadButton.MouseButton1Click, unload)

    local parentOk = pcall(function()
        screenGui.Parent = parent
    end)
    if not parentOk then
        pcall(function()
            screenGui.Parent = CoreGui
        end)
    end
end

-- Build UI before monitoring so the initial scan can be reviewed immediately.
buildUI()

push("SYSTEM", "Observer started", "Read-only mode. No game remotes are invoked by this script.")
push("SYSTEM", "Runtime identity", "PlaceId=" .. safeString(game.PlaceId) .. " | GameId=" .. safeString(game.GameId)
    .. " | JobId=" .. safeString(game.JobId) .. " | Executor=" .. (type(identifyexecutor) == "function" and safeString(identifyexecutor()) or "unknown"))

installRemoteHook()
installPropertyHook()
installExecutorFunctionHooks()
installPromptSignals()
installErrorMonitor()
installEnvironmentMonitor()
watchPlayerAttributes()

-- Initial Workspace inventory.
local initialDescendants = {}
pcall(function()
    initialDescendants = Workspace:GetDescendants()
end)
push("SYSTEM", "Initial Workspace scan", "Descendants=" .. safeString(#initialDescendants))
for _, instance in ipairs(initialDescendants) do
    local className = ""
    local name = ""
    pcall(function()
        className = instance.ClassName
        name = instance.Name
    end)
    if className == "Model" then
        trackModel(instance)
    elseif className == "RemoteEvent" or className == "RemoteFunction" then
        push("REMOTE", "Workspace remote discovered: " .. name, "Class=" .. className .. " | Path=" .. safeFullName(instance))
    elseif className == "Humanoid" then
        local parentModel = instance.Parent
        if parentModel and parentModel:IsA("Model") then
            trackModel(parentModel)
        end
    elseif className == "ProximityPrompt" then
        trackPrompt(instance)
    elseif VISUAL_CLASSES[className] then
        trackVisualObject(instance)
    elseif className == "ClickDetector" then
        push("PROMPT", "ClickDetector discovered: " .. name, "Path=" .. safeFullName(instance))
    elseif containsAny(name, {"alien", "token", "pickup", "drop", "collect", "loot"}) then
        trackInterestingObject(instance)
    end
end

-- Dynamic Workspace monitoring.
connectSignal(Workspace.DescendantAdded, function(instance)
    if not State.Alive then return end
    local className = ""
    local name = ""
    pcall(function()
        className = instance.ClassName
        name = instance.Name
    end)
    if className == "Model" then
        trackModel(instance)
    elseif className == "RemoteEvent" or className == "RemoteFunction" then
        push("REMOTE", "Workspace remote added: " .. name, "Class=" .. className .. " | Path=" .. safeFullName(instance))
    elseif className == "Humanoid" then
        local parentModel = instance.Parent
        if parentModel and parentModel:IsA("Model") then
            trackModel(parentModel)
        end
    elseif className == "ProximityPrompt" then
        trackPrompt(instance)
    elseif VISUAL_CLASSES[className] then
        trackVisualObject(instance)
    elseif className == "ClickDetector" then
        push("PROMPT", "ClickDetector added: " .. name, "Path=" .. safeFullName(instance))
    elseif containsAny(name, {"alien", "token", "pickup", "drop", "collect", "loot"}) then
        trackInterestingObject(instance)
    end
end)

connectSignal(Workspace.DescendantRemoving, function(instance)
    if State.Entities[instance] then
        removeModel(instance)
    end
    if State.SeenObjects[instance] then
        push("LOOT", "Tracked object removed: " .. safeString(instance.Name), "Path=" .. safeFullName(instance))
        State.SeenObjects[instance] = nil
    end
    if State.SeenPrompts[instance] then
        push("PROMPT", "Prompt removed: " .. safeString(instance.Name), "Path=" .. safeFullName(instance))
        State.SeenPrompts[instance] = nil
    end
    if State.SeenVisuals[instance] then
        push("VISUAL", "Visual/effect object removed: " .. safeString(instance.Name), "Path=" .. safeFullName(instance))
        State.SeenVisuals[instance] = nil
    end
end)

-- Player GUI, backpack, and character monitoring.
local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
if playerGui then
    watchGuiTree(playerGui)
end
connectSignal(LocalPlayer.ChildAdded, function(child)
    if child:IsA("PlayerGui") then
        watchGuiTree(child)
    end
    if child:IsA("Backpack") then
        watchBackpack()
    end
end)
watchBackpack()
if LocalPlayer.Character then
    watchCharacter(LocalPlayer.Character)
end
connectSignal(LocalPlayer.CharacterAdded, function(character)
    task.wait(0.25)
    watchCharacter(character)
end)

-- ReplicatedStorage remote inventory (names and paths only; no calls are made).
trackRemoteContainer(ReplicatedStorage)
connectSignal(ReplicatedStorage.DescendantAdded, function(instance)
    local className = ""
    pcall(function() className = instance.ClassName end)
    if className == "RemoteEvent" or className == "RemoteFunction" then
        push("REMOTE", "Remote added: " .. safeString(instance.Name), "Class=" .. className .. " | Path=" .. safeFullName(instance))
    end
end)

-- Periodic lightweight sampling and UI refresh.
task.spawn(movementSampler)
task.spawn(function()
    while State.Alive do
        updateUI()
        task.wait(0.25)
    end
end)

task.spawn(function()
    while State.Alive do
        local activeCount = 0
        for model, record in pairs(State.Entities) do
            if model and model.Parent and record and not record.Dead then
                activeCount = activeCount + 1
            end
        end
        State.ActiveNPCs = activeCount
        task.wait(2)
    end
end)

push("SYSTEM", "Ready", "Run the other script after this observer is active. Export logs after testing each feature separately.")
updateUI()
