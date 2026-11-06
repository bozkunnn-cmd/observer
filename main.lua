--[[
    CULTIVATION UNBOUND - FULL SESSION RECORDER
    Version: 1.2

    Purpose:
      Record the client-visible state of a fresh Cultivation Unbound session.

    Captures:
      - Initial snapshot of DataModel descendants
      - Instance creation/removal and selected attribute/property changes
      - GUI text, colors, visibility and trial timing visuals
      - Keyboard/mouse/touch/gamepad press and release (no mouse-move flood)
      - Local character and player state
      - Proximity prompts, click detectors, tools and bindable events
      - Incoming RemoteEvent traffic; outbound remote hooks are disabled by default
        because executor namecall hooks can interfere with client input/game behavior
      - High-frequency sampling of visible Trial GUI elements during tribulations
      - Periodic checkpoints of local player, character and PlayerGui

    This script is READ-ONLY. It does not click, fire remotes, change stats,
    move the character, or automate cultivation.

    Output:
      CultivationUnbound_Logs/CU_Recorder_<timestamp>_<userid>.jsonl
      JSONL = one JSON object per line.
      Press EXPORT & STOP to finalize the complete session file.

    Notes:
      - No intentional event-count limit when file append is available.
      - Full logging can create very large files and use additional CPU/disk.
      - Server-only state that never replicates to the client cannot be observed.
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local TextChatService = game:GetService("TextChatService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    warn("[CU Recorder] LocalPlayer is unavailable.")
    return
end

local sharedEnv = _G
if type(getgenv) == "function" then
    local ok, env = pcall(getgenv)
    if ok and type(env) == "table" then
        sharedEnv = env
    end
end

-- Stop an earlier copy before starting a new session recorder.
if type(sharedEnv.__CURecorderStop) == "function" then
    pcall(sharedEnv.__CURecorderStop, "replaced_by_new_session")
end
if sharedEnv.__CURecorderGui then
    pcall(function()
        sharedEnv.__CURecorderGui:Destroy()
    end)
end

local CONFIG = {
    FOLDER = "CultivationUnbound_Logs",
    FLUSH_INTERVAL = 1.0,
    FLUSH_BATCH_SIZE = 300,
    CHECKPOINT_INTERVAL = 45,
    TRIAL_SAMPLE_RATE = "RenderStepped",
    LOG_INPUT_CHANGED = false,
    LOG_REMOTE_TRAFFIC = false,
    LOG_RELEVANT_PROPERTY_CHANGES = true,
    LOG_WORLD_PHYSICS_CHANGES = false,
}

local running = true
local paused = false
local flushing = false
local totalEvents = 0
local totalInstances = 0
local totalBytes = 0
local droppedEvents = 0
local startedClock = os.clock()
local startedUnix = os.time()
local sequence = 0
local queue = {}
local memoryBatches = {}
local connections = {}
local uiConnections = {}
local tracked = setmetatable({}, { __mode = "k" })
local trialInstances = {}
local trialSampleCache = setmetatable({}, { __mode = "k" })
local trialWasActive = false
local storageMode = "unavailable"
local storageError = nil
local recoveryFilePath = nil
local filePath = nil
local gui = nil
local ui = {}
local statusText = "Starting..."

local sessionStamp = os.date("%Y%m%d_%H%M%S")
local sessionFile = "CU_Recorder_" .. sessionStamp .. "_" .. tostring(LocalPlayer.UserId) .. ".jsonl"
filePath = CONFIG.FOLDER .. "/" .. sessionFile

local function safePath(instance)
    if not instance then
        return "<nil>"
    end
    local ok, result = pcall(function()
        return instance:GetFullName()
    end)
    if ok and result then
        return result
    end
    local nameOk, name = pcall(function()
        return instance.Name
    end)
    return nameOk and tostring(name) or "<unparented>"
end

local function safeClass(instance)
    local ok, result = pcall(function()
        return instance.ClassName
    end)
    return ok and tostring(result) or "Unknown"
end

local function safeIsA(instance, className)
    local ok, result = pcall(function()
        return instance:IsA(className)
    end)
    return ok and result == true
end

local safeGet

local function normalize(value, depth, seen)
    depth = depth or 0
    seen = seen or {}

    if value == nil then
        return nil
    end

    local valueType = typeof(value)

    if valueType == "Instance" then
        return {
            __type = "Instance",
            class = safeClass(value),
            name = safeGet(value, "Name") or "?",
            path = safePath(value),
        }
    elseif valueType == "Vector2" then
        return { __type = "Vector2", x = value.X, y = value.Y }
    elseif valueType == "Vector3" then
        return { __type = "Vector3", x = value.X, y = value.Y, z = value.Z }
    elseif valueType == "Vector2int16" then
        return { __type = "Vector2int16", x = value.X, y = value.Y }
    elseif valueType == "Vector3int16" then
        return { __type = "Vector3int16", x = value.X, y = value.Y, z = value.Z }
    elseif valueType == "Color3" then
        return { __type = "Color3", r = value.R, g = value.G, b = value.B }
    elseif valueType == "CFrame" then
        local components = { value:GetComponents() }
        return { __type = "CFrame", components = components }
    elseif valueType == "UDim" then
        return { __type = "UDim", scale = value.Scale, offset = value.Offset }
    elseif valueType == "UDim2" then
        return {
            __type = "UDim2",
            x = { scale = value.X.Scale, offset = value.X.Offset },
            y = { scale = value.Y.Scale, offset = value.Y.Offset },
        }
    elseif valueType == "Rect" then
        return {
            __type = "Rect",
            min = normalize(value.Min, depth + 1, seen),
            max = normalize(value.Max, depth + 1, seen),
        }
    elseif valueType == "Ray" then
        return {
            __type = "Ray",
            origin = normalize(value.Origin, depth + 1, seen),
            direction = normalize(value.Direction, depth + 1, seen),
        }
    elseif valueType == "BrickColor" then
        return { __type = "BrickColor", name = value.Name, number = value.Number }
    elseif valueType == "EnumItem" then
        return tostring(value)
    elseif valueType == "NumberRange" then
        return { __type = "NumberRange", min = value.Min, max = value.Max }
    elseif valueType == "DateTime" then
        return { __type = "DateTime", unixTimestampMillis = value.UnixTimestampMillis }
    end

    if type(value) == "number" then
        if value ~= value then return "NaN" end
        if value == math.huge then return "Infinity" end
        if value == -math.huge then return "-Infinity" end
        return value
    elseif type(value) == "string" or type(value) == "boolean" then
        return value
    elseif type(value) == "function" then
        return "<function>"
    elseif type(value) == "thread" then
        return "<thread>"
    elseif type(value) == "userdata" then
        return tostring(value)
    elseif type(value) == "table" then
        if depth >= 6 then
            return "<max_depth>"
        end
        if seen[value] then
            return "<cycle>"
        end
        seen[value] = true

        local result = {}
        local count = 0
        for key, item in pairs(value) do
            count = count + 1
            if count > 300 then
                result.__truncated = true
                break
            end
            result[tostring(key)] = normalize(item, depth + 1, seen)
        end
        seen[value] = nil
        return result
    end

    return tostring(value)
end

local function packArguments(...)
    local count = select("#", ...)
    local values = {}
    for index = 1, count do
        values[index] = normalize(select(index, ...))
    end
    return { n = count, values = values }
end

local function classifyPath(path)
    local lower = string.lower(tostring(path or ""))
    local tags = {}
    local terms = {
        { "qi", "qi" },
        { "body", "body" },
        { "trial", "trial" },
        { "breakthrough", "breakthrough" },
        { "cultivat", "cultivation" },
        { "realm", "realm" },
        { "quest", "quest" },
        { "inventory", "inventory" },
        { "backpack", "inventory" },
        { "tool", "tool" },
        { "skill", "skill" },
        { "boss", "boss" },
        { "enemy", "enemy" },
        { "herb", "herb" },
        { "pill", "pill" },
        { "sect", "sect" },
        { "event", "world_event" },
        { "silver", "currency" },
        { "stone", "currency" },
        { "soul", "soul" },
        { "leaderstat", "leaderstats" },
    }
    local seenTags = {}
    for _, pair in ipairs(terms) do
        if string.find(lower, pair[1], 1, true) and not seenTags[pair[2]] then
            seenTags[pair[2]] = true
            table.insert(tags, pair[2])
        end
    end
    return tags
end

local function addConnection(connection)
    if connection then
        table.insert(connections, connection)
    end
    return connection
end

local function addUiConnection(connection)
    if connection then
        table.insert(uiConnections, connection)
    end
    return connection
end

safeGet = function(instance, property)
    local ok, value = pcall(function()
        return instance[property]
    end)
    if ok then
        return value
    end
    return nil
end

local function getAttributes(instance)
    local ok, attributes = pcall(function()
        return instance:GetAttributes()
    end)
    if ok and type(attributes) == "table" then
        return normalize(attributes)
    end
    return {}
end

local function getTags(instance)
    local ok, tags = pcall(function()
        return CollectionService:GetTags(instance)
    end)
    if ok then
        return tags
    end
    return {}
end

local function propertiesFor(instance)
    local props = { "Name", "ClassName", "Archivable" }
    local function add(list)
        for _, property in ipairs(list) do
            table.insert(props, property)
        end
    end

    if safeIsA(instance, "GuiObject") then
        add({
            "Visible", "Active", "Selectable", "Position", "Size",
            "AbsolutePosition", "AbsoluteSize", "AnchorPoint", "Rotation",
            "ZIndex", "LayoutOrder", "BackgroundColor3",
            "BackgroundTransparency", "BorderColor3", "BorderSizePixel",
            "ClipsDescendants",
        })
    end

    if safeIsA(instance, "LayerCollector") then
        add({ "Enabled", "DisplayOrder", "ZIndexBehavior" })
    end

    if safeIsA(instance, "TextLabel") or safeIsA(instance, "TextButton") or safeIsA(instance, "TextBox") then
        add({
            "Text", "TextColor3", "TextTransparency", "TextStrokeColor3",
            "TextStrokeTransparency", "TextSize", "TextScaled", "TextWrapped",
            "TextTruncate", "RichText", "Font", "FontFace", "TextXAlignment",
            "TextYAlignment", "LineHeight", "PlaceholderText",
            "PlaceholderColor3", "ClearTextOnFocus", "MultiLine",
        })
    end

    if safeIsA(instance, "ImageLabel") or safeIsA(instance, "ImageButton") then
        add({ "Image", "ImageColor3", "ImageTransparency", "ImageRectOffset", "ImageRectSize", "ScaleType", "SliceCenter", "TileSize" })
    end

    if safeIsA(instance, "UIStroke") then
        add({ "Color", "Thickness", "Transparency", "Enabled", "ApplyStrokeMode", "LineJoinMode" })
    end

    if safeIsA(instance, "UIGradient") then
        add({ "Color", "Transparency", "Rotation", "Offset", "Enabled" })
    end

    if safeIsA(instance, "UIListLayout") or safeIsA(instance, "UIGridLayout") or safeIsA(instance, "UITableLayout") then
        add({ "FillDirection", "HorizontalAlignment", "VerticalAlignment", "SortOrder", "Padding", "CellSize", "CellPadding", "StartCorner", "FillDirectionMaxCells" })
    end

    if safeIsA(instance, "ValueBase") then
        add({ "Value" })
    end

    if safeIsA(instance, "BasePart") then
        -- Keep spatial details for likely gameplay objects and the local character.
        -- Static map geometry still gets its name/class/path/attributes, but does not
        -- generate thousands of unnecessary transform reads in the initial snapshot.
        local lowerPath = string.lower(safePath(instance))
        local spatialRelevant = string.find(lowerPath, "npc", 1, true)
            or string.find(lowerPath, "herb", 1, true)
            or string.find(lowerPath, "boss", 1, true)
            or string.find(lowerPath, "quest", 1, true)
            or string.find(lowerPath, "merchant", 1, true)
            or string.find(lowerPath, "event", 1, true)
            or string.find(lowerPath, "trial", 1, true)
            or string.find(lowerPath, "cultivation", 1, true)
            or string.find(lowerPath, "spawn", 1, true)
            or string.find(lowerPath, "resource", 1, true)
            or string.find(lowerPath, "drop", 1, true)
            or string.find(lowerPath, "zone", 1, true)
        local character = LocalPlayer.Character
        if character then
            local ok, insideCharacter = pcall(function()
                return instance:IsDescendantOf(character)
            end)
            spatialRelevant = spatialRelevant or (ok and insideCharacter)
        end
        if spatialRelevant then
            add({
                "CFrame", "Position", "Orientation", "Size", "Anchored", "CanCollide",
                "CanTouch", "CanQuery", "Transparency", "Color", "Material",
            })
        end
    end

    if safeIsA(instance, "Model") then
        add({ "PrimaryPart", "WorldPivot", "LevelOfDetail" })
    end

    if safeIsA(instance, "Humanoid") then
        add({
            "Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight",
            "UseJumpPower", "HipHeight", "Sit", "PlatformStand", "MoveDirection",
            "FloorMaterial", "AutoRotate", "RigType", "DisplayName", "NameDisplayDistance",
        })
    end

    if safeIsA(instance, "Tool") then
        add({ "Enabled", "CanBeDropped", "RequiresHandle", "ToolTip" })
    end

    if safeIsA(instance, "ProximityPrompt") then
        add({
            "ActionText", "ObjectText", "Enabled", "HoldDuration",
            "MaxActivationDistance", "RequiresLineOfSight", "KeyboardKeyCode",
            "GamepadKeyCode", "ClickablePrompt", "Exclusivity",
        })
    end

    if safeIsA(instance, "ClickDetector") then
        add({ "MaxActivationDistance", "CursorIcon" })
    end

    if safeIsA(instance, "Sound") then
        add({ "SoundId", "PlaybackSpeed", "Volume", "TimePosition", "Playing", "Looped", "RollOffMaxDistance" })
    end

    if safeIsA(instance, "ParticleEmitter") then
        add({ "Enabled", "Rate", "Lifetime", "Speed", "SpreadAngle", "Texture", "Color", "Transparency", "Size" })
    end

    if safeIsA(instance, "Camera") then
        add({ "CFrame", "Focus", "FieldOfView", "CameraType", "CameraSubject", "ViewportSize" })
    end

    if safeIsA(instance, "Lighting") then
        add({ "Brightness", "ClockTime", "TimeOfDay", "FogEnd", "FogStart", "FogColor", "Ambient", "OutdoorAmbient", "ExposureCompensation", "GlobalShadows" })
    end

    if safeIsA(instance, "Animation") then
        add({ "AnimationId" })
    end

    if safeIsA(instance, "Animator") then
        add({ "Parent" })
    end

    local unique = {}
    local output = {}
    for _, property in ipairs(props) do
        if not unique[property] then
            unique[property] = true
            table.insert(output, property)
        end
    end
    return output
end

local function snapshotProperties(instance)
    local result = {}
    for _, property in ipairs(propertiesFor(instance)) do
        local value = safeGet(instance, property)
        if value ~= nil then
            result[property] = normalize(value)
        end
    end
    return result
end

local function initializeStorage()
    local makeFolderAvailable = type(makefolder) == "function"
    local writeAvailable = type(writefile) == "function"
    local appendAvailable = type(appendfile) == "function"

    if makeFolderAvailable then
        pcall(makefolder, CONFIG.FOLDER)
    end

    if writeAvailable then
        local ok = pcall(writefile, filePath, "")
        if not ok then
            filePath = sessionFile
            ok = pcall(writefile, filePath, "")
        end
        if ok then
            if appendAvailable then
                storageMode = "append"
            else
                storageMode = "memory_then_write"
            end
            return
        end
    end

    if appendAvailable then
        local ok = pcall(appendfile, filePath, "")
        if ok then
            storageMode = "append"
            return
        end
    end

    storageMode = "memory_only"
    storageError = "Executor file APIs unavailable or failed. Logs will remain in memory until stop."
end

local function updateStatus(extra)
    local mode = storageMode == "append" and "DISK"
        or storageMode == "memory_then_write" and "MEM->FILE"
        or storageMode == "memory_recovery" and "MEM->RECOVERY"
        or storageMode == "written_at_stop" and "FILE WRITTEN"
        or storageMode == "written_recovery" and "RECOVERY WRITTEN"
        or "MEMORY ONLY"
    statusText = string.format(
        "%s | %d events | %d instances | %d queued | %s",
        paused and "PAUSED" or (running and "RECORDING" or "STOPPED"),
        totalEvents,
        totalInstances,
        #queue,
        mode
    )
    if extra then
        statusText = statusText .. " | " .. tostring(extra)
    end
    if ui.status then
        pcall(function()
            ui.status.Text = statusText
        end)
    end
    if ui.path then
        pcall(function()
            ui.path.Text = recoveryFilePath and (tostring(filePath) .. " + " .. tostring(recoveryFilePath)) or (filePath or "No file path")
        end)
    end
end

local function flushQueue()
    if flushing or #queue == 0 then
        return
    end
    flushing = true

    local batch = table.concat(queue, "\n") .. "\n"
    queue = {}

    if storageMode == "append" and type(appendfile) == "function" then
        local ok, err = pcall(appendfile, filePath, batch)
        if ok then
            totalBytes = totalBytes + #batch
        else
            storageMode = type(writefile) == "function" and "memory_recovery" or "memory_only"
            recoveryFilePath = filePath:gsub("%.jsonl$", "_remainder.jsonl")
            storageError = tostring(err)
            table.insert(memoryBatches, batch)
            warn("[CU Recorder] Disk append failed; switching to memory buffering: " .. tostring(err))
        end
    else
        table.insert(memoryBatches, batch)
    end

    flushing = false
    updateStatus()
end

local function emit(eventName, data, force)
    if not running and not force then
        return
    end
    if paused and not force then
        return
    end

    sequence = sequence + 1
    totalEvents = totalEvents + 1

    local row = {
        seq = sequence,
        time_unix = os.time(),
        time_local = os.date("%Y-%m-%d %H:%M:%S"),
        time_utc = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        elapsed = math.floor((os.clock() - startedClock) * 1000) / 1000,
        event = eventName,
        data = normalize(data or {}),
    }

    local ok, encoded = pcall(function()
        return HttpService:JSONEncode(row)
    end)

    if not ok then
        droppedEvents = droppedEvents + 1
        local fallback = string.format(
            '{"seq":%d,"event":"encode_error","message":"%s"}',
            sequence,
            tostring(encoded):gsub('"', "'"):gsub("\n", " ")
        )
        table.insert(queue, fallback)
    else
        table.insert(queue, encoded)
    end

    if #queue >= CONFIG.FLUSH_BATCH_SIZE then
        -- The writer loop flushes asynchronously; this flag is intentionally
        -- not a synchronous file write inside a game event callback.
        sharedEnv.__CURecorderNeedsFlush = true
    end
end

local function shouldSkipInstance(instance)
    if not instance then
        return true
    end
    if gui then
        local ok, isGui = pcall(function()
            return instance == gui or instance:IsDescendantOf(gui)
        end)
        if ok and isGui then
            return true
        end
    end
    return false
end

local function logButtonEvent(instance, eventName, extra)
    emit(eventName, {
        path = safePath(instance),
        class = safeClass(instance),
        name = safeGet(instance, "Name"),
        extra = extra or {},
        tags = classifyPath(safePath(instance)),
    })
end

local function connectSignal(instance, signalName, callback)
    local ok, signal = pcall(function()
        return instance[signalName]
    end)
    if not ok or not signal then
        return
    end
    local connected, connection = pcall(function()
        return signal:Connect(callback)
    end)
    if connected then
        addConnection(connection)
    end
end

local function pathContainsAny(path, words)
    local lower = string.lower(tostring(path or ""))
    for _, word in ipairs(words) do
        if string.find(lower, word, 1, true) then
            return true
        end
    end
    return false
end

local function shouldWatchChanged(instance)
    return safeIsA(instance, "ValueBase")
        or safeIsA(instance, "GuiObject")
        or safeIsA(instance, "LayerCollector")
        or safeIsA(instance, "Humanoid")
        or safeIsA(instance, "ProximityPrompt")
        or safeIsA(instance, "ClickDetector")
        or safeIsA(instance, "Tool")
end

local function shouldLogPropertyChange(instance, propertyName)
    if safeIsA(instance, "ValueBase") then
        return propertyName == "Value"
    end

    if safeIsA(instance, "Humanoid") then
        return propertyName == "Health"
            or propertyName == "MaxHealth"
            or propertyName == "WalkSpeed"
            or propertyName == "JumpPower"
            or propertyName == "JumpHeight"
            or propertyName == "Sit"
            or propertyName == "PlatformStand"
            or propertyName == "MoveDirection"
            or propertyName == "FloorMaterial"
            or propertyName == "AutoRotate"
    end

    if safeIsA(instance, "LayerCollector") then
        return propertyName == "Enabled" or propertyName == "DisplayOrder"
    end

    if safeIsA(instance, "GuiObject") then
        local path = safePath(instance)
        local trialUi = pathContainsAny(path, { "trial", "tribulation", "breakthrough" })
        local importantUi = trialUi or pathContainsAny(path, {
            "cultivation", "realm", "quest", "inventory", "backpack", "shop",
            "boss", "event", "skill", "herb", "pill", "sect", "tracker",
            "qi", "body", "reward", "dialog", "merchant",
        })

        if trialUi then
            return propertyName == "Visible"
                or propertyName == "Position"
                or propertyName == "Size"
                or propertyName == "BackgroundColor3"
                or propertyName == "BackgroundTransparency"
                or propertyName == "ImageColor3"
                or propertyName == "ImageTransparency"
                or propertyName == "Rotation"
                or propertyName == "Text"
                or propertyName == "TextColor3"
                or propertyName == "TextTransparency"
                or propertyName == "TextSize"
                or propertyName == "Enabled"
                or propertyName == "Active"
                or propertyName == "Selectable"
        end

        if importantUi then
            return propertyName == "Visible"
                or propertyName == "Enabled"
                or propertyName == "Text"
                or propertyName == "TextColor3"
                or propertyName == "TextTransparency"
                or propertyName == "BackgroundColor3"
                or propertyName == "BackgroundTransparency"
                or propertyName == "ImageColor3"
                or propertyName == "ImageTransparency"
                or propertyName == "Active"
                or propertyName == "Selectable"
        end

        return propertyName == "Visible" or propertyName == "Enabled"
    end

    if safeIsA(instance, "ProximityPrompt") then
        return propertyName == "ActionText"
            or propertyName == "ObjectText"
            or propertyName == "Enabled"
            or propertyName == "HoldDuration"
            or propertyName == "MaxActivationDistance"
            or propertyName == "RequiresLineOfSight"
    end

    if safeIsA(instance, "ClickDetector") then
        return propertyName == "MaxActivationDistance" or propertyName == "CursorIcon"
    end

    if safeIsA(instance, "Tool") then
        return propertyName == "Enabled" or propertyName == "ToolTip"
    end

    if safeIsA(instance, "BasePart") then
        return CONFIG.LOG_WORLD_PHYSICS_CHANGES
            and (propertyName == "CFrame" or propertyName == "Position"
                or propertyName == "AssemblyLinearVelocity"
                or propertyName == "AssemblyAngularVelocity")
    end

    return false
end

local function recordInstance(instance, origin)
    if not running or shouldSkipInstance(instance) or tracked[instance] then
        return
    end

    tracked[instance] = true
    totalInstances = totalInstances + 1

    local path = safePath(instance)
    local className = safeClass(instance)
    local lowerPath = string.lower(path)

    if string.find(lowerPath, "trial", 1, true) then
        table.insert(trialInstances, instance)
    end

    local initialAttributes = getAttributes(instance)
    emit(origin == "initial" and "instance_snapshot" or "instance_added", {
        origin = origin,
        path = path,
        class = className,
        name = safeGet(instance, "Name"),
        parent = safePath(safeGet(instance, "Parent")),
        properties = snapshotProperties(instance),
        attributes = initialAttributes,
        tags = getTags(instance),
        mechanic_tags = classifyPath(path),
    })

    if CONFIG.LOG_RELEVANT_PROPERTY_CHANGES and shouldWatchChanged(instance) then
        connectSignal(instance, "Changed", function(changed)
            local propertyName
            local value
            if safeIsA(instance, "ValueBase") then
                propertyName = "Value"
                value = changed
            elseif type(changed) == "string" then
                propertyName = changed
                value = safeGet(instance, propertyName)
            else
                return
            end

            if not shouldLogPropertyChange(instance, propertyName) then
                return
            end

            emit("property_changed", {
                path = safePath(instance),
                class = safeClass(instance),
                property = propertyName,
                value = value,
                tags = classifyPath(safePath(instance)),
            })
        end)
    end

    -- Attribute watchers are useful on mechanic-related objects and objects that
    -- already expose attributes. Avoid one extra connection on every static map part.
    if next(initialAttributes) ~= nil or pathContainsAny(path, {
        "cultivation", "realm", "trial", "breakthrough", "quest", "inventory",
        "boss", "skill", "herb", "pill", "sect", "event", "soul", "npc",
        "merchant", "tracker", "reward", "body", "qi",
    }) then
        connectSignal(instance, "AttributeChanged", function(attributeName)
            local attributeValue = nil
            local attributeOk, result = pcall(function()
                return instance:GetAttribute(attributeName)
            end)
            if attributeOk then
                attributeValue = result
            end
            emit("attribute_changed", {
                path = safePath(instance),
                class = className,
                attribute = attributeName,
                value = attributeValue,
                tags = classifyPath(safePath(instance)),
            })
        end)
    end

    if safeIsA(instance, "RemoteEvent") then
        connectSignal(instance, "OnClientEvent", function(...)
            emit("remote_inbound", {
                remote = safePath(instance),
                class = className,
                arguments = packArguments(...),
            })
        end)
    end

    if safeIsA(instance, "BindableEvent") and pathContainsAny(path, {
        "cultivation", "realm", "trial", "breakthrough", "quest", "inventory",
        "boss", "skill", "herb", "pill", "sect", "event", "soul",
    }) then
        connectSignal(instance, "Event", function(...)
            emit("bindable_event", {
                bindable = safePath(instance),
                arguments = packArguments(...),
            })
        end)
    end

    if safeIsA(instance, "GuiButton") then
        connectSignal(instance, "Activated", function(inputObject, clickCount)
            logButtonEvent(instance, "gui_button_activated", {
                input_type = inputObject and tostring(inputObject.UserInputType) or nil,
                key_code = inputObject and tostring(inputObject.KeyCode) or nil,
                click_count = clickCount,
            })
        end)
        connectSignal(instance, "MouseButton1Click", function()
            logButtonEvent(instance, "gui_button_mouse1_click")
        end)
        connectSignal(instance, "MouseButton2Click", function()
            logButtonEvent(instance, "gui_button_mouse2_click")
        end)
        connectSignal(instance, "MouseEnter", function()
            logButtonEvent(instance, "gui_button_mouse_enter")
        end)
        connectSignal(instance, "MouseLeave", function()
            logButtonEvent(instance, "gui_button_mouse_leave")
        end)
    end

    if safeIsA(instance, "TextBox") then
        connectSignal(instance, "Focused", function()
            logButtonEvent(instance, "textbox_focused")
        end)
        connectSignal(instance, "FocusLost", function(enterPressed, inputObject)
            logButtonEvent(instance, "textbox_focus_lost", {
                enter_pressed = enterPressed,
                input_type = inputObject and tostring(inputObject.UserInputType) or nil,
                text = safeGet(instance, "Text"),
            })
        end)
    end

    if safeIsA(instance, "ProximityPrompt") then
        for _, signalName in ipairs({ "PromptButtonHoldBegan", "PromptButtonHoldEnded", "Triggered", "TriggerEnded", "PromptShown", "PromptHidden" }) do
            connectSignal(instance, signalName, function(...)
                emit("proximity_prompt_" .. string.lower(signalName), {
                    path = safePath(instance),
                    action_text = safeGet(instance, "ActionText"),
                    object_text = safeGet(instance, "ObjectText"),
                    arguments = packArguments(...),
                })
            end)
        end
    end

    if safeIsA(instance, "ClickDetector") then
        for _, signalName in ipairs({ "MouseClick", "RightMouseClick", "MouseHoverEnter", "MouseHoverLeave" }) do
            connectSignal(instance, signalName, function(...)
                emit("click_detector_" .. string.lower(signalName), {
                    path = safePath(instance),
                    arguments = packArguments(...),
                })
            end)
        end
    end

    if safeIsA(instance, "Tool") then
        for _, signalName in ipairs({ "Activated", "Deactivated", "Equipped", "Unequipped" }) do
            connectSignal(instance, signalName, function(...)
                emit("tool_" .. string.lower(signalName), {
                    path = safePath(instance),
                    arguments = packArguments(...),
                })
            end)
        end
    end

    if safeIsA(instance, "Humanoid") then
        connectSignal(instance, "Died", function()
            emit("humanoid_died", { path = safePath(instance) })
        end)
        connectSignal(instance, "StateChanged", function(oldState, newState)
            emit("humanoid_state_changed", {
                path = safePath(instance),
                old_state = tostring(oldState),
                new_state = tostring(newState),
                health = safeGet(instance, "Health"),
            })
        end)
        connectSignal(instance, "HealthChanged", function(health)
            emit("humanoid_health_changed", {
                path = safePath(instance),
                health = health,
                max_health = safeGet(instance, "MaxHealth"),
            })
        end)
    end

    if safeIsA(instance, "Player") then
        connectSignal(instance, "Chatted", function(message)
            emit("player_chat", {
                player = safeGet(instance, "Name"),
                user_id = safeGet(instance, "UserId"),
                message = message,
            })
        end)
    end
end

local function getInputDetails(inputObject, processed)
    local data = {
        user_input_type = inputObject and tostring(safeGet(inputObject, "UserInputType")) or nil,
        key_code = inputObject and tostring(safeGet(inputObject, "KeyCode")) or nil,
        position = inputObject and normalize(safeGet(inputObject, "Position")) or nil,
        delta = inputObject and normalize(safeGet(inputObject, "Delta")) or nil,
        processed = processed == true,
    }

    if inputObject then
        local state = safeGet(inputObject, "UserInputState")
        data.user_input_state = state and tostring(state) or nil
    end

    if inputObject and (data.user_input_type == "Enum.UserInputType.MouseButton1" or data.user_input_type == "Enum.UserInputType.MouseButton2") then
        local ok, mouse = pcall(function()
            return LocalPlayer:GetMouse()
        end)
        if ok and mouse then
            data.mouse_target = normalize(safeGet(mouse, "Target"))
            data.mouse_hit = normalize(safeGet(mouse, "Hit"))
        end
        local locationOk, location = pcall(function()
            return UserInputService:GetMouseLocation()
        end)
        if locationOk then
            data.mouse_location = normalize(location)
        end
    end

    return data
end

local function connectGlobalSignals()
    addConnection(game.DescendantAdded:Connect(function(instance)
        recordInstance(instance, "live")
    end))

    addConnection(game.DescendantRemoving:Connect(function(instance)
        if shouldSkipInstance(instance) then return end
        emit("instance_removing", {
            path = safePath(instance),
            class = safeClass(instance),
            name = safeGet(instance, "Name"),
            parent = safePath(safeGet(instance, "Parent")),
            properties = snapshotProperties(instance),
        })
    end))

    addConnection(UserInputService.InputBegan:Connect(function(inputObject, processed)
        emit("input_began", getInputDetails(inputObject, processed))
    end))

    addConnection(UserInputService.InputEnded:Connect(function(inputObject, processed)
        emit("input_ended", getInputDetails(inputObject, processed))
    end))

    if CONFIG.LOG_INPUT_CHANGED then
        addConnection(UserInputService.InputChanged:Connect(function(inputObject, processed)
            emit("input_changed", getInputDetails(inputObject, processed))
        end))
    end

    addConnection(UserInputService.TextBoxFocused:Connect(function(textBox)
        emit("input_textbox_focused", { path = safePath(textBox), text = safeGet(textBox, "Text") })
    end))

    addConnection(UserInputService.TextBoxFocusReleased:Connect(function(textBox)
        emit("input_textbox_released", { path = safePath(textBox), text = safeGet(textBox, "Text") })
    end))

    addConnection(Players.PlayerAdded:Connect(function(player)
        emit("player_added", { name = player.Name, user_id = player.UserId, display_name = player.DisplayName })
        recordInstance(player, "live_player")
    end))

    addConnection(Players.PlayerRemoving:Connect(function(player)
        emit("player_removing", { name = player.Name, user_id = player.UserId })
    end))

    addConnection(LocalPlayer.CharacterAdded:Connect(function(character)
        emit("local_character_added", { path = safePath(character), name = character.Name })
        recordInstance(character, "character_added")
        for _, descendant in ipairs(character:GetDescendants()) do
            recordInstance(descendant, "character_added")
        end
    end))

    addConnection(LocalPlayer.CharacterRemoving:Connect(function(character)
        emit("local_character_removing", { path = safePath(character), name = character.Name })
    end))

    pcall(function()
        addConnection(TextChatService.MessageReceived:Connect(function(message)
            emit("text_chat_message", {
                text = safeGet(message, "Text"),
                prefix_text = safeGet(message, "PrefixText"),
                message_id = safeGet(message, "MessageId"),
                text_source = normalize(safeGet(message, "TextSource")),
            })
        end))
    end)
end

local function installRemoteHook()
    if not CONFIG.LOG_REMOTE_TRAFFIC then
        emit("capability", { name = "outbound_remote_capture", available = false, reason = "disabled_in_config" })
        return
    end

    sharedEnv.__CURecorderRemoteLog = function(remote, method, packedArgs)
        if not running or paused then return end
        emit("remote_outbound", {
            remote = safePath(remote),
            class = safeClass(remote),
            method = method,
            arguments = normalize(packedArgs),
        })
    end

    if sharedEnv.__CURecorderRemoteHookInstalled then
        emit("capability", { name = "outbound_remote_capture", available = true, note = "existing pass-through hook reused" })
        return
    end

    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
        emit("capability", { name = "outbound_remote_capture", available = false, reason = "executor_namecall_hook_unavailable" })
        return
    end

    local oldNamecall
    local wrapper = function(self, ...)
        local method = nil
        pcall(function()
            method = getnamecallmethod()
        end)

        if method == "FireServer" or method == "InvokeServer" then
            local logger = sharedEnv.__CURecorderRemoteLog
            if type(logger) == "function" then
                local ok, isRemote = pcall(function()
                    return self:IsA("RemoteEvent") or self:IsA("RemoteFunction")
                end)
                if ok and isRemote then
                    local count = select("#", ...)
                    local args = { n = count }
                    for index = 1, count do
                        args[index] = select(index, ...)
                    end
                    pcall(logger, self, method, args)
                end
            end
        end

        if oldNamecall then
            return oldNamecall(self, ...)
        end
        return nil
    end

    if type(newcclosure) == "function" then
        wrapper = newcclosure(wrapper)
    end

    local ok, original = pcall(function()
        return hookmetamethod(game, "__namecall", wrapper)
    end)

    if ok and original then
        oldNamecall = original
        sharedEnv.__CURecorderRemoteHookInstalled = true
        emit("capability", {
            name = "outbound_remote_capture",
            available = true,
            note = "pass-through namecall observer installed; remote calls are not modified",
        })
    else
        emit("capability", {
            name = "outbound_remote_capture",
            available = false,
            reason = tostring(original),
        })
    end
end

local function getGuiParent()
    if type(gethui) == "function" then
        local ok, result = pcall(gethui)
        if ok and result then
            return result
        end
    end

    local ok, coreGui = pcall(function()
        return game:GetService("CoreGui")
    end)
    if ok and coreGui then
        return coreGui
    end

    return LocalPlayer:WaitForChild("PlayerGui")
end

local function makeUiObject(className, properties, parent)
    local object = Instance.new(className)
    for property, value in pairs(properties or {}) do
        pcall(function()
            object[property] = value
        end)
    end
    object.Parent = parent
    return object
end

local function roundUi(object, radius)
    makeUiObject("UICorner", { CornerRadius = UDim.new(0, radius or 7) }, object)
end

local function makeUiButton(parent, text, x, width, color)
    local button = makeUiObject("TextButton", {
        Position = UDim2.fromOffset(x, 0),
        Size = UDim2.fromOffset(width, 28),
        BackgroundColor3 = color or Color3.fromRGB(39, 47, 62),
        BorderSizePixel = 0,
        Active = true,
        Selectable = false,
        AutoButtonColor = true,
        Font = Enum.Font.GothamBold,
        Text = text,
        TextColor3 = Color3.fromRGB(235, 240, 248),
        TextSize = 10,
    }, parent)
    roundUi(button, 6)
    return button
end

local function createUi()
    local parent = getGuiParent()
    gui = makeUiObject("ScreenGui", {
        Name = "CU_FullSessionRecorder",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 10,
    }, parent)
    sharedEnv.__CURecorderGui = gui

    local main = makeUiObject("Frame", {
        Name = "Main",
        Position = UDim2.new(1, -473, 0, 12),
        Size = UDim2.fromOffset(455, 150),
        BackgroundColor3 = Color3.fromRGB(17, 21, 29),
        BorderSizePixel = 0,
        Active = false,
        Draggable = false,
    }, gui)
    roundUi(main, 10)

    local header = makeUiObject("Frame", {
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = Color3.fromRGB(31, 39, 53),
        BorderSizePixel = 0,
        Active = false,
    }, main)
    roundUi(header, 10)

    makeUiObject("TextLabel", {
        Position = UDim2.fromOffset(11, 0),
        Size = UDim2.new(1, -20, 1, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        Text = "CULTIVATION UNBOUND | FULL SESSION RECORDER v1.2",
        TextColor3 = Color3.fromRGB(236, 241, 249),
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, header)

    ui.status = makeUiObject("TextLabel", {
        Position = UDim2.fromOffset(11, 42),
        Size = UDim2.new(1, -22, 0, 20),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        Text = "RECORDING | Initializing...",
        TextColor3 = Color3.fromRGB(117, 214, 153),
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, main)

    ui.path = makeUiObject("TextLabel", {
        Position = UDim2.fromOffset(11, 64),
        Size = UDim2.new(1, -22, 0, 24),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        Text = filePath,
        TextColor3 = Color3.fromRGB(164, 176, 195),
        TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, main)

    local buttonRow = makeUiObject("Frame", {
        Position = UDim2.fromOffset(11, 101),
        Size = UDim2.new(1, -22, 0, 28),
        BackgroundTransparency = 1,
    }, main)

    ui.pause = makeUiButton(buttonRow, "PAUSE", 0, 75, Color3.fromRGB(65, 77, 99))
    ui.flush = makeUiButton(buttonRow, "FLUSH", 82, 75, Color3.fromRGB(65, 77, 99))
    ui.export = makeUiButton(buttonRow, "EXPORT & STOP", 164, 126, Color3.fromRGB(54, 125, 91))
    ui.close = makeUiButton(buttonRow, "CLOSE", 299, 67, Color3.fromRGB(45, 53, 68))

    addUiConnection(ui.pause.MouseButton1Click:Connect(function()
        if not running then return end
        if paused then
            paused = false
            emit("recording_resumed", { reason = "ui_button" }, true)
            ui.pause.Text = "PAUSE"
            updateStatus()
        else
            emit("recording_paused", { reason = "ui_button" }, true)
            paused = true
            ui.pause.Text = "RESUME"
            updateStatus()
        end
    end))

    addUiConnection(ui.flush.MouseButton1Click:Connect(function()
        emit("manual_flush_requested", { queued = #queue }, true)
        flushQueue()
        updateStatus("manual flush")
    end))

    addUiConnection(ui.export.MouseButton1Click:Connect(function()
        if running then
            emit("export_requested", {
                file_path = filePath,
                queued_events = #queue,
                storage_mode = storageMode,
            }, true)
            sharedEnv.__CURecorderStop("export_button")
        end
    end))

    addUiConnection(ui.close.MouseButton1Click:Connect(function()
        pcall(function() gui:Destroy() end)
        gui = nil
        sharedEnv.__CURecorderGui = nil
    end))
end

local function isEffectivelyVisible(instance)
    local current = instance
    while current and current ~= game do
        if safeIsA(current, "GuiObject") and safeGet(current, "Visible") == false then
            return false
        end
        if safeIsA(current, "LayerCollector") and safeGet(current, "Enabled") == false then
            return false
        end
        current = safeGet(current, "Parent")
    end
    return true
end

local function trialIsActive()
    for _, instance in ipairs(trialInstances) do
        if instance and safeGet(instance, "Parent") then
            if safeIsA(instance, "GuiObject") and safeGet(instance, "Visible") == true and isEffectivelyVisible(instance) then
                return true
            end
        end
    end
    return false
end

local TRIAL_SAMPLE_PROPERTIES = {
    "Visible", "Enabled", "Position", "Size", "AbsolutePosition", "AbsoluteSize",
    "BackgroundColor3", "BackgroundTransparency", "ImageColor3", "ImageTransparency",
    "Rotation", "Text", "TextColor3", "TextTransparency", "TextSize", "ZIndex",
    "Color", "Thickness", "Transparency", "Offset", "Scale",
}

local function sampleTrialFrame()
    if not running or paused then
        return
    end

    local active = trialIsActive()
    if active and not trialWasActive then
        trialWasActive = true
        emit("trial_sampling_started", { tracked_trial_instances = #trialInstances })
    elseif not active and trialWasActive then
        trialWasActive = false
        emit("trial_sampling_stopped", { tracked_trial_instances = #trialInstances })
    end

    if not active then
        return
    end

    for _, instance in ipairs(trialInstances) do
        if instance and safeGet(instance, "Parent") then
            local properties = {}
            for _, property in ipairs(TRIAL_SAMPLE_PROPERTIES) do
                local value = safeGet(instance, property)
                if value ~= nil then
                    properties[property] = normalize(value)
                end
            end

            if next(properties) ~= nil then
                local signature = ""
                local ok, encoded = pcall(function()
                    return HttpService:JSONEncode(properties)
                end)
                if ok then
                    signature = encoded
                else
                    signature = tostring(properties)
                end

                if trialSampleCache[instance] ~= signature then
                    trialSampleCache[instance] = signature
                    emit("trial_frame_sample", {
                        path = safePath(instance),
                        class = safeClass(instance),
                        properties = properties,
                    })
                end
            end
        end
    end
end

local function checkpoint()
    if not running or paused then
        return
    end

    emit("checkpoint_start", {
        player = LocalPlayer.Name,
        user_id = LocalPlayer.UserId,
        place_id = game.PlaceId,
        job_id = game.JobId,
    })

    local roots = {}
    local ok, descendants = pcall(function()
        return LocalPlayer:GetDescendants()
    end)
    if ok then
        for _, instance in ipairs(descendants) do
            table.insert(roots, instance)
        end
    end

    local character = LocalPlayer.Character
    if character then
        table.insert(roots, character)
        local charOk, charDescendants = pcall(function()
            return character:GetDescendants()
        end)
        if charOk then
            for _, instance in ipairs(charDescendants) do
                table.insert(roots, instance)
            end
        end
    end

    local seen = setmetatable({}, { __mode = "k" })
    for index, instance in ipairs(roots) do
        if instance and not seen[instance] and not shouldSkipInstance(instance) then
            seen[instance] = true
            emit("checkpoint_instance", {
                path = safePath(instance),
                class = safeClass(instance),
                properties = snapshotProperties(instance),
                attributes = getAttributes(instance),
            })
        end
        if index % 100 == 0 then
            task.wait()
        end
    end

    emit("checkpoint_end", { instances = #roots })
end

local function stopRecorder(reason)
    if not running then
        return
    end

    emit("session_stop", {
        reason = reason or "manual",
        total_events = totalEvents,
        total_instances = totalInstances,
        elapsed_seconds = math.floor((os.clock() - startedClock) * 1000) / 1000,
        dropped_events = droppedEvents,
    }, true)

    running = false
    sharedEnv.__CURecorderRemoteLog = nil
    sharedEnv.__CURecorderStop = nil
    sharedEnv.__CURecorderNeedsFlush = nil

    for _, connection in ipairs(connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    connections = {}
    if ui.export then
        pcall(function()
            ui.export.Text = "SAVING..."
            ui.export.Active = false
        end)
    end
    if ui.pause then
        pcall(function()
            ui.pause.Text = "STOPPED"
            ui.pause.Active = false
        end)
    end

    while flushing do
        task.wait(0.05)
    end
    flushQueue()

    if storageMode == "memory_then_write" or storageMode == "memory_only" or storageMode == "memory_recovery" then
        if type(writefile) == "function" then
            local content = table.concat(memoryBatches)
            local targetPath = storageMode == "memory_recovery" and (recoveryFilePath or (filePath .. ".remainder.jsonl")) or filePath
            local ok, err = pcall(writefile, targetPath, content)
            if ok then
                totalBytes = totalBytes + #content
                storageMode = storageMode == "memory_recovery" and "written_recovery" or "written_at_stop"
                if storageMode == "written_recovery" then
                    recoveryFilePath = targetPath
                end
            else
                storageError = tostring(err)
                warn("[CU Recorder] Could not write memory log: " .. tostring(err))
            end
        else
            warn("[CU Recorder] No writefile API; remaining buffered data is only in memory.")
        end
    end

    local exportSucceeded = storageMode == "append"
        or storageMode == "written_at_stop"
        or storageMode == "written_recovery"

    if ui.export then
        pcall(function()
            ui.export.Text = not exportSucceeded and "NO FILE"
                or (storageMode == "written_recovery" and "2 FILES SAVED" or "EXPORTED")
        end)
    end

    local exportStatus = "EXPORT FAILED - check executor file API"
    if storageMode == "written_recovery" then
        exportStatus = "LOG EXPORTED IN 2 FILES | " .. tostring(totalBytes) .. " bytes"
    elseif exportSucceeded then
        exportStatus = "FULL LOG EXPORTED | " .. tostring(totalBytes) .. " bytes"
    end
    updateStatus(exportStatus)
    if recoveryFilePath then
        warn("[CU Recorder] Earlier log: " .. tostring(filePath))
        warn("[CU Recorder] Remainder log: " .. tostring(recoveryFilePath))
    end
    warn("[CU Recorder] Stopped. Events=" .. totalEvents .. " Instances=" .. totalInstances .. " File=" .. tostring(filePath))
    if storageError then
        warn("[CU Recorder] Storage note: " .. tostring(storageError))
    end
end

sharedEnv.__CURecorderStop = stopRecorder

-- Emergency controls work even if the floating panel is hidden or hard to reach:
-- RightCtrl+End stops and exports; RightCtrl+Home toggles the panel.
addConnection(UserInputService.InputBegan:Connect(function(inputObject, processed)
    if processed then return end
    local key = safeGet(inputObject, "KeyCode")
    local rightCtrl = UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
    local leftCtrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
    if not (rightCtrl or leftCtrl) then return end

    if key == Enum.KeyCode.End then
        stopRecorder("emergency_hotkey")
    elseif key == Enum.KeyCode.Home and gui then
        gui.Enabled = not gui.Enabled
    end
end))

-- Set up UI before scanning so the user can see that the recorder is active.
local uiOk, uiError = pcall(createUi)
if not uiOk then
    warn("[CU Recorder] GUI creation failed: " .. tostring(uiError))
end

initializeStorage()

emit("session_start", {
    recorder = "Cultivation Unbound Full Session Recorder",
    version = "1.2",
    place_id = game.PlaceId,
    game_id = game.GameId,
    job_id = game.JobId,
    creator_id = game.CreatorId,
    player_name = LocalPlayer.Name,
    display_name = LocalPlayer.DisplayName,
    user_id = LocalPlayer.UserId,
    account_age_days = LocalPlayer.AccountAge,
    started_unix = startedUnix,
    file_path = filePath,
    storage_mode = storageMode,
    config = CONFIG,
})

installRemoteHook()
connectGlobalSignals()

-- Start flushing before the initial snapshot; the initial scan can be large.
task.spawn(function()
    while running do
        task.wait(CONFIG.FLUSH_INTERVAL)
        if #queue > 0 or sharedEnv.__CURecorderNeedsFlush then
            sharedEnv.__CURecorderNeedsFlush = nil
            flushQueue()
        end
        updateStatus()
    end
    flushQueue()
end)

-- Record the DataModel root and every currently replicated descendant.
recordInstance(game, "initial_root")
local scanOk, initialDescendants = pcall(function()
    return game:GetDescendants()
end)

if scanOk and type(initialDescendants) == "table" then
    local count = #initialDescendants
    emit("initial_scan_started", { descendants = count })
    for index, instance in ipairs(initialDescendants) do
        recordInstance(instance, "initial")
        if index % 50 == 0 then
            updateStatus("initial scan " .. index .. "/" .. count)
            task.wait()
        end
    end
    emit("initial_scan_finished", { scanned = count, tracked = totalInstances })
else
    emit("initial_scan_failed", { error = tostring(initialDescendants) })
end

-- Record an immediate player/character checkpoint after the initial snapshot.
checkpoint()

-- Trial sampler: event-driven property changes are recorded continuously;
-- this extra RenderStepped sampler catches fast visual state/color transitions.
addConnection(RunService.RenderStepped:Connect(sampleTrialFrame))

-- Periodic player/character/PlayerGui checkpoints catch state that might not
-- raise a normal property-change event in a particular client build.
task.spawn(function()
    while running do
        task.wait(CONFIG.CHECKPOINT_INTERVAL)
        if running then
            checkpoint()
        end
    end
end)

updateStatus("initial recording active")
print("[CU Recorder] FULL SESSION RECORDING ACTIVE")
print("[CU Recorder] File: " .. tostring(filePath))
print("[CU Recorder] Storage: " .. tostring(storageMode))
print("[CU Recorder] Press EXPORT & STOP to finalize the complete JSONL file.")
print("[CU Recorder] Find it in the executor workspace: " .. tostring(filePath))
print("[CU Recorder] SAFE MODE: no input hooks, no outbound remote hook, no per-frame world physics logging.")
print("[CU Recorder] Only the visible buttons intercept clicks; panel background is click-through.")
