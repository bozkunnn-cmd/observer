--[[
    CULTIVATION UNBOUND - FULL SESSION RECORDER
    Version: 1.3

    Read-only client observer for a fresh progression session.

    Captures:
      * Local player, character, PlayerGui, leaderstats, backpack and attributes
      * Qi / Body cultivation, realms, layers, mastery, multipliers and progress UI
      * Minimal breakthroughs and tribulation UI state
      * Trial ring / glow / seal / tap geometry and visual changes at render rate
      * GUI text, visibility, colors, buttons and button activations
      * Relevant Workspace entities, NPCs, herbs, bosses, drops and prompts
      * Tools, proximity prompts, click detectors and Humanoid state / health
      * Input began / ended events (does not record text typed into TextBoxes)
      * Relevant inbound RemoteEvent traffic where visible to the client
      * Periodic compact checkpoints and local character position changes

    Storage:
      * appendfile available: rotates JSONL parts at a configurable size
      * writefile only: writes bounded JSONL segment files
      * Manifest lists every exported part and session totals
      * No intentional event-count cap

    Safety:
      * Does not click, fire remotes, change stats, move the character or automate play
      * Does not install namecall / metamethod hooks for outbound remote spying
      * Does not record mouse movement or chat message contents
      * GUI background is click-through; only its buttons receive clicks

    IMPORTANT:
      * Client-visible data only. Server-only state is not accessible.
      * Executor must support appendfile or writefile for reliable disk export.
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    warn("[CU Recorder] LocalPlayer is unavailable. Run from a client executor.")
    return
end

local sharedEnv = _G
if type(getgenv) == "function" then
    local ok, env = pcall(getgenv)
    if ok and type(env) == "table" then
        sharedEnv = env
    end
end

if type(sharedEnv.__CURecorderStop) == "function" then
    pcall(sharedEnv.__CURecorderStop, "replaced_by_v1_3")
end
if sharedEnv.__CURecorderGui then
    pcall(function()
        sharedEnv.__CURecorderGui:Destroy()
    end)
end

local CONFIG = {
    OUTPUT_FOLDER = "CultivationUnbound_Logs",
    FLUSH_INTERVAL = 1.0,
    FLUSH_BATCH_EVENTS = 800,
    APPEND_PART_BYTES = 16 * 1024 * 1024,
    WRITEFILE_SEGMENT_BYTES = 512 * 1024,
    WRITEFILE_SEGMENT_SECONDS = 5,
    CHECKPOINT_INTERVAL = 30,
    CHARACTER_POSITION_INTERVAL = 1,
    CHARACTER_POSITION_MIN_DELTA = 0.75,
    TRIAL_SAMPLE_HZ = 60,
    MAX_NORMALIZE_DEPTH = 6,
    MAX_TABLE_ENTRIES = 600,
    MAX_STRING_LENGTH = 2400,
    LOG_RELEVANT_INBOUND_REMOTES = true,
    LOG_ALL_INBOUND_REMOTES = true,
}

local running = true
local paused = false
local stopping = false
local flushing = false
local totalEvents = 0
local totalInstances = 0
local droppedEvents = 0
local sequence = 0
local startedClock = os.clock()
local startedUnix = os.time()
local queue = {}
local connections = {}
local uiConnections = {}
local tracked = setmetatable({}, { __mode = "k" })
local trialSet = setmetatable({}, { __mode = "k" })
local trialObjects = {}
local trialSampleCache = setmetatable({}, { __mode = "k" })
local eventCounts = {}
local partPaths = {}
local partBytes = {}
local partIndex = 0
local currentPartPath = nil
local currentPartBytes = 0
local segmentBuffer = ""
local segmentLastWrite = os.clock()
local totalBytes = 0
local storageMode = "checking"
local storageError = nil
local outputFolder = CONFIG.OUTPUT_FOLDER
local baseName = nil
local manifestPath = nil
local gui = nil
local ui = {}
local trialWasActive = false
local trialFrame = 0
local lastTrialSample = 0
local lastTrialPrune = 0
local lastPositionSample = 0
local lastCharacterPosition = nil
local lastCheckpoint = 0
local checkpointSignatures = {}
local initialScanComplete = false
local flushRequested = false

local sessionStamp = os.date("%Y%m%d_%H%M%S") .. "_" .. tostring(math.floor((os.clock() % 1) * 1000))
baseName = "CU_Recorder_" .. sessionStamp .. "_" .. tostring(LocalPlayer.UserId)

local function safeGet(instance, property)
    local ok, value = pcall(function()
        return instance[property]
    end)
    if ok then
        return value
    end
    return nil
end

local function safeClass(instance)
    local ok, value = pcall(function()
        return instance.ClassName
    end)
    return ok and tostring(value) or "Unknown"
end

local function safePath(instance)
    if not instance then
        return "<nil>"
    end
    local ok, value = pcall(function()
        return instance:GetFullName()
    end)
    if ok and value then
        return tostring(value)
    end
    local name = safeGet(instance, "Name")
    return name and tostring(name) or "<unparented>"
end

local function safeIsA(instance, className)
    local ok, result = pcall(function()
        return instance:IsA(className)
    end)
    return ok and result == true
end

local function safeDescendantOf(instance, ancestor)
    if not instance or not ancestor then
        return false
    end
    local ok, result = pcall(function()
        return instance == ancestor or instance:IsDescendantOf(ancestor)
    end)
    return ok and result == true
end

local function truncateString(value, maxLength)
    local text = tostring(value)
    if #text > maxLength then
        return string.sub(text, 1, maxLength - 3) .. "..."
    end
    return text
end

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
            name = truncateString(safeGet(value, "Name") or "?", 120),
            path = truncateString(safePath(value), 360),
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
    elseif type(value) == "string" then
        return truncateString(value, CONFIG.MAX_STRING_LENGTH)
    elseif type(value) == "boolean" then
        return value
    elseif type(value) == "function" then
        return "<function>"
    elseif type(value) == "thread" then
        return "<thread>"
    elseif type(value) == "userdata" then
        return truncateString(tostring(value), 300)
    elseif type(value) == "table" then
        if depth >= CONFIG.MAX_NORMALIZE_DEPTH then
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
            if count > CONFIG.MAX_TABLE_ENTRIES then
                result.__truncated = true
                break
            end
            result[truncateString(key, 100)] = normalize(item, depth + 1, seen)
        end
        seen[value] = nil
        return result
    end

    return truncateString(tostring(value), 300)
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

local MECHANIC_WORDS = {
    "cultivat", "qi", "body", "realm", "trial", "tribulation", "breakthrough",
    "quest", "inventory", "backpack", "skill", "boss", "enemy", "herb", "pill",
    "sect", "event", "silver", "stone", "soul", "leaderstat", "npc", "merchant",
    "reward", "stats", "trait", "race", "clan", "manual", "training", "weight",
    "meditat", "aura", "sense", "zone", "shop", "currency", "party", "spirit",
    "map", "teleport", "resource", "drop", "chest", "treasure", "dialog", "tracker",
    "title", "potion", "elixir", "pvp", "arena", "damage", "health", "combat",
    "fight", "refin", "meridian", "dantian", "mastery", "progress", "multiplier",
    "speed", "realmdisplay", "worldboss", "worldevent", "qisense", "qi_sense",
}

local TRIAL_WORDS = { "trial", "tribulation", "breakthrough", "breakthroughmg", "breakthroughgui" }
local REMOTE_WORDS = {
    "cultivat", "qi", "body", "realm", "trial", "breakthrough", "quest", "inventory",
    "skill", "boss", "herb", "pill", "sect", "event", "reward", "shop", "purchase",
    "player", "character", "stat", "progress", "update", "sync", "state", "notify",
    "action", "data", "world", "spirit", "soul",
}

local function classifyPath(path)
    local lower = string.lower(tostring(path or ""))
    local tags = {}
    local map = {
        { "qi", "qi" }, { "body", "body" }, { "trial", "trial" },
        { "tribulation", "tribulation" }, { "breakthrough", "breakthrough" },
        { "cultivat", "cultivation" }, { "realm", "realm" }, { "quest", "quest" },
        { "inventory", "inventory" }, { "backpack", "inventory" }, { "skill", "skill" },
        { "boss", "boss" }, { "enemy", "enemy" }, { "herb", "herb" },
        { "pill", "pill" }, { "sect", "sect" }, { "event", "world_event" },
        { "silver", "currency" }, { "stone", "currency" }, { "soul", "soul" },
        { "trait", "trait" }, { "npc", "npc" }, { "merchant", "merchant" },
        { "party", "party" }, { "leaderstat", "leaderstats" },
    }
    local seen = {}
    for _, pair in ipairs(map) do
        if string.find(lower, pair[1], 1, true) and not seen[pair[2]] then
            seen[pair[2]] = true
            table.insert(tags, pair[2])
        end
    end
    return tags
end

local function isTrialPath(path)
    return pathContainsAny(path, TRIAL_WORDS)
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
    if ok and type(tags) == "table" then
        return tags
    end
    return {}
end

local function getTimestampMillis()
    local ok, result = pcall(function()
        return DateTime.now().UnixTimestampMillis
    end)
    if ok and result then
        return result
    end
    return os.time() * 1000
end

local function getPartPath(index)
    return outputFolder .. "/" .. baseName .. "_part" .. string.format("%03d", index) .. ".jsonl"
end

local function getManifestData(finalState)
    return {
        recorder = "Cultivation Unbound Full Session Recorder",
        version = "1.3",
        place_id = game.PlaceId,
        game_id = game.GameId,
        job_id = game.JobId,
        player_name = LocalPlayer.Name,
        display_name = LocalPlayer.DisplayName,
        user_id = LocalPlayer.UserId,
        started_unix = startedUnix,
        ended_unix = finalState and os.time() or nil,
        status = finalState and "stopped" or "recording",
        storage_mode = storageMode,
        total_events = totalEvents,
        total_instances = totalInstances,
        dropped_events = droppedEvents,
        total_bytes = totalBytes,
        parts = partPaths,
        event_counts = eventCounts,
        storage_error = storageError,
    }
end

local function writeManifest(finalState)
    local manifest = getManifestData(finalState)
    local okEncode, encoded = pcall(function()
        return HttpService:JSONEncode(manifest)
    end)
    if not okEncode then
        return false, tostring(encoded)
    end

    if type(writefile) == "function" then
        local ok, err = pcall(writefile, manifestPath, encoded)
        if ok then
            return true
        end
        storageError = "Manifest write failed: " .. tostring(err)
    end

    if type(appendfile) == "function" then
        local appendPath = manifestPath:gsub("%.json$", ".jsonl")
        local ok, err = pcall(appendfile, appendPath, encoded .. "\n")
        if ok then
            manifestPath = appendPath
            return true
        end
        storageError = "Manifest append failed: " .. tostring(err)
    end

    return false, storageError or "No manifest file API"
end

local function createFolderIfPossible()
    if type(makefolder) == "function" then
        pcall(makefolder, outputFolder)
    else
        outputFolder = "."
    end
end

local function initializeStorageAt(folder)
    local canAppend = type(appendfile) == "function"
    local canWrite = type(writefile) == "function"

    partIndex = 0
    currentPartPath = nil
    currentPartBytes = 0
    outputFolder = folder
    manifestPath = outputFolder .. "/" .. baseName .. (canWrite and "_manifest.json" or "_manifest.jsonl")

    if canAppend then
        partIndex = 1
        currentPartPath = getPartPath(partIndex)
        local created = false
        if canWrite then
            local ok = pcall(writefile, currentPartPath, "")
            created = ok
        end
        if not created then
            local ok = pcall(appendfile, currentPartPath, "")
            created = ok
        end
        if created then
            storageMode = "append"
            table.insert(partPaths, currentPartPath)
            partBytes[currentPartPath] = 0
            writeManifest(false)
            return true
        end
        storageError = "appendfile could not create the first JSONL part"
    end

    if canWrite then
        -- Use the manifest itself as a writefile probe, then replace it with
        -- the real manifest. This avoids leaving a disposable probe file.
        local probeOk = pcall(writefile, manifestPath, "{}")
        if probeOk then
            storageMode = "segments"
            writeManifest(false)
            return true
        end
        storageError = "writefile could not create the manifest in " .. tostring(folder)
    end

    return false
end

local function initializeStorage()
    local canAppend = type(appendfile) == "function"
    local canWrite = type(writefile) == "function"
    if not canAppend and not canWrite then
        storageMode = "unavailable"
        storageError = "Executor has neither appendfile nor writefile. Recording was not started."
        return false
    end

    createFolderIfPossible()
    if initializeStorageAt(outputFolder) then
        return true
    end

    if outputFolder ~= "." then
        warn("[CU Recorder] Output folder failed; trying executor workspace root.")
        if initializeStorageAt(".") then
            return true
        end
    end

    storageMode = "unavailable"
    storageError = storageError or "Could not initialize an output file"
    return false
end

local function updateStatus(extra)
    local mode = storageMode == "append" and "DISK / ROTATING"
        or storageMode == "segments" and "DISK / SEGMENTS"
        or storageMode == "unavailable" and "NO DISK - STOPPED"
        or tostring(storageMode):upper()
    local state = paused and "PAUSED" or (running and "RECORDING" or "STOPPED")
    local text = string.format("%s | %d events | %d instances | %d parts | %s", state, totalEvents, totalInstances, #partPaths, mode)
    if extra then
        text = text .. " | " .. tostring(extra)
    end
    if ui.status then
        pcall(function()
            ui.status.Text = text
        end)
    end
    if ui.path then
        pcall(function()
            ui.path.Text = outputFolder .. "/" .. baseName .. "_part*.jsonl"
        end)
    end
end

local function writeNewSegment(content)
    if content == "" then
        return true
    end
    if type(writefile) ~= "function" then
        return false, "writefile unavailable"
    end

    partIndex = partIndex + 1
    local path = getPartPath(partIndex)
    local ok, err = pcall(writefile, path, content)
    if not ok then
        partIndex = partIndex - 1
        return false, tostring(err)
    end

    table.insert(partPaths, path)
    partBytes[path] = #content
    totalBytes = totalBytes + #content
    return true
end

local function rotateAppendPart()
    partIndex = partIndex + 1
    currentPartPath = getPartPath(partIndex)
    local created = false
    if type(writefile) == "function" then
        local ok = pcall(writefile, currentPartPath, "")
        created = ok
    end
    if not created and type(appendfile) == "function" then
        local ok = pcall(appendfile, currentPartPath, "")
        created = ok
    end
    if not created then
        return false, "Could not create rotated JSONL part"
    end
    currentPartBytes = 0
    table.insert(partPaths, currentPartPath)
    partBytes[currentPartPath] = 0
    writeManifest(false)
    return true
end

local function flushQueue(forceSegment)
    if flushing then
        return false
    end
    if #queue == 0 and segmentBuffer == "" then
        return true
    end

    flushing = true
    local batch = ""
    if #queue > 0 then
        batch = table.concat(queue, "\n") .. "\n"
        queue = {}
    end

    local success = true
    if storageMode == "append" then
        if batch ~= "" then
            if currentPartBytes + #batch > CONFIG.APPEND_PART_BYTES and currentPartBytes > 0 then
                local rotateOk, rotateError = rotateAppendPart()
                if not rotateOk then
                    storageError = tostring(rotateError)
                    storageMode = type(writefile) == "function" and "segments" or "unavailable"
                end
            end
            if storageMode == "append" then
                local ok, err = pcall(appendfile, currentPartPath, batch)
                if ok then
                    currentPartBytes = currentPartBytes + #batch
                    totalBytes = totalBytes + #batch
                    partBytes[currentPartPath] = currentPartBytes
                else
                    storageError = "appendfile failed: " .. tostring(err)
                    storageMode = type(writefile) == "function" and "segments" or "unavailable"
                    segmentBuffer = segmentBuffer .. batch
                    success = false
                end
            else
                segmentBuffer = segmentBuffer .. batch
            end
        end
    elseif storageMode == "segments" then
        if batch ~= "" then
            segmentBuffer = segmentBuffer .. batch
        end
        local shouldWrite = forceSegment
            or #segmentBuffer >= CONFIG.WRITEFILE_SEGMENT_BYTES
            or (segmentBuffer ~= "" and os.clock() - segmentLastWrite >= CONFIG.WRITEFILE_SEGMENT_SECONDS)
        if shouldWrite and segmentBuffer ~= "" then
            local content = segmentBuffer
            local ok, err = writeNewSegment(content)
            if ok then
                segmentBuffer = ""
                segmentLastWrite = os.clock()
            else
                storageError = "writefile segment failed: " .. tostring(err)
                paused = true
                warn("[CU Recorder] Disk write failed; recording paused to prevent memory growth: " .. tostring(err))
                success = false
            end
        end
    else
        if batch ~= "" then
            droppedEvents = droppedEvents + 1
            storageError = storageError or "Storage unavailable; event batch could not be persisted"
            success = false
        end
    end

    if totalEvents > 0 and (totalEvents % 5000 == 0 or forceSegment) then
        writeManifest(false)
    end

    flushing = false
    updateStatus()
    return success
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
    eventCounts[eventName] = (eventCounts[eventName] or 0) + 1

    local row = {
        seq = sequence,
        unix_ms = getTimestampMillis(),
        time_local = os.date("%Y-%m-%d %H:%M:%S"),
        time_utc = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        elapsed_s = math.floor((os.clock() - startedClock) * 1000) / 1000,
        event = eventName,
        tags = data and data.path and classifyPath(data.path) or nil,
        data = normalize(data or {}),
    }

    local ok, encoded = pcall(function()
        return HttpService:JSONEncode(row)
    end)
    if not ok then
        droppedEvents = droppedEvents + 1
        local fallback = {
            seq = sequence,
            unix_ms = getTimestampMillis(),
            elapsed_s = math.floor((os.clock() - startedClock) * 1000) / 1000,
            event = "encode_error",
            data = { failed_event = eventName, error = truncateString(encoded, 500) },
        }
        local fallbackOk, fallbackEncoded = pcall(function()
            return HttpService:JSONEncode(fallback)
        end)
        if fallbackOk then
            encoded = fallbackEncoded
        else
            return
        end
    end

    table.insert(queue, encoded)
    if #queue >= CONFIG.FLUSH_BATCH_EVENTS then
        flushRequested = true
    end
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

local function connectSignal(instance, signalName, callback, bucket)
    local ok, signal = pcall(function()
        return instance[signalName]
    end)
    if not ok or not signal then
        return nil
    end
    local connected, connection = pcall(function()
        return signal:Connect(callback)
    end)
    if connected then
        if bucket == "ui" then
            addUiConnection(connection)
        else
            addConnection(connection)
        end
        return connection
    end
    return nil
end

local function shouldSkipInstance(instance)
    if not instance then
        return true
    end
    if gui and safeDescendantOf(instance, gui) then
        return true
    end
    return false
end

local function isRelevantInstance(instance)
    if not instance or shouldSkipInstance(instance) then
        return false
    end

    if instance == LocalPlayer or safeDescendantOf(instance, LocalPlayer) then
        return true
    end

    local character = LocalPlayer.Character
    if character and safeDescendantOf(instance, character) then
        return true
    end

    local className = safeClass(instance)
    if className == "Humanoid" or className == "ProximityPrompt" or className == "ClickDetector" or className == "Tool" then
        return true
    end

    if className == "RemoteEvent" or className == "RemoteFunction" then
        return true
    end

    return pathContainsAny(safePath(instance), MECHANIC_WORDS)
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

local function propertiesFor(instance)
    local props = { "Name", "ClassName" }
    local function add(list)
        for _, property in ipairs(list) do
            table.insert(props, property)
        end
    end

    if safeIsA(instance, "GuiObject") then
        add({
            "Visible", "Active", "Selectable", "Position", "Size", "AbsolutePosition",
            "AbsoluteSize", "AnchorPoint", "Rotation", "ZIndex", "LayoutOrder",
            "BackgroundColor3", "BackgroundTransparency", "BorderColor3", "BorderSizePixel",
            "ClipsDescendants",
        })
    end

    if safeIsA(instance, "LayerCollector") then
        add({ "Enabled", "DisplayOrder", "ZIndexBehavior" })
    end

    if safeIsA(instance, "TextLabel") or safeIsA(instance, "TextButton") or safeIsA(instance, "TextBox") then
        add({
            "Text", "TextColor3", "TextTransparency", "TextStrokeColor3", "TextStrokeTransparency",
            "TextSize", "TextScaled", "TextWrapped", "RichText", "Font", "TextXAlignment",
            "TextYAlignment", "PlaceholderText",
        })
    end

    if safeIsA(instance, "ImageLabel") or safeIsA(instance, "ImageButton") then
        add({ "Image", "ImageColor3", "ImageTransparency", "ImageRectOffset", "ImageRectSize", "ScaleType" })
    end

    if safeIsA(instance, "UIStroke") then
        add({ "Color", "Thickness", "Transparency", "Enabled" })
    end
    if safeIsA(instance, "UIGradient") then
        add({ "Color", "Transparency", "Rotation", "Offset", "Enabled" })
    end
    if safeIsA(instance, "UIScale") then
        add({ "Scale" })
    end
    if safeIsA(instance, "ValueBase") then
        add({ "Value" })
    end

    if safeIsA(instance, "BasePart") then
        local path = safePath(instance)
        local character = LocalPlayer.Character
        local inCharacter = character and safeDescendantOf(instance, character)
        if inCharacter or pathContainsAny(path, {
            "npc", "boss", "herb", "quest", "merchant", "event", "trial", "cultivation",
            "spawn", "resource", "drop", "zone", "training", "weight", "item", "chest",
        }) then
            add({ "CFrame", "Position", "Orientation", "Size", "Anchored", "CanCollide", "Transparency", "Color", "Material" })
        end
    end

    if safeIsA(instance, "Model") then
        add({ "PrimaryPart", "WorldPivot" })
    end

    if safeIsA(instance, "Humanoid") then
        add({
            "Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight", "UseJumpPower",
            "HipHeight", "Sit", "PlatformStand", "MoveDirection", "FloorMaterial", "AutoRotate",
            "RigType", "DisplayName",
        })
    end

    if safeIsA(instance, "Tool") then
        add({ "Enabled", "CanBeDropped", "RequiresHandle", "ToolTip" })
    end

    if safeIsA(instance, "ProximityPrompt") then
        add({
            "ActionText", "ObjectText", "Enabled", "HoldDuration", "MaxActivationDistance",
            "RequiresLineOfSight", "KeyboardKeyCode", "GamepadKeyCode", "ClickablePrompt",
        })
    end

    if safeIsA(instance, "ClickDetector") then
        add({ "MaxActivationDistance", "CursorIcon" })
    end

    if safeIsA(instance, "RemoteEvent") or safeIsA(instance, "RemoteFunction") then
        add({ "Name", "ClassName" })
    end

    local unique = {}
    local result = {}
    for _, property in ipairs(props) do
        if not unique[property] then
            unique[property] = true
            table.insert(result, property)
        end
    end
    return result
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
        return propertyName == "Health" or propertyName == "MaxHealth"
            or propertyName == "WalkSpeed" or propertyName == "JumpPower"
            or propertyName == "JumpHeight" or propertyName == "Sit"
            or propertyName == "PlatformStand" or propertyName == "MoveDirection"
            or propertyName == "FloorMaterial" or propertyName == "AutoRotate"
    end

    if safeIsA(instance, "LayerCollector") then
        return propertyName == "Enabled" or propertyName == "DisplayOrder"
    end

    if safeIsA(instance, "GuiObject") then
        local path = safePath(instance)
        if isTrialPath(path) then
            return propertyName == "Visible" or propertyName == "Position" or propertyName == "Size"
                or propertyName == "AbsolutePosition" or propertyName == "AbsoluteSize"
                or propertyName == "BackgroundColor3" or propertyName == "BackgroundTransparency"
                or propertyName == "ImageColor3" or propertyName == "ImageTransparency"
                or propertyName == "Rotation" or propertyName == "Text" or propertyName == "TextColor3"
                or propertyName == "TextTransparency" or propertyName == "TextSize"
                or propertyName == "Active" or propertyName == "Selectable"
        end
        return propertyName == "Visible" or propertyName == "Enabled" or propertyName == "Text"
            or propertyName == "TextColor3" or propertyName == "TextTransparency"
            or propertyName == "BackgroundColor3" or propertyName == "BackgroundTransparency"
            or propertyName == "ImageColor3" or propertyName == "ImageTransparency"
            or propertyName == "Active" or propertyName == "Selectable"
    end

    if safeIsA(instance, "ProximityPrompt") then
        return propertyName == "ActionText" or propertyName == "ObjectText"
            or propertyName == "Enabled" or propertyName == "HoldDuration"
            or propertyName == "MaxActivationDistance" or propertyName == "RequiresLineOfSight"
    end

    if safeIsA(instance, "ClickDetector") then
        return propertyName == "MaxActivationDistance" or propertyName == "CursorIcon"
    end

    if safeIsA(instance, "Tool") then
        return propertyName == "Enabled" or propertyName == "ToolTip"
    end

    return false
end

local function packArguments(...)
    local count = select("#", ...)
    local values = {}
    local limit = math.min(count, 50)
    for index = 1, limit do
        values[index] = normalize(select(index, ...))
    end
    return { n = count, values = values, truncated = count > limit }
end

local function logButtonEvent(instance, eventName, extra)
    emit(eventName, {
        path = safePath(instance),
        class = safeClass(instance),
        name = safeGet(instance, "Name"),
        text = safeGet(instance, "Text"),
        visible = safeGet(instance, "Visible"),
        extra = extra or {},
    })
end

local function remoteShouldLog(remote)
    if CONFIG.LOG_ALL_INBOUND_REMOTES then
        return true
    end
    return CONFIG.LOG_RELEVANT_INBOUND_REMOTES and pathContainsAny(safePath(remote), REMOTE_WORDS)
end

local recordInstance

local function registerEntityFromHumanoid(humanoid)
    local model = safeGet(humanoid, "Parent")
    if not model or not safeIsA(model, "Model") then
        return
    end

    if not tracked[model] then
        recordInstance(model, "entity_model", true)
    end

    local rootNames = { "HumanoidRootPart", "PrimaryPart", "Head", "Torso", "UpperTorso" }
    for _, name in ipairs(rootNames) do
        local part = safeGet(model, name)
        if part and safeIsA(part, "BasePart") and not tracked[part] then
            recordInstance(part, "entity_part", true)
        end
    end
end

recordInstance = function(instance, origin, force)
    if not running or shouldSkipInstance(instance) or tracked[instance] then
        return
    end
    if not force and not isRelevantInstance(instance) then
        return
    end

    tracked[instance] = true
    totalInstances = totalInstances + 1

    local path = safePath(instance)
    local className = safeClass(instance)
    local attributes = getAttributes(instance)

    if isTrialPath(path) and not trialSet[instance] then
        trialSet[instance] = true
        table.insert(trialObjects, instance)
    end

    local isInitialOrigin = string.find(tostring(origin or ""), "initial", 1, true) == 1
    emit(isInitialOrigin and "instance_snapshot" or "instance_added", {
        origin = origin,
        path = path,
        class = className,
        name = safeGet(instance, "Name"),
        parent = safePath(safeGet(instance, "Parent")),
        properties = snapshotProperties(instance),
        attributes = attributes,
        tags = getTags(instance),
        mechanic_tags = classifyPath(path),
    })

    if shouldWatchChanged(instance) then
        connectSignal(instance, "Changed", function(changed)
            local propertyName
            if safeIsA(instance, "ValueBase") then
                propertyName = "Value"
            elseif type(changed) == "string" then
                propertyName = changed
            else
                return
            end
            if not shouldLogPropertyChange(instance, propertyName) then
                return
            end
            emit("property_changed", {
                path = safePath(instance),
                class = className,
                property = propertyName,
                value = safeGet(instance, propertyName),
            })
        end)
    end

    local characterForAttributes = LocalPlayer.Character
    local shouldWatchAttributes = next(attributes) ~= nil
        or safeDescendantOf(instance, LocalPlayer)
        or (characterForAttributes and safeDescendantOf(instance, characterForAttributes))
        or pathContainsAny(path, MECHANIC_WORDS)
        or safeIsA(instance, "Humanoid")
    if shouldWatchAttributes then
        connectSignal(instance, "AttributeChanged", function(attributeName)
            local attributeValue = nil
            local attributeOk, attributeResult = pcall(function()
                return instance:GetAttribute(attributeName)
            end)
            if attributeOk then
                attributeValue = attributeResult
            end
            emit("attribute_changed", {
                path = safePath(instance),
                class = className,
                attribute = attributeName,
                value = attributeValue,
            })
        end)
    end

    if safeIsA(instance, "RemoteEvent") then
        emit("remote_discovered", { path = path, class = className, name = safeGet(instance, "Name") })
        if remoteShouldLog(instance) then
            connectSignal(instance, "OnClientEvent", function(...)
                emit("remote_inbound", {
                    remote = safePath(instance),
                    arguments = packArguments(...),
                })
            end)
        end
    elseif safeIsA(instance, "RemoteFunction") then
        emit("remote_discovered", { path = path, class = className, name = safeGet(instance, "Name"), inbound_callback = "not_hooked" })
    end

    if safeIsA(instance, "BindableEvent") and pathContainsAny(path, MECHANIC_WORDS) then
        connectSignal(instance, "Event", function(...)
            emit("bindable_event", { path = safePath(instance), arguments = packArguments(...) })
        end)
    end

    if safeIsA(instance, "GuiButton") then
        connectSignal(instance, "Activated", function(inputObject, clickCount)
            logButtonEvent(instance, "gui_button_activated", {
                input_type = inputObject and tostring(safeGet(inputObject, "UserInputType")) or nil,
                key_code = inputObject and tostring(safeGet(inputObject, "KeyCode")) or nil,
                click_count = clickCount,
            })
        end)
        connectSignal(instance, "MouseButton2Click", function()
            logButtonEvent(instance, "gui_button_mouse2_click")
        end)
    end

    if safeIsA(instance, "ProximityPrompt") then
        local promptSignals = {
            "PromptButtonHoldBegan", "PromptButtonHoldEnded", "Triggered",
            "TriggerEnded", "PromptShown", "PromptHidden",
        }
        for _, signalName in ipairs(promptSignals) do
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

    if safeIsA(instance, "Tool") then
        for _, signalName in ipairs({ "Activated", "Deactivated", "Equipped", "Unequipped" }) do
            connectSignal(instance, signalName, function(...)
                emit("tool_" .. string.lower(signalName), { path = safePath(instance), arguments = packArguments(...) })
            end)
        end
    end

    if safeIsA(instance, "ProximityPrompt") or safeIsA(instance, "ClickDetector") then
        local parentPart = safeGet(instance, "Parent")
        if parentPart and safeIsA(parentPart, "BasePart") then
            if not tracked[parentPart] then
                recordInstance(parentPart, "interactable_parent", true)
            end
            local model = parentPart:FindFirstAncestorOfClass("Model")
            if model and not tracked[model] then
                recordInstance(model, "interactable_model", true)
            end
        end
    end

    if safeIsA(instance, "Humanoid") then
        connectSignal(instance, "Died", function()
            emit("humanoid_died", { path = safePath(instance), model = safePath(safeGet(instance, "Parent")) })
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
        registerEntityFromHumanoid(instance)
    end
end

local function getInputDetails(inputObject, processed)
    local inputType = inputObject and safeGet(inputObject, "UserInputType")
    local keyCode = inputObject and safeGet(inputObject, "KeyCode")
    local data = {
        user_input_type = inputType and tostring(inputType) or nil,
        key_code = keyCode and tostring(keyCode) or nil,
        position = inputObject and normalize(safeGet(inputObject, "Position")) or nil,
        processed = processed == true,
    }

    if inputObject then
        local state = safeGet(inputObject, "UserInputState")
        data.user_input_state = state and tostring(state) or nil
    end

    if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.MouseButton2 then
        local locationOk, location = pcall(function()
            return UserInputService:GetMouseLocation()
        end)
        if locationOk then
            data.mouse_location = normalize(location)
        end
        local mouseOk, mouse = pcall(function()
            return LocalPlayer:GetMouse()
        end)
        if mouseOk and mouse then
            data.mouse_target = normalize(safeGet(mouse, "Target"))
            data.mouse_hit = normalize(safeGet(mouse, "Hit"))
        end
    end

    return data
end

local function connectGlobalSignals()
    addConnection(game.DescendantAdded:Connect(function(instance)
        if isRelevantInstance(instance) then
            recordInstance(instance, "live")
        end
    end))

    addConnection(game.DescendantRemoving:Connect(function(instance)
        if tracked[instance] then
            emit("instance_removing", {
                path = safePath(instance),
                class = safeClass(instance),
                name = safeGet(instance, "Name"),
                parent = safePath(safeGet(instance, "Parent")),
                properties = snapshotProperties(instance),
            })
        end
    end))

    addConnection(UserInputService.InputBegan:Connect(function(inputObject, processed)
        if UserInputService:GetFocusedTextBox() then
            return
        end
        emit("input_began", getInputDetails(inputObject, processed))
    end))

    addConnection(UserInputService.InputEnded:Connect(function(inputObject, processed)
        if UserInputService:GetFocusedTextBox() then
            return
        end
        emit("input_ended", getInputDetails(inputObject, processed))
    end))

    addConnection(Players.PlayerAdded:Connect(function(player)
        emit("player_added", { name = player.Name, user_id = player.UserId, display_name = player.DisplayName })
    end))

    addConnection(Players.PlayerRemoving:Connect(function(player)
        emit("player_removing", { name = player.Name, user_id = player.UserId })
    end))

    addConnection(LocalPlayer.CharacterAdded:Connect(function(character)
        emit("local_character_added", { path = safePath(character), name = character.Name })
        recordInstance(character, "character_added", true)
        for _, descendant in ipairs(character:GetDescendants()) do
            recordInstance(descendant, "character_added", true)
        end
    end))

    addConnection(LocalPlayer.CharacterRemoving:Connect(function(character)
        emit("local_character_removing", { path = safePath(character), name = character.Name })
    end))
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
        BackgroundColor3 = color,
        BorderSizePixel = 0,
        Active = true,
        Selectable = false,
        AutoButtonColor = true,
        Font = Enum.Font.GothamBold,
        Text = text,
        TextColor3 = Color3.fromRGB(238, 242, 249),
        TextSize = 10,
    }, parent)
    roundUi(button, 6)
    return button
end

local function createUi()
    gui = makeUiObject("ScreenGui", {
        Name = "CU_FullSessionRecorder_v13",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 20,
    }, getGuiParent())
    sharedEnv.__CURecorderGui = gui

    local main = makeUiObject("Frame", {
        Name = "Main",
        Position = UDim2.new(1, -400, 0, 12),
        Size = UDim2.fromOffset(388, 126),
        BackgroundColor3 = Color3.fromRGB(17, 21, 29),
        BackgroundTransparency = 0.08,
        BorderSizePixel = 0,
        Active = false,
        Selectable = false,
    }, gui)
    roundUi(main, 9)

    local header = makeUiObject("TextLabel", {
        Position = UDim2.fromOffset(10, 6),
        Size = UDim2.new(1, -20, 0, 20),
        BackgroundTransparency = 1,
        Active = false,
        Font = Enum.Font.GothamBold,
        Text = "CULTIVATION UNBOUND | SESSION RECORDER v1.3",
        TextColor3 = Color3.fromRGB(238, 242, 249),
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, main)

    ui.status = makeUiObject("TextLabel", {
        Position = UDim2.fromOffset(10, 30),
        Size = UDim2.new(1, -20, 0, 20),
        BackgroundTransparency = 1,
        Active = false,
        Font = Enum.Font.GothamBold,
        Text = "CHECKING STORAGE...",
        TextColor3 = Color3.fromRGB(117, 214, 153),
        TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, main)

    ui.path = makeUiObject("TextLabel", {
        Position = UDim2.fromOffset(10, 51),
        Size = UDim2.new(1, -20, 0, 17),
        BackgroundTransparency = 1,
        Active = false,
        Font = Enum.Font.Code,
        Text = outputFolder .. "/" .. baseName,
        TextColor3 = Color3.fromRGB(164, 176, 195),
        TextSize = 8,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, main)

    local row = makeUiObject("Frame", {
        Position = UDim2.fromOffset(10, 82),
        Size = UDim2.new(1, -20, 0, 28),
        BackgroundTransparency = 1,
        Active = false,
    }, main)

    ui.pause = makeUiButton(row, "PAUSE", 0, 66, Color3.fromRGB(65, 77, 99))
    ui.flush = makeUiButton(row, "FLUSH", 72, 66, Color3.fromRGB(65, 77, 99))
    ui.export = makeUiButton(row, "EXPORT & STOP", 144, 112, Color3.fromRGB(54, 125, 91))
    ui.hide = makeUiButton(row, "HIDE", 262, 66, Color3.fromRGB(45, 53, 68))

    addUiConnection(ui.pause.MouseButton1Click:Connect(function()
        if not running then return end
        if paused then
            paused = false
            emit("recording_resumed", { reason = "ui_button" }, true)
            ui.pause.Text = "PAUSE"
        else
            emit("recording_paused", { reason = "ui_button" }, true)
            paused = true
            ui.pause.Text = "RESUME"
        end
        updateStatus()
    end))

    addUiConnection(ui.flush.MouseButton1Click:Connect(function()
        emit("manual_flush_requested", { queued = #queue }, true)
        flushQueue(true)
        updateStatus("manual flush")
    end))

    addUiConnection(ui.export.MouseButton1Click:Connect(function()
        if running then
            stopRecorder("export_button")
        end
    end))

    addUiConnection(ui.hide.MouseButton1Click:Connect(function()
        if gui then
            gui.Enabled = false
        end
    end))
end

local function trialIsActive()
    for _, instance in ipairs(trialObjects) do
        if instance and safeGet(instance, "Parent") then
            if safeIsA(instance, "GuiObject") and safeGet(instance, "Visible") == true and isEffectivelyVisible(instance) then
                return true
            end
            if safeIsA(instance, "LayerCollector") and safeGet(instance, "Enabled") == true then
                -- A visible child will confirm activity; this only keeps the root tracked.
            end
        end
    end
    return false
end

local TRIAL_SAMPLE_PROPERTIES = {
    "Visible", "Active", "Selectable", "Position", "Size", "AbsolutePosition", "AbsoluteSize",
    "BackgroundColor3", "BackgroundTransparency", "ImageColor3", "ImageTransparency", "Image",
    "Rotation", "Text", "TextColor3", "TextTransparency", "TextSize", "ZIndex",
    "Color", "Thickness", "Transparency", "Offset", "Scale", "Enabled",
}

local function sampleTrialFrame()
    if not running or paused then
        return
    end
    local now = os.clock()
    if now - lastTrialSample < (1 / CONFIG.TRIAL_SAMPLE_HZ) then
        return
    end
    lastTrialSample = now

    local active = trialIsActive()
    if now - lastTrialPrune >= 1 then
        lastTrialPrune = now
        for index = #trialObjects, 1, -1 do
            local instance = trialObjects[index]
            if not instance or not safeGet(instance, "Parent") then
                if instance then
                    trialSet[instance] = nil
                    trialSampleCache[instance] = nil
                end
                table.remove(trialObjects, index)
            end
        end
    end

    if active and not trialWasActive then
        trialWasActive = true
        trialFrame = 0
        emit("trial_ui_became_active", { tracked_objects = #trialObjects })
    elseif not active and trialWasActive then
        trialWasActive = false
        emit("trial_ui_became_inactive", { tracked_objects = #trialObjects })
    end

    if not active then
        return
    end

    trialFrame = trialFrame + 1
    for _, instance in ipairs(trialObjects) do
        if instance and safeGet(instance, "Parent") then
            local className = safeClass(instance)
            local isSampleClass = safeIsA(instance, "GuiObject")
                or className == "UIStroke" or className == "UIGradient" or className == "UIScale"
            if isSampleClass then
                local properties = {}
                for _, property in ipairs(TRIAL_SAMPLE_PROPERTIES) do
                    local value = safeGet(instance, property)
                    if value ~= nil then
                        properties[property] = normalize(value)
                    end
                end
                if next(properties) ~= nil then
                    local ok, signature = pcall(function()
                        return HttpService:JSONEncode(properties)
                    end)
                    if ok and trialSampleCache[instance] ~= signature then
                        trialSampleCache[instance] = signature
                        emit("trial_visual_sample", {
                            frame = trialFrame,
                            path = safePath(instance),
                            class = className,
                            properties = properties,
                        })
                    end
                end
            end
        end
    end
end

local function collectCheckpoint()
    local snapshot = {
        player = {
            name = LocalPlayer.Name,
            display_name = LocalPlayer.DisplayName,
            user_id = LocalPlayer.UserId,
            account_age_days = LocalPlayer.AccountAge,
            attributes = getAttributes(LocalPlayer),
        },
        values = {},
        gui_text = {},
        tools = {},
    }

    local descendants = {}
    local ok, result = pcall(function()
        return LocalPlayer:GetDescendants()
    end)
    if ok then
        descendants = result
    end

    for _, instance in ipairs(descendants) do
        if safeIsA(instance, "ValueBase") and #snapshot.values < 350 then
            table.insert(snapshot.values, {
                path = safePath(instance),
                class = safeClass(instance),
                value = safeGet(instance, "Value"),
            })
        elseif safeIsA(instance, "Tool") and #snapshot.tools < 100 then
            table.insert(snapshot.tools, {
                path = safePath(instance),
                name = safeGet(instance, "Name"),
                enabled = safeGet(instance, "Enabled"),
                tooltip = safeGet(instance, "ToolTip"),
            })
        elseif (safeIsA(instance, "TextLabel") or safeIsA(instance, "TextButton")) and #snapshot.gui_text < 450 then
            local text = safeGet(instance, "Text")
            local path = safePath(instance)
            if type(text) == "string" and text ~= "" and (pathContainsAny(path, MECHANIC_WORDS) or pathContainsAny(text, MECHANIC_WORDS)) then
                table.insert(snapshot.gui_text, {
                    path = path,
                    text = truncateString(text, 500),
                    visible = safeGet(instance, "Visible"),
                })
            end
        end
    end

    local character = LocalPlayer.Character
    if character then
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        local root = character:FindFirstChild("HumanoidRootPart")
        snapshot.character = {
            name = character.Name,
            humanoid = humanoid and {
                health = humanoid.Health,
                max_health = humanoid.MaxHealth,
                walk_speed = humanoid.WalkSpeed,
                jump_power = humanoid.JumpPower,
                state = tostring(humanoid:GetState()),
            } or nil,
            root_position = root and normalize(root.Position) or nil,
            root_cframe = root and normalize(root.CFrame) or nil,
        }
    end

    return snapshot
end

local function checkpoint()
    if not running or paused then
        return
    end
    local snapshot = collectCheckpoint()
    local ok, signature = pcall(function()
        return HttpService:JSONEncode(snapshot)
    end)
    if ok then
        if checkpointSignatures.last ~= signature then
            checkpointSignatures.last = signature
            emit("player_checkpoint", snapshot)
        else
            emit("checkpoint_heartbeat", { unchanged = true })
        end
    else
        emit("checkpoint_error", { error = tostring(signature) })
    end
end

local function sampleCharacterPosition()
    if not running or paused then
        return
    end
    local now = os.clock()
    if now - lastPositionSample < CONFIG.CHARACTER_POSITION_INTERVAL then
        return
    end
    lastPositionSample = now

    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root then
        return
    end

    local position = root.Position
    if not lastCharacterPosition or (position - lastCharacterPosition).Magnitude >= CONFIG.CHARACTER_POSITION_MIN_DELTA then
        lastCharacterPosition = position
        emit("character_position", {
            position = position,
            cframe = root.CFrame,
            velocity = root.AssemblyLinearVelocity,
        })
    end
end

local function scanInitial()
    local playerDescendants = {}
    local okPlayer, playerResult = pcall(function()
        return LocalPlayer:GetDescendants()
    end)
    if okPlayer then
        playerDescendants = playerResult
    end

    emit("initial_scan_started", {
        local_player_descendants = #playerDescendants,
        workspace_scan = "selective",
        replicated_storage_scan = "remote_metadata_and_relevant_paths",
    })

    for index, instance in ipairs(playerDescendants) do
        recordInstance(instance, "initial")
        if index % 400 == 0 then
            updateStatus("player snapshot " .. index .. "/" .. #playerDescendants)
            task.wait()
        end
    end
    recordInstance(LocalPlayer, "initial_root", true)

    local character = LocalPlayer.Character
    if character then
        recordInstance(character, "initial_character", true)
        local charDescendants = character:GetDescendants()
        for index, instance in ipairs(charDescendants) do
            recordInstance(instance, "initial_character")
            if index % 300 == 0 then
                task.wait()
            end
        end
    end

    local workspaceDescendants = {}
    local okWorkspace, workspaceResult = pcall(function()
        return workspace:GetDescendants()
    end)
    if okWorkspace then
        workspaceDescendants = workspaceResult
    end

    for index, instance in ipairs(workspaceDescendants) do
        if isRelevantInstance(instance) then
            recordInstance(instance, "initial_workspace")
        end
        if index % 1200 == 0 then
            updateStatus("world scan " .. index .. "/" .. #workspaceDescendants)
            task.wait()
        end
    end

    local replicatedDescendants = {}
    local okReplicated, replicatedResult = pcall(function()
        return ReplicatedStorage:GetDescendants()
    end)
    if okReplicated then
        replicatedDescendants = replicatedResult
    end
    for index, instance in ipairs(replicatedDescendants) do
        local className = safeClass(instance)
        if className == "RemoteEvent" or className == "RemoteFunction" or pathContainsAny(safePath(instance), MECHANIC_WORDS) then
            recordInstance(instance, "initial_replicated_storage", true)
        end
        if index % 600 == 0 then
            task.wait()
        end
    end

    local firstDescendants = {}
    local okFirst, firstResult = pcall(function()
        return ReplicatedFirst:GetDescendants()
    end)
    if okFirst then
        firstDescendants = firstResult
    end
    for index, instance in ipairs(firstDescendants) do
        local className = safeClass(instance)
        if className == "RemoteEvent" or className == "RemoteFunction" or pathContainsAny(safePath(instance), MECHANIC_WORDS) then
            recordInstance(instance, "initial_replicated_first", true)
        end
        if index % 600 == 0 then
            task.wait()
        end
    end

    emit("initial_scan_finished", {
        player_descendants = #playerDescendants,
        workspace_descendants_examined = #workspaceDescendants,
        replicated_storage_descendants_examined = #replicatedDescendants,
        replicated_first_descendants_examined = #firstDescendants,
        tracked_instances = totalInstances,
        trial_objects = #trialObjects,
    })
    initialScanComplete = true
end

local function stopRecorder(reason)
    if stopping or not running then
        return
    end
    stopping = true

    emit("session_stop", {
        reason = reason or "manual",
        total_events_before_stop = totalEvents,
        total_instances = totalInstances,
        elapsed_seconds = math.floor((os.clock() - startedClock) * 1000) / 1000,
        dropped_events = droppedEvents,
    }, true)

    running = false
    sharedEnv.__CURecorderStop = nil
    sharedEnv.__CURecorderNeedsFlush = nil

    for _, connection in ipairs(connections) do
        pcall(function() connection:Disconnect() end)
    end
    connections = {}
    for _, connection in ipairs(uiConnections) do
        pcall(function() connection:Disconnect() end)
    end
    uiConnections = {}

    while flushing do
        task.wait(0.05)
    end

    flushQueue(true)
    if storageMode == "segments" and segmentBuffer ~= "" then
        local content = segmentBuffer
        local ok, err = writeNewSegment(content)
        if ok then
            segmentBuffer = ""
        else
            storageError = "Final segment write failed: " .. tostring(err)
        end
    end

    writeManifest(true)

    local saved = storageMode == "append" or (storageMode == "segments" and #partPaths > 0)
    local message = saved and "EXPORTED - upload every part + manifest" or "EXPORT FAILED - check executor file APIs"
    updateStatus(message)

    if ui.export then
        pcall(function()
            ui.export.Text = saved and "EXPORTED" or "NO FILE"
            ui.export.Active = false
        end)
    end
    if ui.pause then
        pcall(function()
            ui.pause.Text = "STOPPED"
            ui.pause.Active = false
        end)
    end

    warn("[CU Recorder] Stopped. Events=" .. tostring(totalEvents)
        .. " Instances=" .. tostring(totalInstances)
        .. " Parts=" .. tostring(#partPaths)
        .. " Bytes=" .. tostring(totalBytes))
    warn("[CU Recorder] Output folder: " .. tostring(outputFolder))
    warn("[CU Recorder] Manifest: " .. tostring(manifestPath))
    if storageError then
        warn("[CU Recorder] Storage note: " .. tostring(storageError))
    end
end

sharedEnv.__CURecorderStop = stopRecorder

local function togglePause(reason)
    if not running then
        return
    end
    if paused then
        paused = false
        emit("recording_resumed", { reason = reason or "hotkey" }, true)
        if ui.pause then ui.pause.Text = "PAUSE" end
    else
        emit("recording_paused", { reason = reason or "hotkey" }, true)
        paused = true
        if ui.pause then ui.pause.Text = "RESUME" end
    end
    updateStatus()
end

local function connectHotkeys()
    addConnection(UserInputService.InputBegan:Connect(function(inputObject, processed)
        if processed or UserInputService:GetFocusedTextBox() then
            return
        end
        local key = safeGet(inputObject, "KeyCode")
        local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
            or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
        if not ctrl then
            return
        end
        if key == Enum.KeyCode.Home then
            if gui then gui.Enabled = not gui.Enabled end
        elseif key == Enum.KeyCode.End then
            stopRecorder("emergency_hotkey")
        elseif key == Enum.KeyCode.P then
            togglePause("hotkey")
        elseif key == Enum.KeyCode.F then
            emit("manual_flush_requested", { queued = #queue }, true)
            flushQueue(true)
        end
    end))
end

local function main()
    local uiOk, uiError = pcall(createUi)
    if not uiOk then
        warn("[CU Recorder] GUI creation failed: " .. tostring(uiError))
    end

    local storageOk = initializeStorage()
    if not storageOk then
        if ui.status then
            ui.status.Text = "STORAGE UNAVAILABLE - RECORDING NOT STARTED"
            ui.status.TextColor3 = Color3.fromRGB(235, 110, 110)
        end
        warn("[CU Recorder] " .. tostring(storageError))
        running = false
        sharedEnv.__CURecorderStop = nil
        return
    end

    emit("session_start", {
        recorder = "Cultivation Unbound Full Session Recorder",
        version = "1.3",
        place_id = game.PlaceId,
        game_id = game.GameId,
        job_id = game.JobId,
        creator_id = game.CreatorId,
        player_name = LocalPlayer.Name,
        display_name = LocalPlayer.DisplayName,
        user_id = LocalPlayer.UserId,
        account_age_days = LocalPlayer.AccountAge,
        started_unix = startedUnix,
        output_folder = outputFolder,
        manifest_path = manifestPath,
        storage_mode = storageMode,
        config = CONFIG,
        capability = {
            inbound_remote_events = CONFIG.LOG_RELEVANT_INBOUND_REMOTES or CONFIG.LOG_ALL_INBOUND_REMOTES,
            outbound_remote_events = false,
            outbound_remote_reason = "No namecall/metamethod hook installed; avoided to protect input and game stability",
            mouse_move_logging = false,
            chat_content_logging = false,
        },
    })

    connectGlobalSignals()
    connectHotkeys()

    task.spawn(function()
        while running do
            task.wait(CONFIG.FLUSH_INTERVAL)
            if #queue > 0 or flushRequested then
                flushRequested = false
                flushQueue(false)
            elseif storageMode == "segments" and segmentBuffer ~= "" and os.clock() - segmentLastWrite >= CONFIG.WRITEFILE_SEGMENT_SECONDS then
                flushQueue(false)
            end
            updateStatus()
        end
    end)

    task.spawn(function()
        while running do
            task.wait(CONFIG.CHECKPOINT_INTERVAL)
            if running and not paused then
                checkpoint()
                writeManifest(false)
            end
        end
    end)

    addConnection(RunService.RenderStepped:Connect(function()
        if running and not paused then
            sampleTrialFrame()
        end
    end))

    addConnection(RunService.Heartbeat:Connect(function()
        if running and not paused then
            sampleCharacterPosition()
        end
    end))

    scanInitial()
    checkpoint()
    updateStatus("initial scan complete")

    print("[CU Recorder] v1.3 recording active")
    print("[CU Recorder] Folder: " .. tostring(outputFolder))
    print("[CU Recorder] Manifest: " .. tostring(manifestPath))
    print("[CU Recorder] Storage: " .. tostring(storageMode))
    print("[CU Recorder] Ctrl+Home show/hide | Ctrl+P pause | Ctrl+F flush | Ctrl+End export/stop")
    print("[CU Recorder] Read-only: no clicks, remote firing, stat edits or movement")
end

main()
