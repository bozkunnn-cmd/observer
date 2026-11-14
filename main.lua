--[[
    CULTIVATION UNBOUND - AUTO CULTIVATION + ECONOMY
    Version: 1.0.8.3.1

    Built on the user's working Auto Breakthrough v0.2.

    FEATURES
      - Qi Auto Cultivation: select best eligible Qi zone, teleport, meditate.
      - Body Auto Cultivation: select best eligible Body zone, teleport, push-ups.
      - Re-evaluate the best zone after realm breakthroughs.
      - Preserve the working BreakthroughBanner and ordinary tribulation Tap logic.
      - Heavenly Tribulation: detect its live title, track the contracting white
        timing ring against the gold target, press SPACE near alignment, and lock
        other automation until the event and Qi progression update finish.
      - Heavenly Tribulation cadence is every fifth displayed Qi realm; detection
        uses the live event title rather than assuming internal realm numbering.
      - Ordinary tribulation processing does not require a readable hit counter.
      - Anti-AFK toggle using LocalPlayer.Idled / VirtualUser.
      - Auto Herb Collection: scans enabled CollectHerbPrompt objects in both
        normal HerbSpots and SpiritWorld.Herbs folders; reads HerbYear and
        prioritizes oldest age first, with optional species filters.
      - Holds the real 2.5-second collection prompt and verifies the result.
      - Temporarily pauses cultivation during a herb sweep, then resumes.
      - Auto Brew: exact recipe validation, independently selectable 1/10/100/1000-year ingredient ages,
        no fallback to disabled ages, timed Stoke, and verified automatic claiming.
      - Chest automation and Chest Teleport retired in v1.0.6 after the experience
        explicitly banned a direct chest teleport. No chest travel or opening runs.
      - Herb age filters: independently select 1/10/100/1000-year herbs, including a 1000-year-only preset;
        when no matching herb exists, cultivation remains active and the scanner watches for respawns.
      - Herb Monitor: live age counts split between normal and SpiritWorld nodes,
        including disabled/locked prompt counts.
      - Economy dashboard: Silver and Primordial Stone balances, NPC Silver rewards,
        session deltas, and Destiny reroll probability/cost estimates.
      - Auto Sell at Merchant Gao: per-species/per-age ALL or exact quantity,
        SELL ALL EXCEPT 1,000-year preset, Alchemy reserve protection, and
        inventory + Silver confirmation after every transaction.
      - Silver combat, Auto Silver, and Immortal Inheritance retired in v1.0.6.
      - Experiments page and chest interaction probes removed; core diagnostics retained.
      - Redesigned tabs: Overview, Cultivation, Farming, Alchemy, Economy, Settings, Diagnostics.
      - Integrated bounded diagnostics for cultivation progress, server confirmations, and errors.
      - Persistent settings saved to CU_AutoCultivation_Settings.json and restored on auto-execute.
      - Auto Hop when no 1,000-year herbs remain: requires strict 1k-only filter,
        confirms no eligible 1k prompt is currently available, waits a grace period,
        then uses the existing public Server Hop and restores saved settings after arrival.
      - Private-server rejoin targets the current live JobId; public Server Hop selects another public instance.
      - Settings are saved before travel; executor Auto Execute must be enabled to reload them after arrival.

    IMPORTANT
      - No RemoteEvent:FireServer calls.
      - No chest or Inheritance automation is present in the active UI or background loops.
      - No Auto Silver combat or target scan runs in this version.
      - Zone activation is checked against replicated zone multipliers before
        the script starts meditation or push-ups.
      - Qi and Body auto modes are mutually exclusive because one character
        can only run one selected cultivation activity at a time.
      - Private rejoin can target only the current live private-server JobId. A PrivateServerId is not a join access code and cannot revive a closed VIP instance by itself.
      - Public Server Hop uses the executor HTTP request API and Roblox's public server listing endpoint.
      - A disconnected client cannot execute its own reconnect code; Auto Execute only runs after Roblox has successfully joined a server.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local VirtualUser = game:GetService("VirtualUser")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    warn("[CU AutoCultivation] LocalPlayer unavailable.")
    return
end

local Env = _G
if type(getgenv) == "function" then
    local ok, result = pcall(getgenv)
    if ok and type(result) == "table" then
        Env = result
    end
end

-- A prior v1.0.2 outbound hook cannot be safely unhooked from this session,
-- but its callback can be disabled. Rejoin once after upgrading to clear the
-- old executor __namecall wrapper completely.
if type(Env.__CUOutboundRemoteAudit) == "table" then
    Env.__CUOutboundRemoteAudit.enabled = false
    Env.__CUOutboundRemoteAudit.callback = nil
end

if type(Env.__CUAutoCultivationStop) == "function" then
    pcall(Env.__CUAutoCultivationStop, "replaced")
end
if type(Env.__CUAutoBreakthroughStop) == "function" then
    pcall(Env.__CUAutoBreakthroughStop, "replaced by v0.9.1")
end

local running = true
local paused = false
local breakthroughEnabled = true
local antiAfkEnabled = true
local autoHerbsEnabled = false
local autoBrewEnabled = false
local autoBrewBusy = false
local autoBrewTaskRunning = false
local CHEST = {
    autoEnabled = false,
    taskRunning = false,
    busy = false,
    teleportActive = false,
    teleportReturnCFrame = nil,
    teleportResumeMode = nil,
    teleportTargetSpot = nil,
    teleportTargetPrompt = nil,
    openedCount = 0,
    failedCount = 0,
    activeName = "idle",
    returnCFrame = nil,
    resumeMode = nil,
    pendingManualResume = nil,
    attemptTimes = setmetatable({}, {__mode = "k"}),
    openedByScript = setmetatable({}, {__mode = "k"}),
    worldOpenedRevision = 0,
    lastWorldOpened = nil,
    tierSelection = {Celestial = true, Jade = true, Bronze = true, Wooden = true},
    tierOrder = {Celestial = 4, Jade = 3, Bronze = 2, Wooden = 1},
}
local INHERITANCE = {
    autoEnabled = false,
    active = false,
    busy = false,
    taskRunning = false,
    state = "unknown",
    holder = nil,
    progress = 0,
    position = nil,
    radius = 50,
    endsAt = nil,
    winner = nil,
    lastEventKey = nil,
    attemptedEventKey = nil,
    returnCFrame = nil,
    resumeMode = nil,
    resumeWasAuto = false,
    claimEnteredAt = nil,
    activeName = "waiting for event",
}
local HERB_MONITOR = {ageCounts = nil, lastScanAt = 0, ageOptions = {1000, 100, 10, 1}, ageSelection = {[1] = true, [10] = true, [100] = true, [1000] = true}}
local HERB_HOP = {
    enabled = false,
    graceSeconds = 60,
    emptySince = nil,
    lastCountAt = 0,
    lastAvailableCount = nil,
    nextAttemptAt = 0,
    status = "OFF",
}
local QUICK_INTERACT = {enabled = false, chestEnabled = false, attempts = 0, successes = 0, fallbacks = 0}
local EXPERIMENT = {
    remoteAuditEnabled = false,
    remoteAuditInstalled = false,
    remoteAuditStatus = "Not installed",
    remoteAuditCount = 0,
    progressProbeEnabled = false,
    rerollClickCount = 0,
    rerollResultCount = 0,
    remoteAuditShared = nil,
}

-- Currency tracking is passive: values come from player attributes and the
-- game's inbound UpdateMoney / UpdatePrimordialStones events.
local ECONOMY = {
    silver = tonumber(LocalPlayer:GetAttribute("Silver")),
    stones = tonumber(LocalPlayer:GetAttribute("PrimordialStones")),
    silverStart = tonumber(LocalPlayer:GetAttribute("Silver")),
    stonesStart = tonumber(LocalPlayer:GetAttribute("PrimordialStones")),
    silverNetChange = 0,
    npcSilverEarned = 0,
    npcKillCount = 0,
    stonesEarned = 0,
    lastStoneDelta = 0,
    lastStoneChangeAt = nil,
    lastStoneChangeClock = nil,
    startedAt = os.clock(),
}
local SILVER = {
    autoEnabled = false, -- retired in v1.0.6; no UI or runner is exposed
    taskRunning = false,
    busy = false,
    activeName = "idle",
    currentTarget = nil,
    currentTargetRealm = nil,
    kills = 0,
    earned = 0,
    failed = 0,
    lastReward = 0,
    lastTargetAt = 0,
    autoDrawEnabled = false,
    tAttemptedCharacter = nil,
    targetMode = "SAFE", -- SAFE chooses the weakest eligible non-boss camp NPC.
    attackInterval = 0.18,
    clickHold = 0.045,
    retreatHealthFraction = 0.35,
    returnCFrame = nil,
    blacklist = setmetatable({}, {__mode = "k"}),
}
-- Multiple pill recipes can be queued. Qi + Body are enabled by default.
local brewRecipeSelection = {
    QiSpeed = true,
    BodySpeed = true,
    Damage = false,
    HP = false,
}
local brewRecipeCursor = 1
local brewAgeSelection = {[1] = true, [10] = true, [100] = true, [1000] = true}
local BREW_AGE_OPTIONS = {1, 10, 100, 1000}
local cauldronState = nil
local cauldronStartResult = nil
local cauldronStartZone = nil
local cauldronStokeResult = nil
local cauldronBrewComplete = nil
local cauldronClaimResult = nil
local cauldronBrewSerial = 0
local cauldronStokeHandledSerial = -1
local lastStokeClickAt = 0
local lastStokeRoot = nil
local cauldronPillInventoryRevision = 0
local cauldronLastTier = nil
local herbCollectorBusy = false
local herbCollectorTaskRunning = false
local herbAttemptTimes = setmetatable({}, {__mode = "k"})
local herbCollectedPrompts = setmetatable({}, {__mode = "k"})
local herbCollectedCount = 0
local herbFailedCount = 0
local herbInventoryRevision = 0
local herbCounts = nil
local herbReturnCFrame = nil
local herbResumeMode = nil
local herbActiveName = "idle"
local AUTO_SELL = {
    enabled = false,
    busy = false,
    sellNowRequested = false,
    status = "OFF",
    soldCount = 0,
    silverEarned = 0,
    lastSilver = tonumber(LocalPlayer:GetAttribute("Silver")),
    config = {},
}
for herbId = 1, 5 do
    for _, age in ipairs({1, 10, 100, 1000}) do
        AUTO_SELL.config[tostring(herbId) .. "_" .. tostring(age)] = {
            enabled = false, mode = "ALL", amount = 0,
        }
    end
end
local herbFilterButton = nil
local UI = {chestFilterToggleButtons = {}, pages = {}, tabs = {}, herbAgeFilterToggleButtons = {}, settingsStatusLabel = nil, privateRejoinButton = nil, serverHopButton = nil, autoHopNo1kButton = nil, autoSellButton = nil, autoSellNowButton = nil, autoSellConfigButton = nil, autoSellStatusLabel = nil, autoSellPicker = nil, autoSellRows = {}}
local herbFilterPicker = nil
local herbFilterToggleButtons = {}
local HERB_SPECIES = {"Ginseng", "Azure Lotus", "Verdant Moss", "Golden Fern", "Violet Sage"}
local HERB_TYPE_NAMES = {[1] = "Ginseng", [2] = "Azure Lotus", [3] = "Verdant Moss", [4] = "Golden Fern", [5] = "Violet Sage"}
local herbSpeciesSelection = {
    ["Ginseng"] = true,
    ["Azure Lotus"] = true,
    ["Verdant Moss"] = true,
    ["Golden Fern"] = true,
    ["Violet Sage"] = true,
}
local autoStartedTrainingMode = nil
local selectedAutoMode = nil -- nil, "Qi", or "Body"
local connections = {}

local qiState = nil
local bodyState = nil

local activeTrialGui = nil
local attemptedPrompts = {}
local previousRingSizes = {}
local lastTrialText = "Trial: idle"
local lastTrialScoreText = nil

-- Heavenly Tribulation (every fifth displayed Qi realm). The game displays this
-- as a separate timing event: press SPACE when the contracting white ring meets
-- the fixed gold circle. Detection is UI-driven; if the ring objects cannot be
-- identified confidently, the controller waits instead of guessing or spamming.
UI.heavenly = {
    active = false,
    titleObject = nil,
    uiRoot = nil,
    lastTitleScanAt = 0,
    lastSeenAt = 0,
    scanAt = 0,
    whiteRing = nil,
    goldTarget = nil,
    ringSource = "none",
    previousRatio = nil,
    previousSampleAt = 0,
    pulseConsumed = false,
    ringLostAt = 0,
    inputBusy = false,
    lastInputAt = 0,
    successfulInputs = 0,
    failedInputs = 0,
    startedAt = 0,
    lastNoPairLogAt = 0,
    pairDetected = false,
    lastFeedback = nil,
    feedbackValue = nil,
    feedbackScanAt = 0,
    ratioSamples = {},
    pulseSerial = 0,
    lastPulseStartAt = 0,
    retryNotBefore = 0,
    timingLead = 0.020,
    lastInputRatio = nil,
    awaitingFeedback = false,
    feedbackHandledPulse = 0,
}

local lastMode = "Unknown"
local lastPercent = nil
local lastSignature = nil
local lastAction = "Starting..."
local lastError = ""

local breakthroughMode = nil
local breakthroughSignature = nil
local breakthroughAttempts = 0
local lastBreakthroughTryAt = 0
local breakthroughTrialSeen = false
local breakthroughWaitForProgressReset = false

local teleporting = false
local lastTeleportAt = 0
local lastTeleportTarget = nil
local trainingToggleAt = 0
local trainingToggleAttempts = 0
local lastAutoCheckAt = 0

local gui = nil
local panel = nil
local modeLabel = nil
local progressLabel = nil
local zoneLabel = nil
local statusLabel = nil
local trialLabel = nil
local qiButton = nil
local bodyButton = nil
local breakthroughButton = nil
local antiAfkButton = nil
local herbButton = nil
local herbInfoLabel = nil
local brewButton = nil
local brewRecipeButton = nil
local brewRecipePicker = nil
local brewRecipeToggleButtons = {}
UI.brewAgeFilterButton = nil
UI.brewAgeFilterPicker = nil
UI.brewAgeFilterToggleButtons = {}
local pauseButton = nil
local updateModeButtons = nil
local footerStatusLabel = nil

UI.setPanelVisible = function(visible)
    if panel then panel.Visible = visible end
    if UI.restoreButton then UI.restoreButton.Visible = not visible end
end

local COLORS = {
    bg = Color3.fromRGB(17, 20, 28),
    panel = Color3.fromRGB(27, 32, 43),
    panel2 = Color3.fromRGB(36, 43, 57),
    text = Color3.fromRGB(235, 239, 247),
    muted = Color3.fromRGB(157, 169, 188),
    qi = Color3.fromRGB(105, 190, 255),
    body = Color3.fromRGB(255, 177, 112),
    accent = Color3.fromRGB(145, 130, 255),
    success = Color3.fromRGB(112, 211, 151),
    warning = Color3.fromRGB(245, 190, 91),
    danger = Color3.fromRGB(226, 91, 102),
}

-- Verified from the user's in-game zone scanner reports.
-- Required realm numbers correspond to the game's replicated realm/bodyRealm fields.
local ZONES = {
    Qi = {
        {name = "Verdant Valley", realm = 1, multiplier = 1.50, x = -190.00, y = 5.57, z = 120.00, size = 67},
        {name = "Misty Peaks", realm = 5, multiplier = 1.75, x = -1100.00, y = 112.48, z = 250.00, size = 104},
        {name = "Thunder Sanctum", realm = 9, multiplier = 2.00, x = 1300.00, y = 163.25, z = -450.00, size = 104},
        {name = "Celestial Expanse", realm = 13, multiplier = 2.25, x = 700.00, y = 152.48, z = 1450.00, size = 104},
        {name = "Shattered Heavens", realm = 17, multiplier = 2.50, x = -1520.00, y = 182.50, z = -650.00, size = 104},
        {name = "Dao Pinnacle", realm = 21, multiplier = 2.75, x = 195.00, y = 1002.50, z = -750.00, size = 97},
        {name = "Shattered Sky", realm = 25, multiplier = 3.00, x = -100.00, y = 732.68, z = -1150.00, size = 149},
    },
    Body = {
        {name = "Dusty Courtyard", realm = 1, multiplier = 1.50, x = 150.00, y = 5.50, z = 40.00, size = 91},
        {name = "Iron Fist Dojo", realm = 3, multiplier = 1.75, x = 790.00, y = 11.90, z = 330.00, size = 104},
        {name = "Stone Peak Arena", realm = 6, multiplier = 2.00, x = 1500.00, y = 8.61, z = 650.00, size = 117},
        {name = "Jade Colosseum", realm = 9, multiplier = 2.25, x = -700.00, y = 40.55, z = 1500.00, size = 123},
        {name = "Dragon Spine Ridge", realm = 12, multiplier = 2.50, x = 1520.00, y = 342.20, z = -1150.00, size = 104},
        {name = "Heaven's Forge", realm = 16, multiplier = 2.75, x = 1250.00, y = 8.69, z = 1450.00, size = 110},
        {name = "Immortal Crucible", realm = 20, multiplier = 3.00, x = -1480.00, y = 90.88, z = 1280.00, size = 117},
    },
}

-- Exact recipe labels recovered from the live CauldronGui.
-- Herb IDs: 1 Ginseng, 2 Azure Lotus, 3 Verdant Moss, 4 Golden Fern, 5 Violet Sage.
local BREW_RECIPES = {
    QiSpeed = {
        name = "Qi Cultivation Pill",
        short = "QI",
        ingredients = {
            {id = 1, name = "Ginseng", count = 2},
            {id = 2, name = "Azure Lotus", count = 1},
        },
    },
    BodySpeed = {
        name = "Body Cultivation Pill",
        short = "BODY",
        ingredients = {
            {id = 3, name = "Verdant Moss", count = 2},
            {id = 4, name = "Golden Fern", count = 1},
        },
    },
    Damage = {
        name = "Bloodfury Pill",
        short = "BLOOD",
        ingredients = {
            {id = 2, name = "Azure Lotus", count = 1},
            {id = 4, name = "Golden Fern", count = 1},
            {id = 5, name = "Violet Sage", count = 1},
        },
    },
    HP = {
        name = "Vitality Pill",
        short = "VITAL",
        ingredients = {
            {id = 1, name = "Ginseng", count = 1},
            {id = 3, name = "Verdant Moss", count = 1},
            {id = 5, name = "Violet Sage", count = 1},
        },
    },
}
local BREW_RECIPE_ORDER = {"QiSpeed", "BodySpeed", "Damage", "HP"}
local BREW_AGE_ORDER = {1000, 100, 10, 1}

local function addConnection(signal, callback)
    local ok, connection = pcall(function()
        return signal:Connect(callback)
    end)
    if ok and connection then
        table.insert(connections, connection)
        return connection
    end
    return nil
end

local function disconnectAll()
    for _, connection in ipairs(connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    table.clear(connections)
end

local function setStatus(message, color)
    lastAction = tostring(message or "")
    if statusLabel then
        statusLabel.Text = lastAction
        statusLabel.TextColor3 = color or COLORS.muted
    end
    if footerStatusLabel then
        footerStatusLabel.Text = lastAction
        footerStatusLabel.TextColor3 = color or COLORS.muted
    end
end


-- Integrated diagnostics: bounded, passive, and limited to this suite's modules.
-- It observes inbound server confirmations and local action outcomes; it never
-- fabricates or fires reward, reroll, combat, or progression remotes.
local DIAG = {
    enabled = true,
    events = {},
    sequence = 0,
    maxEvents = 1200,
    errorCount = 0,
    warningCount = 0,
    lastRefresh = 0,
    lastFlush = 0,
    fileName = "CU_AutoCultivation_Diagnostics_" .. os.date("%Y%m%d_%H%M%S") .. ".jsonl",
    progressSamples = {},
    lastZoneByMode = {},
    lastTrainingState = {},
    rewardFingerprints = {},
    progressRates = {
        Qi = {uiPercentPerSecond = 0, rawPerSecond = 0, zoneMultiplier = nil},
        Body = {uiPercentPerSecond = 0, rawPerSecond = 0, zoneMultiplier = nil},
    },
    rerollWatched = setmetatable({}, {__mode = "k"}),
}

local function diagClean(value, depth, seen)
    depth = depth or 0
    seen = seen or {}
    local kind = typeof(value)
    if kind == "Instance" then
        local ok, fullName = pcall(function() return value:GetFullName() end)
        return {type = "Instance", class = value.ClassName, path = ok and fullName or value.Name}
    elseif kind == "Vector2" then
        return {type = "Vector2", x = value.X, y = value.Y}
    elseif kind == "Vector3" then
        return {type = "Vector3", x = value.X, y = value.Y, z = value.Z}
    elseif kind == "Color3" then
        return {type = "Color3", r = value.R, g = value.G, b = value.B}
    elseif kind == "CFrame" then
        return {type = "CFrame", components = {value:GetComponents()}}
    elseif kind == "EnumItem" then
        return tostring(value)
    end
    if type(value) == "string" then return string.sub(value, 1, 500) end
    if type(value) == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return tostring(value) end
        return value
    end
    if type(value) == "boolean" or value == nil then return value end
    if type(value) == "table" then
        if depth >= 4 then return "[max-depth]" end
        if seen[value] then return "[cycle]" end
        seen[value] = true
        local out, count = {}, 0
        for k, v in pairs(value) do
            count = count + 1
            if count > 50 then out.truncated = true break end
            out[tostring(k)] = diagClean(v, depth + 1, seen)
        end
        seen[value] = nil
        return out
    end
    return tostring(value)
end

DIAG.log = function(level, moduleName, eventName, data)
    if not DIAG.enabled then return end
    DIAG.sequence = DIAG.sequence + 1
    if moduleName == "RNG" and eventName == "manual_reroll_click" then EXPERIMENT.rerollClickCount = EXPERIMENT.rerollClickCount + 1 end
    if moduleName == "RNG" and eventName == "server_reroll_result" then EXPERIMENT.rerollResultCount = EXPERIMENT.rerollResultCount + 1 end
    local row = {
        seq = DIAG.sequence,
        unix_ms = DateTime.now().UnixTimestampMillis,
        elapsed = math.floor((os.clock() - ECONOMY.startedAt) * 1000) / 1000,
        level = tostring(level or "INFO"),
        module = tostring(moduleName or "SYSTEM"),
        event = tostring(eventName or "event"),
        data = diagClean(data or {}, 0, {}),
    }
    table.insert(DIAG.events, row)
    if #DIAG.events > DIAG.maxEvents then table.remove(DIAG.events, 1) end
    if row.level == "ERROR" then DIAG.errorCount = DIAG.errorCount + 1 end
    if row.level == "WARN" then DIAG.warningCount = DIAG.warningCount + 1 end
    DIAG.lastEvent = row
    DIAG.refreshUI(false)
end

local SETTINGS = {file = "CU_AutoCultivation_Settings.json", schema = 1, status = "No saved settings loaded", loaded = false, restoreReady = false}
local REJOIN = {
    busy = false,
    recentServers = {},
    status = "ready",
    lastPrivateServerId = nil,
    lastPrivateJobId = nil,
}

do
    local function getExecutorFunction(name)
        local candidate = nil
        pcall(function() candidate = Env[name] end)
        if type(candidate) ~= "function" then
            pcall(function() candidate = _G[name] end)
        end
        return type(candidate) == "function" and candidate or nil
    end

    local function loadSettings()
        local read = getExecutorFunction("readfile")
        if not read then
            SETTINGS.status = "Executor readfile unavailable; using defaults"
            return false
        end
        local ok, raw = pcall(read, SETTINGS.file)
        if not ok or type(raw) ~= "string" or raw == "" then
            SETTINGS.status = "No saved settings file; using defaults"
            return false
        end
        local decodeOk, data = pcall(function() return HttpService:JSONDecode(raw) end)
        if not decodeOk or type(data) ~= "table" then
            SETTINGS.status = "Saved settings file is invalid; using defaults"
            return false
        end
        if tonumber(data.placeId) ~= game.PlaceId then
            SETTINGS.status = "Saved settings belong to another place; using defaults"
            return false
        end

        selectedAutoMode = (data.selectedAutoMode == "Qi" or data.selectedAutoMode == "Body") and data.selectedAutoMode or nil
        if type(data.breakthroughEnabled) == "boolean" then breakthroughEnabled = data.breakthroughEnabled end
        if type(data.antiAfkEnabled) == "boolean" then antiAfkEnabled = data.antiAfkEnabled end
        if type(data.autoHerbsEnabled) == "boolean" then autoHerbsEnabled = data.autoHerbsEnabled end
        if type(data.quickInteractEnabled) == "boolean" then QUICK_INTERACT.enabled = data.quickInteractEnabled end
        if type(data.autoBrewEnabled) == "boolean" then autoBrewEnabled = data.autoBrewEnabled end
        if type(data.autoHopNo1kHerbs) == "boolean" then HERB_HOP.enabled = data.autoHopNo1kHerbs end
        local hopGrace = tonumber(data.autoHopGraceSeconds)
        if hopGrace then HERB_HOP.graceSeconds = math.clamp(math.floor(hopGrace), 30, 300) end

        if type(data.herbAgeSelection) == "table" then
            for _, age in ipairs({1, 10, 100, 1000}) do
                local value = data.herbAgeSelection[tostring(age)]
                if type(value) == "boolean" then HERB_MONITOR.ageSelection[age] = value end
            end
        end
        if type(data.herbSpeciesSelection) == "table" then
            for _, species in ipairs(HERB_SPECIES) do
                local value = data.herbSpeciesSelection[species]
                if type(value) == "boolean" then herbSpeciesSelection[species] = value end
            end
        end
        if type(data.brewRecipeSelection) == "table" then
            for key in pairs(brewRecipeSelection) do
                local value = data.brewRecipeSelection[key]
                if type(value) == "boolean" then brewRecipeSelection[key] = value end
            end
        end
        if type(data.brewAgeSelection) == "table" then
            for _, age in ipairs(BREW_AGE_OPTIONS) do
                local value = data.brewAgeSelection[tostring(age)]
                if type(value) == "boolean" then brewAgeSelection[age] = value end
            end
        end
        if type(data.autoSellEnabled) == "boolean" then AUTO_SELL.enabled = data.autoSellEnabled end
        if type(data.autoSellConfig) == "table" then
            for key, saved in pairs(data.autoSellConfig) do
                if type(saved) == "table" and AUTO_SELL.config[key] then
                    AUTO_SELL.config[key].enabled = saved.enabled == true
                    AUTO_SELL.config[key].mode = saved.mode == "COUNT" and "COUNT" or "ALL"
                    AUTO_SELL.config[key].amount = math.max(0, math.floor(tonumber(saved.amount) or 0))
                end
            end
        end
        local cursor = tonumber(data.brewRecipeCursor)
        if cursor and cursor >= 1 and cursor <= #BREW_RECIPE_ORDER then brewRecipeCursor = math.floor(cursor) end
        if type(data.recentPublicServers) == "table" then REJOIN.recentServers = data.recentPublicServers end

        SETTINGS.loaded = true
        SETTINGS.status = "Restored saved settings | " .. os.date("%H:%M:%S")
        return true
    end

    SETTINGS.save = function(reason)
        local write = getExecutorFunction("writefile")
        if not write then
            SETTINGS.status = "Executor writefile unavailable; settings not persisted"
            if UI.settingsStatusLabel then UI.settingsStatusLabel.Text = SETTINGS.status end
            return false, SETTINGS.status
        end
        local data = {
            schema = SETTINGS.schema,
            version = "1.0.8.3.1",
            placeId = game.PlaceId,
            savedAt = os.time(),
            reason = tostring(reason or "setting_changed"),
            selectedAutoMode = selectedAutoMode,
            breakthroughEnabled = breakthroughEnabled,
            antiAfkEnabled = antiAfkEnabled,
            autoHerbsEnabled = autoHerbsEnabled,
            herbAgeSelection = {
                ["1"] = HERB_MONITOR.ageSelection[1] == true,
                ["10"] = HERB_MONITOR.ageSelection[10] == true,
                ["100"] = HERB_MONITOR.ageSelection[100] == true,
                ["1000"] = HERB_MONITOR.ageSelection[1000] == true,
            },
            herbSpeciesSelection = {},
            quickInteractEnabled = QUICK_INTERACT.enabled == true,
            autoBrewEnabled = autoBrewEnabled == true,
            autoSellEnabled = AUTO_SELL.enabled == true,
            autoSellConfig = AUTO_SELL.config,
            autoHopNo1kHerbs = HERB_HOP.enabled == true,
            autoHopGraceSeconds = HERB_HOP.graceSeconds,
            brewRecipeSelection = {},
            brewAgeSelection = {
                ["1"] = brewAgeSelection[1] == true,
                ["10"] = brewAgeSelection[10] == true,
                ["100"] = brewAgeSelection[100] == true,
                ["1000"] = brewAgeSelection[1000] == true,
            },
            brewRecipeCursor = brewRecipeCursor,
            recentPublicServers = REJOIN.recentServers,
            privateServerId = game.PrivateServerId,
            privateServerJobId = game.JobId,
        }
        for _, species in ipairs(HERB_SPECIES) do data.herbSpeciesSelection[species] = herbSpeciesSelection[species] == true end
        for key, enabled in pairs(brewRecipeSelection) do data.brewRecipeSelection[key] = enabled == true end

        local encodedOk, encoded = pcall(function() return HttpService:JSONEncode(data) end)
        if not encodedOk then
            SETTINGS.status = "Settings JSON encode failed: " .. tostring(encoded)
            if UI.settingsStatusLabel then UI.settingsStatusLabel.Text = SETTINGS.status end
            return false, SETTINGS.status
        end
        local ok, err = pcall(write, SETTINGS.file, encoded)
        if not ok then
            SETTINGS.status = "Settings save failed: " .. tostring(err)
            if UI.settingsStatusLabel then UI.settingsStatusLabel.Text = SETTINGS.status end
            DIAG.log("WARN", "SETTINGS", "save_failed", {reason = tostring(err)})
            return false, SETTINGS.status
        end
        SETTINGS.status = "Settings saved locally | " .. os.date("%H:%M:%S")
        if UI.settingsStatusLabel then UI.settingsStatusLabel.Text = SETTINGS.status end
        DIAG.log("INFO", "SETTINGS", "saved", {reason = tostring(reason or "setting_changed"), file = SETTINGS.file})
        return true, SETTINGS.status
    end

    SETTINGS.saveBeforeTravel = function(reason)
        local ok, message = SETTINGS.save(reason)
        if not ok then
            setStatus("Travel cancelled: settings could not be saved. " .. tostring(message), COLORS.danger)
            return false
        end
        return true
    end

    SETTINGS.load = loadSettings
    SETTINGS.load()
end

DIAG.refreshUI = function(force)
    if not UI.diagEventLabel then return end
    local now = os.clock()
    if not force and now - DIAG.lastRefresh < 0.45 then return end
    DIAG.lastRefresh = now
    local lines = {}
    local first = math.max(1, #DIAG.events - 11)
    for i = #DIAG.events, first, -1 do
        local row = DIAG.events[i]
        local timeText = os.date("%H:%M:%S", math.floor(row.unix_ms / 1000))
        local detail = ""
        if type(row.data) == "table" then
            detail = tostring(row.data.reason or row.data.result or row.data.status or row.data.target or row.data.prompt or "")
        end
        table.insert(lines, string.format("[%s] %s/%s: %s", timeText, row.module, row.event, string.sub(detail, 1, 70)))
    end
    if #lines == 0 then table.insert(lines, "No automation events recorded yet.") end
    UI.diagEventLabel.Text = table.concat(lines, "\n")
    if UI.diagSummaryLabel then
        UI.diagSummaryLabel.Text = string.format(
            "Observer ON | Events %d/%d | Warnings %d | Errors %d | Quick %s (%d/%d) | Remote audit %s",
            #DIAG.events, DIAG.maxEvents, DIAG.warningCount, DIAG.errorCount,
            (QUICK_INTERACT.enabled or QUICK_INTERACT.chestEnabled) and "ON" or "OFF", QUICK_INTERACT.successes, QUICK_INTERACT.attempts,
            EXPERIMENT.remoteAuditEnabled and "ON" or "OFF"
        )
    end
    if UI.remoteAuditStatusLabel then
        UI.remoteAuditStatusLabel.Text = EXPERIMENT.remoteAuditStatus .. " | Captured: " .. tostring(EXPERIMENT.remoteAuditCount)
    end
    if UI.rngSampleLabel then
        UI.rngSampleLabel.Text = "Manual reroll clicks: " .. tostring(EXPERIMENT.rerollClickCount) .. "\nServer results: " .. tostring(EXPERIMENT.rerollResultCount)
    end
    if UI.diagProgressLabel then
        local q = DIAG.progressRates.Qi
        local b = DIAG.progressRates.Body
        UI.diagProgressLabel.Text = string.format(
            "Qi UI %.3f%%/s | raw qi %.1f/s | zone %.2fx\nBody UI %.3f%%/s | raw EXP %.1f/s | zone %.2fx",
            q.uiPercentPerSecond or 0, q.rawPerSecond or 0, q.zoneMultiplier or 0,
            b.uiPercentPerSecond or 0, b.rawPerSecond or 0, b.zoneMultiplier or 0
        )
    end
end

DIAG.export = function()
    local lines = {}
    for _, row in ipairs(DIAG.events) do
        local ok, encoded = pcall(function() return HttpService:JSONEncode(row) end)
        if ok then table.insert(lines, encoded) end
    end
    local content = table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
    if type(writefile) == "function" then
        local ok, err = pcall(writefile, DIAG.fileName, content)
        if ok then
            DIAG.log("INFO", "DIAGNOSTICS", "exported", {file = DIAG.fileName, events = #DIAG.events})
            if UI.diagSummaryLabel then UI.diagSummaryLabel.Text = "Exported " .. tostring(#DIAG.events) .. " events: " .. DIAG.fileName end
            return true, DIAG.fileName
        end
        if type(setclipboard) == "function" then pcall(setclipboard, content) end
        return false, tostring(err)
    end
    if type(setclipboard) == "function" then
        local ok = pcall(setclipboard, content)
        return ok, ok and "copied to clipboard" or "clipboard failed"
    end
    print("[CU Diagnostics] No writefile/setclipboard API. Recent events:")
    for _, row in ipairs(DIAG.events) do print(row.seq, row.module, row.event) end
    return false, "executor has no file or clipboard API"
end

DIAG.flush = function()
    if type(writefile) ~= "function" then return false end
    local now = os.clock()
    if now - DIAG.lastFlush < 8 then return true end
    DIAG.lastFlush = now
    local lines = {}
    for _, row in ipairs(DIAG.events) do
        local ok, encoded = pcall(function() return HttpService:JSONEncode(row) end)
        if ok then table.insert(lines, encoded) end
    end
    return pcall(writefile, DIAG.fileName, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
end

ECONOMY.formatNumber = function(value)
    value = tonumber(value)
    if not value then return "--" end
    local sign = value < 0 and "-" or ""
    local n = math.floor(math.abs(value) + 0.5)
    local text = tostring(n)
    local result = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if string.sub(result, 1, 1) == "," then result = string.sub(result, 2) end
    return sign .. result
end

ECONOMY.updateUI = function()
    local elapsedMinutes = math.max(0.01, (os.clock() - ECONOMY.startedAt) / 60)
    local silverRate = ECONOMY.npcSilverEarned / elapsedMinutes
    if UI.currencySilverLabel then UI.currencySilverLabel.Text = "Silver  " .. ECONOMY.formatNumber(ECONOMY.silver) end
    if UI.currencyStoneLabel then UI.currencyStoneLabel.Text = "Primordial Stones  " .. ECONOMY.formatNumber(ECONOMY.stones) end
    if UI.economySilverDetail then
        UI.economySilverDetail.Text = "NPC Silver earned this session: " .. ECONOMY.formatNumber(ECONOMY.npcSilverEarned) .. "  |  NPC kill rewards: " .. tostring(ECONOMY.npcKillCount)
    end
    if UI.economyRateDetail then
        UI.economyRateDetail.Text = "Observed NPC reward rate: " .. ECONOMY.formatNumber(silverRate) .. " Silver/min (session average)"
    end
    if UI.economyStoneDetail then
        local changeText = "Source unverified. Prior recording showed two +1 updates about 10m10s apart; a timed reward is only a hypothesis."
        if ECONOMY.lastStoneChangeAt then
            local delta = ECONOMY.lastStoneDelta
            changeText = "Last balance update: " .. (delta >= 0 and "+" or "") .. tostring(delta) .. " at " .. os.date("%H:%M:%S", ECONOMY.lastStoneChangeAt) .. " | source not identified"
        end
        UI.economyStoneDetail.Text = changeText
    end
    if UI.overviewSilverLabel then UI.overviewSilverLabel.Text = ECONOMY.formatNumber(ECONOMY.silver) end
    if UI.overviewStoneLabel then UI.overviewStoneLabel.Text = ECONOMY.formatNumber(ECONOMY.stones) end
end

SILVER.setStatus = function(message)
    SILVER.activeName = tostring(message or "idle")
end

local function setHerbStatus(message)
    herbActiveName = tostring(message or "idle")
    if herbInfoLabel then
        herbInfoLabel.Text = string.format(
            "Herbs: %d collected | %s",
            herbCollectedCount,
            herbActiveName
        )
    end
end

CHEST.setStatus = function(message)
    CHEST.activeName = tostring(message or "idle")
end

local function stop(reason)
    if not running then
        return
    end
    DIAG.log("INFO", "SYSTEM", "stop", {reason = tostring(reason or "manual")})
    DIAG.export()
    running = false
    autoHerbsEnabled = false
    autoBrewEnabled = false
    autoBrewBusy = false
    AUTO_SELL.enabled = false
    AUTO_SELL.sellNowRequested = false
    AUTO_SELL.status = "Stopped"
    selectedAutoMode = nil
    breakthroughEnabled = false
    antiAfkEnabled = false
    QUICK_INTERACT.enabled = false
    if SETTINGS.save then SETTINGS.save("stop_all") end
    CHEST.autoEnabled = false
    INHERITANCE.autoEnabled = false
    SILVER.autoEnabled = false
    SILVER.busy = false
    EXPERIMENT.remoteAuditEnabled = false
    if EXPERIMENT.remoteAuditShared then
        EXPERIMENT.remoteAuditShared.enabled = false
        EXPERIMENT.remoteAuditShared.callback = nil
    end
    disconnectAll()
    if gui then
        pcall(function()
            gui:Destroy()
        end)
        gui = nil
    end
    Env.__CUAutoCultivationStop = nil
    Env.__CUAutoCultivationState = nil
    Env.__CUAutoBreakthroughStop = nil
    Env.__CUAutoBreakthroughState = nil
    print("[CU AutoCultivation] Stopped: " .. tostring(reason or "manual"))
end

Env.__CUAutoCultivationStop = stop
Env.__CUAutoBreakthroughStop = stop
Env.__CUAutoCultivationState = {
    getStatus = function()
        return {
            running = running,
            paused = paused,
            autoMode = selectedAutoMode,
            breakthroughEnabled = breakthroughEnabled,
            antiAfkEnabled = antiAfkEnabled,
            quickInteractEnabled = QUICK_INTERACT.enabled,
            quickChestProbeEnabled = QUICK_INTERACT.chestEnabled,
            remoteAuditEnabled = EXPERIMENT.remoteAuditEnabled,
            remoteAuditStatus = EXPERIMENT.remoteAuditStatus,
            remoteAuditCount = EXPERIMENT.remoteAuditCount,
            diagnosticsEnabled = DIAG.enabled,
            diagnosticEvents = #DIAG.events,
            diagnosticErrors = DIAG.errorCount,
            diagnosticWarnings = DIAG.warningCount,
            autoHerbsEnabled = autoHerbsEnabled,
            herbAgeSelection = { [1] = HERB_MONITOR.ageSelection[1], [10] = HERB_MONITOR.ageSelection[10], [100] = HERB_MONITOR.ageSelection[100], [1000] = HERB_MONITOR.ageSelection[1000] },
            chestTeleportActive = CHEST.teleportActive,
            autoBrewEnabled = autoBrewEnabled,
            autoBrewBusy = autoBrewBusy,
            brewAgeSelection = { [1] = brewAgeSelection[1], [10] = brewAgeSelection[10], [100] = brewAgeSelection[100], [1000] = brewAgeSelection[1000] },
            autoChestEnabled = CHEST.autoEnabled,
            autoSilverEnabled = SILVER.autoEnabled,
            silverMode = "scan_only_no_mouse_input",
            autoDrawSwordEnabled = SILVER.autoDrawEnabled,
            autoInheritanceEnabled = INHERITANCE.autoEnabled,
            inheritanceActive = INHERITANCE.active,
            inheritanceBusy = INHERITANCE.busy,
            inheritanceState = INHERITANCE.state,
            inheritanceHolder = INHERITANCE.holder,
            inheritanceProgress = INHERITANCE.progress,
            silverBusy = SILVER.busy,
            silverKills = SILVER.kills,
            silverEarned = SILVER.earned,
            silverBalance = ECONOMY.silver,
            primordialStones = ECONOMY.stones,
            npcSilverEarned = ECONOMY.npcSilverEarned,
            chestCollectorBusy = CHEST.busy,
            chestsOpened = CHEST.openedCount,
            chestsFailed = CHEST.failedCount,
            chestTierSelection = {
                Celestial = CHEST.tierSelection.Celestial,
                Jade = CHEST.tierSelection.Jade,
                Bronze = CHEST.tierSelection.Bronze,
                Wooden = CHEST.tierSelection.Wooden,
            },
            herbAgeCounts = HERB_MONITOR.ageCounts,
            selectedBrewRecipes = {
                QiSpeed = brewRecipeSelection.QiSpeed,
                BodySpeed = brewRecipeSelection.BodySpeed,
                Damage = brewRecipeSelection.Damage,
                HP = brewRecipeSelection.HP,
            },
            herbCollectorBusy = herbCollectorBusy,
            herbsCollected = herbCollectedCount,
            herbsFailed = herbFailedCount,
            herbSpeciesSelection = {
                Ginseng = herbSpeciesSelection["Ginseng"],
                AzureLotus = herbSpeciesSelection["Azure Lotus"],
                VerdantMoss = herbSpeciesSelection["Verdant Moss"],
                GoldenFern = herbSpeciesSelection["Golden Fern"],
                VioletSage = herbSpeciesSelection["Violet Sage"],
            },
            autoStartedTrainingMode = autoStartedTrainingMode,
            mode = lastMode,
            percent = lastPercent,
            action = lastAction,
            trial = lastTrialText,
            heavenlyTribulationActive = UI.heavenly.active,
            heavenlySpaceInputs = UI.heavenly.successfulInputs,
            heavenlyInputFailures = UI.heavenly.failedInputs,
            error = lastError,
        }
    end,
    stop = stop,
}
Env.__CUAutoBreakthroughState = Env.__CUAutoCultivationState

local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local function cauldronPanelIsOpen()
    local cauldronGui = PlayerGui:FindFirstChild("CauldronGui")
    local cauldronPanel = cauldronGui and cauldronGui:FindFirstChild("CauldronPanel")
    return cauldronGui ~= nil and cauldronGui.Enabled == true
        and cauldronPanel ~= nil and cauldronPanel.Visible == true
end

local function make(className, properties, parent)
    local object = Instance.new(className)
    for property, value in pairs(properties or {}) do
        pcall(function()
            object[property] = value
        end)
    end
    object.Parent = parent
    return object
end

local function round(object, radius)
    make("UICorner", {
        CornerRadius = UDim.new(0, radius or 8),
    }, object)
end

local function getGuiParent()
    if type(gethui) == "function" then
        local ok, hidden = pcall(gethui)
        if ok and hidden then
            return hidden
        end
    end
    return PlayerGui
end

local function isVisibleInTree(object)
    local node = object
    while node and node ~= PlayerGui do
        if node:IsA("GuiObject") and not node.Visible then
            return false
        end
        if node:IsA("ScreenGui") and not node.Enabled then
            return false
        end
        node = node.Parent
    end
    return true
end

local function hasEnabledConnections(signal)
    if type(getconnections) ~= "function" then
        return false
    end
    local ok, list = pcall(getconnections, signal)
    if not ok or type(list) ~= "table" then
        return false
    end
    for _, connection in ipairs(list) do
        if connection.Enabled ~= false then
            return true
        end
    end
    return false
end

local function clickGuiButton(button)
    if not button or not button:IsA("GuiButton") then
        return false, "not a GuiButton"
    end
    if not button.Active or not isVisibleInTree(button) then
        return false, "button or parent is not visible/active"
    end
    if not button:IsDescendantOf(PlayerGui) then
        return false, "button is outside PlayerGui"
    end

    if button.Name == "BreakthroughBanner" then
        local parent = button.Parent
        if not parent or parent.Name ~= "BreakthroughRow" or button.Text ~= "Breakthrough" then
            return false, "BreakthroughBanner identity check failed"
        end
    end
    if button.Name == "Tap" then
        local seal = button.Parent
        local prompt = seal and seal.Parent
        if not seal or seal.Name ~= "Seal" or not prompt then
            return false, "Tribulation Tap identity check failed"
        end
    end

    if type(firesignal) == "function" and type(getconnections) == "function" then
        local mouseSignal = button.MouseButton1Click
        if hasEnabledConnections(mouseSignal) then
            local ok = pcall(firesignal, mouseSignal)
            if ok then
                return true, "direct MouseButton1Click signal"
            end
        end
        local activatedSignal = button.Activated
        if hasEnabledConnections(activatedSignal) then
            local ok = pcall(firesignal, activatedSignal)
            if ok then
                return true, "direct Activated signal"
            end
        end
    end

    local okActivate, activateError = pcall(function()
        button:Activate()
    end)
    if okActivate then
        return true, "GuiButton:Activate"
    end
    return false, tostring(activateError or "direct activation unavailable")
end

local function sendKey(keyCode)
    local vim
    local okService, service = pcall(function()
        return game:GetService("VirtualInputManager")
    end)
    if okService then
        vim = service
    end

    if vim then
        local ok = pcall(function()
            vim:SendKeyEvent(true, keyCode, false, game)
            task.wait(0.08)
            vim:SendKeyEvent(false, keyCode, false, game)
        end)
        if ok then
            return true, "VirtualInputManager"
        end
    end

    local vk = keyCode.Value
    if type(keypress) == "function" and type(keyrelease) == "function" then
        local ok = pcall(function()
            keypress(vk)
            task.wait(0.08)
            keyrelease(vk)
        end)
        if ok then
            return true, "executor keypress"
        end
    end

    return false, "no supported key-input method"
end

local function sendTimingKey(keyCode)
    local vim
    local okService, service = pcall(function()
        return game:GetService("VirtualInputManager")
    end)
    if okService then vim = service end

    if vim then
        local ok = pcall(function()
            vim:SendKeyEvent(true, keyCode, false, game)
            task.wait(0.025)
            vim:SendKeyEvent(false, keyCode, false, game)
        end)
        if ok then return true, "VirtualInputManager 25ms pulse" end
    end

    local vk = keyCode.Value
    if type(keypress) == "function" and type(keyrelease) == "function" then
        local ok = pcall(function()
            keypress(vk)
            task.wait(0.025)
            keyrelease(vk)
        end)
        if ok then return true, "executor keypress 25ms pulse" end
    end
    return false, "no supported short key-pulse method"
end

local function parsePercent(text)
    if type(text) ~= "string" then
        return nil
    end
    local number = string.match(text, "([%d%.]+)%s*%%")
    return tonumber(number)
end

local function getStatusPanel()
    local cultivationGui = PlayerGui:FindFirstChild("CultivationGui")
    return cultivationGui and cultivationGui:FindFirstChild("StatusPanel") or nil
end

local function getFrameForMode(mode)
    local statusPanel = getStatusPanel()
    if not statusPanel then
        return nil, nil
    end
    if mode == "Qi" then
        return statusPanel:FindFirstChild("MainFrame"), statusPanel
    end
    return statusPanel:FindFirstChild("BodyFrame"), statusPanel
end

local function getActiveMode()
    local statusPanel = getStatusPanel()
    if not statusPanel then
        return nil, nil, nil
    end

    local mainFrame = statusPanel:FindFirstChild("MainFrame")
    local bodyFrame = statusPanel:FindFirstChild("BodyFrame")

    if selectedAutoMode then
        return selectedAutoMode, selectedAutoMode == "Qi" and mainFrame or bodyFrame, statusPanel
    end

    local mainVisible = mainFrame and mainFrame.Visible
    local bodyVisible = bodyFrame and bodyFrame.Visible

    if mainVisible and not bodyVisible then
        return "Qi", mainFrame, statusPanel
    end
    if bodyVisible and not mainVisible then
        return "Body", bodyFrame, statusPanel
    end

    if qiState and qiState.isMeditating then
        return "Qi", mainFrame, statusPanel
    end
    if bodyState and bodyState.isPushingUp then
        return "Body", bodyFrame, statusPanel
    end

    if lastMode == "Qi" then
        return "Qi", mainFrame, statusPanel
    elseif lastMode == "Body" then
        return "Body", bodyFrame, statusPanel
    end

    return nil, nil, statusPanel
end

local function getModeProgress(mode, frame)
    if not frame then
        return nil, nil, nil
    end

    local label
    local realmLabel
    local layerLabel
    local block = frame:FindFirstChild("Block")
    local bar
    local fill

    if mode == "Qi" then
        label = frame:FindFirstChild("ProgressLabel")
        realmLabel = frame:FindFirstChild("RealmLabel")
        layerLabel = frame:FindFirstChild("LayerLabel")
        bar = block and block:FindFirstChild("QiBarFrame")
        fill = bar and bar:FindFirstChild("QiBarFill")
    else
        label = frame:FindFirstChild("BodyProgressLabel")
        realmLabel = frame:FindFirstChild("BodyRealmLabel")
        layerLabel = frame:FindFirstChild("BodyLayerLabel")
        bar = block and block:FindFirstChild("BodyBarFrame")
        fill = bar and bar:FindFirstChild("BodyBarFill")
    end

    local percentLabel = bar and bar:FindFirstChild("Percent")
    local percent = label and parsePercent(label.Text) or nil
    if percent == nil and percentLabel then
        percent = parsePercent(percentLabel.Text)
    end
    if percent == nil and fill then
        local ok, scale = pcall(function()
            return fill.Size.X.Scale
        end)
        if ok and type(scale) == "number" then
            percent = math.clamp(scale * 100, 0, 100)
        end
    end

    -- In the supplied recording the realm/layer text is Block.RealmLine,
    -- not a top-level RealmLabel/LayerLabel.
    local realmLine = block and block:FindFirstChild("RealmLine")
    local realmText = realmLine and realmLine.Text or (realmLabel and realmLabel.Text) or mode
    local layerText = layerLabel and layerLabel.Text or ""
    local state = mode == "Qi" and qiState or bodyState
    local realmNumber = mode == "Qi" and state and state.realm or state and state.bodyRealm
    local layerNumber = mode == "Qi" and state and state.layer or state and state.bodyLayer

    local signature = table.concat({
        mode,
        tostring(realmText),
        tostring(layerText),
        tostring(realmNumber or "?"),
        tostring(layerNumber or "?"),
    }, ":")

    return percent, signature, realmText
end


DIAG.sampleProgress = function()
    local mode, frame = getActiveMode()
    if not mode or not frame then return end
    local percent, signature = getModeProgress(mode, frame)
    local state
    if mode == "Qi" then state = qiState else state = bodyState end
    if type(state) ~= "table" then return end
    local rawValue, rawMax, zoneMultiplier
    if mode == "Qi" then
        rawValue = tonumber(state.qi)
        rawMax = tonumber(state.maxQi)
        zoneMultiplier = tonumber(state.zoneMultiplier)
    else
        rawValue = tonumber(state.bodyExp)
        rawMax = tonumber(state.maxBodyExp)
        zoneMultiplier = tonumber(state.bodyZoneMultiplier)
    end
    local active = mode == "Qi" and state.isMeditating == true or mode == "Body" and state.isPushingUp == true
    local speedText = nil
    for _, node in ipairs(frame:GetDescendants()) do
        if node:IsA("TextLabel") and string.find(string.lower(tostring(node.Text or "")), "speed", 1, true) then
            speedText = tostring(node.Text)
            break
        end
    end
    local now = os.clock()
    local previous = DIAG.progressSamples[mode]
    local uiRate, rawRate = 0, 0
    if previous and previous.signature == signature then
        local dt = math.max(0.05, now - previous.time)
        if percent ~= nil and previous.percent ~= nil then
            local delta = percent - previous.percent
            if delta >= 0 then uiRate = delta / dt end
        end
        if rawValue ~= nil and previous.rawValue ~= nil then
            local delta = rawValue - previous.rawValue
            if delta >= 0 then rawRate = delta / dt end
        end
    elseif previous then
        DIAG.log("INFO", "PROGRESS", "layer_or_realm_changed", {mode = mode, from = previous.signature, to = signature})
    end
    DIAG.progressSamples[mode] = {time = now, percent = percent, rawValue = rawValue, rawMax = rawMax, signature = signature}
    DIAG.progressRates[mode] = {
        uiPercentPerSecond = uiRate,
        rawPerSecond = rawRate,
        zoneMultiplier = zoneMultiplier,
    }
    if EXPERIMENT.progressProbeEnabled then
        DIAG.log("INFO", "PROGRESS", "rate_sample", {
            mode = mode, signature = signature, uiPercent = percent,
            uiPercentPerSecond = uiRate, rawValue = rawValue, rawMax = rawMax,
            rawPerSecond = rawRate, active = active,
            isMeditating = state.isMeditating, isPushingUp = state.isPushingUp,
            zone = state.currentZone or state.bodyCurrentZone, zoneMultiplier = zoneMultiplier,
            speedText = speedText, serverSpeedMultiplier = state.speedMultiplier or state.qiSpeedMultiplier or state.bodySpeedMultiplier,
            stoneMultiplier = state.stoneMultiplier, groupBonus = state.groupBonus,
            premiumBonus = state.premiumBonus, weightMultiplier = state.weightMultiplier,
        })
    end
    -- Flag only unusually large observed jumps for later review. This is a
    -- diagnostic hint, not proof of an exploit or a server validation flaw.
    if previous and previous.signature == signature and uiRate > 15 then
        DIAG.log("WARN", "PROGRESS", "large_ui_progress_jump_candidate", {mode = mode, rate = uiRate, signature = signature})
    end
    DIAG.refreshUI(true)
end

local function getScoreInfo(trialGui)
    local header = trialGui:FindFirstChild("TrialHeader", true)
    local scorePill = header and header:FindFirstChild("ScorePill", true)
    local scoreObject = scorePill and scorePill:FindFirstChild("Score", true)
    local scoreText = scoreObject and scoreObject.Text or nil

    if not scoreText then
        for _, descendant in ipairs(trialGui:GetDescendants()) do
            if descendant:IsA("TextLabel") then
                local value = descendant.Text
                if type(value) == "string" and string.match(value, "%d+%s*/%s*%d+") then
                    scoreText = value
                    break
                end
            end
        end
    end

    if type(scoreText) ~= "string" then
        return nil, nil, nil
    end
    local current, required = string.match(scoreText, "(%d+)%s*/%s*(%d+)")
    return tonumber(current), tonumber(required), scoreText
end

local function isTrialRootActive(candidate)
    if candidate:IsA("ScreenGui") then
        return candidate.Enabled
    end
    if candidate:IsA("GuiObject") then
        return candidate.Visible
    end
    return false
end

local function getActiveTrialGui()
    local names
    if lastMode == "Body" then
        names = {"BodyTrialGui", "BreakthroughMG"}
    else
        names = {"BreakthroughMG", "BodyTrialGui"}
    end

    for _, name in ipairs(names) do
        local candidate = PlayerGui:FindFirstChild(name)
        if candidate and isTrialRootActive(candidate) then
            if candidate:FindFirstChild("TrialHeader", true) then
                return candidate
            end
        end
    end

    for _, child in ipairs(PlayerGui:GetChildren()) do
        if child:IsA("ScreenGui") and child.Enabled and string.find(string.lower(child.Name), "trial") then
            if child:FindFirstChild("TrialHeader", true) then
                return child
            end
        end
    end
    return nil
end

local function getLatestPrompt(trialGui)
    local prompts = {}
    local function consider(object)
        local number = string.match(object.Name, "^Prompt(%d+)$")
        if number and (object:IsA("CanvasGroup") or object:IsA("Frame")) then
            table.insert(prompts, {number = tonumber(number), object = object})
        end
    end

    for _, child in ipairs(trialGui:GetChildren()) do
        consider(child)
    end

    if #prompts == 0 then
        for _, descendant in ipairs(trialGui:GetDescendants()) do
            consider(descendant)
        end
    end

    if #prompts == 0 then
        for _, descendant in ipairs(trialGui:GetDescendants()) do
            local ring = descendant:FindFirstChild("Ring")
            local seal = descendant:FindFirstChild("Seal")
            local isContainer = descendant:IsA("CanvasGroup") or descendant:IsA("Frame")
            if isContainer and ring and seal then
                local number = tonumber(string.match(descendant.Name, "%d+")) or (#prompts + 1)
                table.insert(prompts, {number = number, object = descendant})
            end
        end
    end

    table.sort(prompts, function(a, b)
        return a.number < b.number
    end)

    for index = #prompts, 1, -1 do
        local prompt = prompts[index].object
        if prompt.Visible then
            return prompts[index].number, prompt
        end
    end
    return nil, nil
end

local function isGold(color)
    if not color then
        return false
    end
    return color.R >= 0.90 and color.G >= 0.75 and color.B <= 0.65
end

-- Heavenly Tribulation detector ----------------------------------------------
-- The title/instruction is the authoritative active-state signal. The timing
-- rings are located by their visible circular UIStroke geometry, preferably in
-- the same ScreenGui/BillboardGui as the title, then on the character/camera.

UI.heavenly.findTitle = function()
    local now = os.clock()
    local cached = UI.heavenly.titleObject
    if cached and cached.Parent and (cached:IsA("TextLabel") or cached:IsA("TextButton")) then
        local text = string.upper(tostring(cached.Text or ""))
        if string.find(text, "HEAVENLY TRIBULATION", 1, true) and isVisibleInTree(cached) then
            return cached
        end
    end
    if now - UI.heavenly.lastTitleScanAt < 0.18 then
        return nil
    end
    UI.heavenly.lastTitleScanAt = now

    local roots = {PlayerGui, LocalPlayer.Character, Workspace.CurrentCamera}
    for _, root in ipairs(roots) do
        if root then
            local ok, descendants = pcall(function() return root:GetDescendants() end)
            if ok then
                for _, object in ipairs(descendants) do
                    if object:IsA("TextLabel") or object:IsA("TextButton") then
                        local text = string.upper(tostring(object.Text or ""))
                        if string.find(text, "HEAVENLY TRIBULATION", 1, true) and isVisibleInTree(object) then
                            UI.heavenly.titleObject = object
                            local node = object
                            while node and not node:IsA("ScreenGui") and not node:IsA("BillboardGui") and not node:IsA("SurfaceGui") do
                                node = node.Parent
                            end
                            UI.heavenly.uiRoot = node or root
                            return object
                        end
                    end
                end
            end
        end
    end
    UI.heavenly.titleObject = nil
    UI.heavenly.uiRoot = nil
    return nil
end

UI.heavenly.classifyRingColor = function(color)
    if not color then return nil end
    local r, g, b = color.R, color.G, color.B
    if r >= 0.76 and g >= 0.76 and b >= 0.76 and math.abs(r - g) <= 0.22 and math.abs(g - b) <= 0.22 then
        return "white"
    end
    if r >= 0.66 and g >= 0.38 and g <= 0.92 and b <= 0.42 and r > g then
        return "gold"
    end
    return nil
end

UI.heavenly.collectRingCandidates = function(root, out)
    if not root then return end
    local ok, descendants = pcall(function() return root:GetDescendants() end)
    if not ok then return end
    for _, object in ipairs(descendants) do
        if object:IsA("GuiObject") and object.Visible then
            local size = object.AbsoluteSize
            if size.X >= 18 and size.Y >= 18 and size.X <= 900 and size.Y <= 900 then
                local aspect = size.X / math.max(1, size.Y)
                if aspect >= 0.82 and aspect <= 1.22 then
                    local stroke = object:FindFirstChildOfClass("UIStroke")
                    local kind = nil
                    if stroke and stroke.Transparency <= 0.42 and stroke.Thickness >= 1 then
                        kind = UI.heavenly.classifyRingColor(stroke.Color)
                    end
                    if not kind and object:IsA("ImageLabel") and object.Image ~= "" and object.ImageTransparency <= 0.42 then
                        kind = UI.heavenly.classifyRingColor(object.ImageColor3)
                    end
                    if kind then
                            local pos = object.AbsolutePosition
                            table.insert(out, {
                                object = object,
                                kind = kind,
                                diameter = (size.X + size.Y) * 0.5,
                                center = Vector2.new(pos.X + size.X * 0.5, pos.Y + size.Y * 0.5),
                                parent = object.Parent,
                            })
                    end
                end
            end
        end
    end
end

UI.heavenly.findRingPair = function()
    local candidates = {}
    local roots, seen = {}, {}
    local function addRoot(root)
        if root and not seen[root] then
            seen[root] = true
            table.insert(roots, root)
        end
    end
    addRoot(PlayerGui)
    addRoot(UI.heavenly.uiRoot)
    addRoot(LocalPlayer.Character)
    addRoot(Workspace.CurrentCamera)

    for _, root in ipairs(roots) do
        UI.heavenly.collectRingCandidates(root, candidates)
    end

    local whiteCount, goldCount = 0, 0
    for _, candidate in ipairs(candidates) do
        if candidate.kind == "white" then whiteCount = whiteCount + 1 end
        if candidate.kind == "gold" then goldCount = goldCount + 1 end
    end
    local bestWhite, bestGold, bestScore = nil, nil, math.huge
    for _, white in ipairs(candidates) do
        if white.kind == "white" then
            for _, gold in ipairs(candidates) do
                if gold.kind == "gold" and white.diameter > gold.diameter * 1.12 then
                    local ratio = white.diameter / gold.diameter
                    if ratio <= 5.5 then
                        local centerDistance = (white.center - gold.center).Magnitude
                        local tolerance = math.max(16, gold.diameter * 0.16)
                        if centerDistance <= tolerance then
                            local parentPenalty = white.parent == gold.parent and 0 or 18
                            local score = centerDistance + parentPenalty + math.abs(ratio - 1.9) * 3
                            if score < bestScore then
                                bestWhite, bestGold, bestScore = white, gold, score
                            end
                        end
                    end
                end
            end
        end
    end

    if bestWhite and bestGold then
        return bestWhite.object, bestGold.object, "matched circular UIStroke pair"
    end
    return nil, nil, string.format("no matched pair (white=%d gold=%d candidates=%d)", whiteCount, goldCount, #candidates)
end

UI.heavenly.readFeedback = function()
    local now = os.clock()
    if now - UI.heavenly.feedbackScanAt < 0.04 then
        return UI.heavenly.feedbackValue
    end
    UI.heavenly.feedbackScanAt = now
    local roots = {UI.heavenly.uiRoot, PlayerGui}
    for _, root in ipairs(roots) do
        if root then
            local ok, descendants = pcall(function() return root:GetDescendants() end)
            if ok then
                for _, object in ipairs(descendants) do
                    if object:IsA("TextLabel") or object:IsA("TextButton") then
                        if object.Visible then
                            local value = string.upper(tostring(object.Text or ""))
                            if value == "PERFECT!" or value == "PERFECT" or value == "GOOD!" or value == "GOOD" or value == "MISS" or value == "FAILED" then
                                UI.heavenly.feedbackValue = value
                                return value
                            end
                        end
                    end
                end
            end
        end
    end
    UI.heavenly.feedbackValue = nil
    return nil
end

UI.heavenly.reset = function(reason)
    if UI.heavenly.active then
        DIAG.log("INFO", "HEAVENLY", "tribulation_ui_ended", {
            reason = reason or "title disappeared",
            spaceInputs = UI.heavenly.successfulInputs,
            inputFailures = UI.heavenly.failedInputs,
            duration = os.clock() - UI.heavenly.startedAt,
        })
    end
    UI.heavenly.active = false
    UI.heavenly.titleObject = nil
    UI.heavenly.uiRoot = nil
    UI.heavenly.whiteRing = nil
    UI.heavenly.goldTarget = nil
    UI.heavenly.previousRatio = nil
    UI.heavenly.previousSampleAt = 0
    UI.heavenly.pulseConsumed = false
    UI.heavenly.ringLostAt = 0
    UI.heavenly.inputBusy = false
    UI.heavenly.scanAt = 0
    UI.heavenly.lastFeedback = nil
    UI.heavenly.feedbackValue = nil
    UI.heavenly.feedbackScanAt = 0
    UI.heavenly.lastNoPairLogAt = 0
    UI.heavenly.pairDetected = false
    UI.heavenly.ratioSamples = {}
    UI.heavenly.pulseSerial = 0
    UI.heavenly.lastPulseStartAt = 0
    UI.heavenly.retryNotBefore = 0
    UI.heavenly.awaitingFeedback = false
    UI.heavenly.feedbackHandledPulse = 0
    UI.heavenly.lastInputRatio = nil
end

UI.heavenly.process = function()
    local now = os.clock()
    local title = UI.heavenly.findTitle()
    if title then
        if not UI.heavenly.active then
            UI.heavenly.active = true
            UI.heavenly.startedAt = now
            UI.heavenly.successfulInputs = 0
            UI.heavenly.failedInputs = 0
            UI.heavenly.lastInputAt = 0
            UI.heavenly.scanAt = 0
            UI.heavenly.ringLostAt = 0
            UI.heavenly.feedbackScanAt = 0
            UI.heavenly.feedbackValue = nil
            UI.heavenly.lastNoPairLogAt = 0
            UI.heavenly.pairDetected = false
            UI.heavenly.previousRatio = nil
            UI.heavenly.previousSampleAt = 0
            UI.heavenly.pulseConsumed = false
            UI.heavenly.ratioSamples = {}
            UI.heavenly.pulseSerial = 1
            UI.heavenly.lastPulseStartAt = now
            UI.heavenly.retryNotBefore = 0
            UI.heavenly.awaitingFeedback = false
            UI.heavenly.feedbackHandledPulse = 0
            UI.heavenly.lastInputRatio = nil
            UI.heavenly.timingLead = 0.020
            UI.heavenly.whiteRing = nil
            UI.heavenly.goldTarget = nil
            breakthroughTrialSeen = true
            lastTrialText = "Heavenly Tribulation: detecting timing ring"
            DIAG.log("INFO", "HEAVENLY", "tribulation_detected", {
                title = tostring(title.Text),
                qiRealm = type(qiState) == "table" and qiState.realm or nil,
                note = "Displayed realm cadence is every 5 realms; detection uses the live title, not realm modulo."
            })
        end
        UI.heavenly.lastSeenAt = now
        breakthroughTrialSeen = true
    elseif UI.heavenly.active then
        -- A short grace period prevents a transient title rebuild from releasing
        -- the cultivation lock while the event is still resolving.
        if now - UI.heavenly.lastSeenAt <= 1.25 then
            return true
        end
        UI.heavenly.reset("Heavenly Tribulation title disappeared")
        lastTrialText = "Heavenly Tribulation: finished; waiting for Qi realm/progress update"
        setStatus("Heavenly Tribulation ended; waiting for the server's Qi progression update before resuming.", COLORS.success)
        return false
    else
        return false
    end

    if not breakthroughEnabled then
        lastTrialText = "Heavenly Tribulation: detected; Auto Breakthrough is OFF"
        setStatus("Heavenly Tribulation detected, but Auto Breakthrough is OFF. SPACE timing is paused.", COLORS.warning)
        return true
    end

    local whiteRef = UI.heavenly.whiteRing
    local goldRef = UI.heavenly.goldTarget
    local refsInvalid = (whiteRef and (not whiteRef.Parent or not whiteRef.Visible or whiteRef.AbsoluteSize.X < 18))
        or (goldRef and (not goldRef.Parent or not goldRef.Visible or goldRef.AbsoluteSize.X < 18))
    local noPair = not whiteRef or not goldRef
    local shouldRescan = refsInvalid
        or (noPair and now - UI.heavenly.scanAt >= 0.22)
        or (not noPair and now - UI.heavenly.scanAt >= 0.90)
    if shouldRescan then
        UI.heavenly.scanAt = now
        local oldWhite, oldGold = UI.heavenly.whiteRing, UI.heavenly.goldTarget
        local whiteRing, goldTarget, ringSource = UI.heavenly.findRingPair()
        UI.heavenly.whiteRing = whiteRing
        UI.heavenly.goldTarget = goldTarget
        UI.heavenly.ringSource = ringSource or "unavailable"
        if whiteRing and goldTarget and (whiteRing ~= oldWhite or goldTarget ~= oldGold) then
            UI.heavenly.previousRatio = nil
            UI.heavenly.previousSampleAt = 0
            UI.heavenly.ratioSamples = {}
            UI.heavenly.pulseConsumed = false
            UI.heavenly.awaitingFeedback = false
            UI.heavenly.pulseSerial = UI.heavenly.pulseSerial + 1
            UI.heavenly.lastPulseStartAt = now
            UI.heavenly.pairDetected = false
            DIAG.log("INFO", "HEAVENLY", "timing_pair_reacquired", {
                white = whiteRing:GetFullName(), gold = goldTarget:GetFullName(),
                source = ringSource,
            })
        end
        if not UI.heavenly.whiteRing or not UI.heavenly.goldTarget then
            if UI.heavenly.ringLostAt == 0 then UI.heavenly.ringLostAt = now end
            UI.heavenly.pairDetected = false
            if now - UI.heavenly.ringLostAt > 0.28 then
                UI.heavenly.previousRatio = nil
                UI.heavenly.previousSampleAt = 0
                UI.heavenly.ratioSamples = {}
                UI.heavenly.pulseConsumed = false
                UI.heavenly.awaitingFeedback = false
            end
            lastTrialText = "Heavenly Tribulation: waiting for ring geometry"
            if now - UI.heavenly.lastNoPairLogAt >= 1.0 then
                UI.heavenly.lastNoPairLogAt = now
                DIAG.log("WARN", "HEAVENLY", "timing_ring_pair_unresolved", {
                    detail = UI.heavenly.ringSource,
                    titleRoot = UI.heavenly.uiRoot and UI.heavenly.uiRoot:GetFullName() or "unknown",
                })
            end
            setStatus("Heavenly Tribulation active; waiting for the white ring and gold target to become readable.", COLORS.warning)
            return true
        end
        UI.heavenly.ringLostAt = 0
        if not UI.heavenly.pairDetected then
            UI.heavenly.pairDetected = true
            DIAG.log("INFO", "HEAVENLY", "timing_ring_pair_found", {source = UI.heavenly.ringSource})
        end
    end

    local white = UI.heavenly.whiteRing
    local gold = UI.heavenly.goldTarget
    if not white or not gold or not white.Parent or not gold.Parent or not white.Visible or not gold.Visible then
        UI.heavenly.whiteRing = nil
        UI.heavenly.goldTarget = nil
        UI.heavenly.ringLostAt = now
        UI.heavenly.pairDetected = false
        return true
    end

    local ws, gs = white.AbsoluteSize, gold.AbsoluteSize
    local ratio = ((ws.X + ws.Y) * 0.5) / math.max(1, (gs.X + gs.Y) * 0.5)
    local previous = UI.heavenly.previousRatio
    local previousAt = UI.heavenly.previousSampleAt
    local dt = previousAt > 0 and (now - previousAt) or 0

    -- Continuous tribulations can reset the same UI objects without destroying
    -- them. Detect a genuine outward reset instead of requiring a large 1.22x
    -- ring size; the old threshold missed faster/smaller consecutive pulses.
    local rising = previous ~= nil and ratio > previous + 0.025
    if rising and ratio >= 1.035 and now - UI.heavenly.lastPulseStartAt >= 0.10 then
        UI.heavenly.pulseConsumed = false
        UI.heavenly.lastPulseStartAt = now
        UI.heavenly.pulseSerial = UI.heavenly.pulseSerial + 1
        UI.heavenly.awaitingFeedback = false
        UI.heavenly.lastFeedback = nil
        UI.heavenly.ratioSamples = {}
        DIAG.log("INFO", "HEAVENLY", "continuous_pulse_rearmed", {
            pulse = UI.heavenly.pulseSerial,
            ratio = ratio,
            previousRatio = previous,
        })
    end

    -- Drop stale samples after a frame hitch. A large dt produces a misleading
    -- velocity estimate and was a common source of late/early SPACE presses.
    if dt > 0.16 then
        UI.heavenly.ratioSamples = {}
        previous = nil
        dt = 0
    end

    local samples = UI.heavenly.ratioSamples
    table.insert(samples, {t = now, r = ratio})
    while #samples > 4 or (#samples > 1 and now - samples[1].t > 0.14) do
        table.remove(samples, 1)
    end

    -- Least-squares slope across the most recent samples is less noisy than a
    -- single-frame derivative, especially when the game is under load.
    local rate = nil
    if #samples >= 3 then
        local meanT, meanR = 0, 0
        for _, sample in ipairs(samples) do
            meanT = meanT + sample.t
            meanR = meanR + sample.r
        end
        meanT = meanT / #samples
        meanR = meanR / #samples
        local numerator, denominator = 0, 0
        for _, sample in ipairs(samples) do
            numerator = numerator + (sample.t - meanT) * (sample.r - meanR)
            denominator = denominator + (sample.t - meanT) ^ 2
        end
        if denominator > 0.000001 then rate = numerator / denominator end
    elseif previous ~= nil and dt > 0 then
        rate = (ratio - previous) / dt
    end

    local shouldPress = false
    local timeToAlignment = nil
    local canAttempt = not UI.heavenly.pulseConsumed
        and not UI.heavenly.inputBusy
        and now >= UI.heavenly.retryNotBefore
        and now - UI.heavenly.lastInputAt >= 0.12

    if canAttempt and rate and rate < -0.02 then
        timeToAlignment = (1.0 - ratio) / rate
        local lead = math.clamp(UI.heavenly.timingLead, 0, 0.065)
        shouldPress = timeToAlignment <= lead and timeToAlignment >= -0.025
    end

    UI.heavenly.previousRatio = ratio
    UI.heavenly.previousSampleAt = now

    local feedback = UI.heavenly.readFeedback()
    if feedback and UI.heavenly.awaitingFeedback
        and now - UI.heavenly.lastInputAt >= 0.10
        and UI.heavenly.feedbackHandledPulse ~= UI.heavenly.pulseSerial then
        UI.heavenly.feedbackHandledPulse = UI.heavenly.pulseSerial
        UI.heavenly.awaitingFeedback = false
        UI.heavenly.lastFeedback = feedback
        DIAG.log("INFO", "HEAVENLY", "timing_feedback", {
            feedback = feedback,
            ratioAtInput = UI.heavenly.lastInputRatio,
            timingLead = UI.heavenly.timingLead,
            pulse = UI.heavenly.pulseSerial,
        })
        if feedback == "PERFECT" or feedback == "PERFECT!" or feedback == "GOOD" or feedback == "GOOD!" then
            UI.heavenly.successfulInputs = UI.heavenly.successfulInputs + 1
            -- Preserve a successful lead; only misses move the calibration.
        elseif feedback == "MISS" or feedback == "FAILED" then
            local ratioAtInput = UI.heavenly.lastInputRatio or 1
            if ratioAtInput > 1.012 then
                -- Input landed before the target: shorten the lead.
                UI.heavenly.timingLead = math.max(0, UI.heavenly.timingLead - 0.006)
            elseif ratioAtInput < 0.988 then
                -- Input landed after the target: increase the lead.
                UI.heavenly.timingLead = math.min(0.065, UI.heavenly.timingLead + 0.006)
            end
            DIAG.log("WARN", "HEAVENLY", "timing_miss_feedback", {
                feedback = feedback,
                ratioAtInput = ratioAtInput,
                adjustedLead = UI.heavenly.timingLead,
            })
        end
    elseif not feedback then
        UI.heavenly.lastFeedback = nil
    end

    if shouldPress then
        UI.heavenly.inputBusy = true
        UI.heavenly.lastInputAt = now
        UI.heavenly.lastInputRatio = ratio
        UI.heavenly.awaitingFeedback = true
        lastTrialText = "Heavenly Tribulation: SPACE timing input"
        DIAG.log("INFO", "HEAVENLY", "space_input_attempt", {
            ringRatio = ratio,
            rate = rate,
            timeToAlignment = timeToAlignment,
            timingLead = UI.heavenly.timingLead,
            pulse = UI.heavenly.pulseSerial,
            ringSource = UI.heavenly.ringSource,
        })
        task.spawn(function()
            local ok, sent, backend = pcall(sendTimingKey, Enum.KeyCode.Space)
            UI.heavenly.inputBusy = false
            if ok and sent then
                UI.heavenly.pulseConsumed = true
                DIAG.log("INFO", "HEAVENLY", "space_input_sent", {
                    backend = backend,
                    ringRatio = ratio,
                    pulse = UI.heavenly.pulseSerial,
                })
                setStatus("Heavenly Tribulation: SPACE sent; adaptive timing lead " .. string.format("%.0fms", UI.heavenly.timingLead * 1000) .. ".", COLORS.success)
            else
                UI.heavenly.awaitingFeedback = false
                UI.heavenly.retryNotBefore = os.clock() + 0.12
                UI.heavenly.failedInputs = UI.heavenly.failedInputs + 1
                DIAG.log("ERROR", "HEAVENLY", "space_input_failed", {
                    error = ok and backend or tostring(sent),
                    ringRatio = ratio,
                    pulse = UI.heavenly.pulseSerial,
                })
                setStatus("Heavenly Tribulation SPACE input failed; retrying this pulse if timing remains available.", COLORS.danger)
            end
        end)
    else
        lastTrialText = string.format(
            "Heavenly Tribulation: ring %.2fx | SPACE %d | lead %.0fms | pulse %d",
            ratio, UI.heavenly.successfulInputs,
            UI.heavenly.timingLead * 1000, UI.heavenly.pulseSerial
        )
    end
    return true
end

local function processTrial()
    if UI.heavenly.process() then
        return true
    end
    local trialGui = getActiveTrialGui()
    if not trialGui then
        if activeTrialGui then
            activeTrialGui = nil
            attemptedPrompts = {}
            previousRingSizes = {}
            lastTrialScoreText = nil
            lastTrialText = "Trial: idle"
        end
        return false
    end

    breakthroughTrialSeen = true

    if activeTrialGui ~= trialGui then
        activeTrialGui = trialGui
        attemptedPrompts = {}
        previousRingSizes = {}
        lastTrialScoreText = nil
        lastTrialText = "Trial detected: " .. trialGui.Name
        setStatus("Tribulation detected; tracking the Tap timing ring.", COLORS.warning)
    end

    local current, required, scoreText = getScoreInfo(trialGui)
    if scoreText then
        lastTrialScoreText = scoreText
        lastTrialText = "Trial: " .. scoreText
    else
        lastTrialText = "Trial: active; waiting for Tap prompts"
    end

    -- The score is diagnostic only. It is NOT required to process a prompt.
    if not breakthroughEnabled then
        setStatus("Tribulation detected; Auto Breakthrough is OFF.", COLORS.warning)
        return true
    end

    local promptNumber, prompt = getLatestPrompt(trialGui)
    if not promptNumber or not prompt then
        setStatus("Tribulation active; waiting for the next Tap prompt.", COLORS.warning)
        return true
    end

    local promptKey = trialGui.Name .. ":Prompt" .. tostring(promptNumber)
    if attemptedPrompts[promptKey] then
        setStatus("Prompt " .. tostring(promptNumber) .. " already handled; waiting for the next.", COLORS.muted)
        return true
    end

    local ring = prompt:FindFirstChild("Ring")
    local seal = prompt:FindFirstChild("Seal")
    local tap = seal and seal:FindFirstChild("Tap")
    if not ring or not seal or not tap or not tap:IsA("GuiButton") then
        setStatus("Prompt " .. tostring(promptNumber) .. ": Ring/Seal/Tap not found.", COLORS.warning)
        return true
    end

    if not prompt.Visible or not ring.Visible or not seal.Visible or not tap.Visible or not tap.Active then
        return true
    end

    local ringSize = ring.AbsoluteSize.X
    local sealSize = seal.AbsoluteSize.X
    if ringSize <= 0 or sealSize <= 0 then
        return true
    end

    local previous = previousRingSizes[promptKey]
    local shrinking = previous ~= nil and ringSize < previous - 0.1
    previousRingSizes[promptKey] = ringSize

    local ratio = ringSize / sealSize
    local stroke = ring:FindFirstChildOfClass("UIStroke")
    local gold = true
    if stroke then
        gold = isGold(stroke.Color) and stroke.Transparency <= 0.16
    end
    local aligned = ratio >= 0.97 and ratio <= 1.025

    if gold and aligned and shrinking then
        local sent, backend = clickGuiButton(tap)
        if sent then
            attemptedPrompts[promptKey] = true
            setStatus(
                "Clicked Prompt " .. tostring(promptNumber)
                    .. " at " .. string.format("%.3fx", ratio)
                    .. " (" .. backend .. ").",
                COLORS.success
            )
            DIAG.log("INFO", "TRIBULATION", "tap_activated", {prompt = promptKey, ringRatio = ratio, backend = backend})
            print("[CU AutoCultivation] Trial click: " .. promptKey .. " ratio=" .. string.format("%.3f", ratio))
        else
            setStatus("Trial click failed: " .. tostring(backend), COLORS.danger)
        end
    else
        local phase = gold and "gold; waiting for alignment" or "waiting for gold ring"
        setStatus(
            "Prompt " .. tostring(promptNumber) .. " " .. phase
                .. " (" .. string.format("%.2fx", ratio) .. ").",
            COLORS.warning
        )
    end

    return true
end

local function resetBreakthroughState(mode, signature)
    breakthroughMode = mode
    breakthroughSignature = signature
    breakthroughAttempts = 0
    lastBreakthroughTryAt = 0
    breakthroughTrialSeen = false
    breakthroughWaitForProgressReset = false
end

local function processBreakthrough()
    if UI.heavenly.active or autoBrewBusy or cauldronPanelIsOpen() then
        return
    end
    local mode, frame, statusPanel = getActiveMode()
    if not mode or not frame or not statusPanel then
        lastMode = "Unknown"
        lastPercent = nil
        return
    end

    lastMode = mode
    local percent, signature, realmText = getModeProgress(mode, frame)
    lastPercent = percent

    if modeLabel then
        modeLabel.Text = "Mode: " .. mode .. (selectedAutoMode == mode and " AUTO" or " monitor")
        modeLabel.TextColor3 = mode == "Qi" and COLORS.qi or COLORS.body
    end
    if progressLabel then
        progressLabel.Text = "Progress: " .. (percent and string.format("%.2f%%", percent) or "--")
    end

    if percent == nil or percent < 99.95 then
        -- A real progress reset is the signal that a new layer is ready.
        -- This also prevents the completed tribulation from being clicked again.
        if breakthroughMode ~= mode or breakthroughSignature ~= signature
            or breakthroughAttempts > 0 or breakthroughTrialSeen or breakthroughWaitForProgressReset then
            resetBreakthroughState(mode, signature)
        else
            breakthroughMode = mode
            breakthroughSignature = signature
        end
        if percent then
            if not selectedAutoMode then
                setStatus("Monitoring " .. mode .. "; waiting for 100%.", COLORS.muted)
            end
        else
            setStatus("Waiting for " .. mode .. " progress data.", COLORS.muted)
        end
        return
    end

    if not breakthroughEnabled then
        setStatus("100% reached; Auto Breakthrough is OFF.", COLORS.warning)
        return
    end

    if activeTrialGui or getActiveTrialGui() then
        breakthroughTrialSeen = true
        setStatus("100% reached; tribulation is active.", COLORS.warning)
        return
    end

    if breakthroughMode ~= mode then
        resetBreakthroughState(mode, signature)
    elseif breakthroughSignature == nil then
        breakthroughSignature = signature
    elseif breakthroughSignature ~= signature then
        -- Realm/layer changed while the bar still displays 100%. Wait for the
        -- UI to publish its new progress instead of risking a duplicate click.
        breakthroughSignature = signature
        breakthroughWaitForProgressReset = true
        setStatus("Progression changed; waiting for the new layer's progress bar.", COLORS.success)
        return
    end

    if breakthroughWaitForProgressReset then
        setStatus("Breakthrough registered; waiting for progress to reset before another click.", COLORS.success)
        return
    end

    if breakthroughTrialSeen then
        setStatus("Tribulation finished; waiting for the game to update the layer/realm.", COLORS.success)
        return
    end

    local now = os.clock()
    local shouldClick = (breakthroughAttempts == 0 and now - lastBreakthroughTryAt >= 1.5)
        or (breakthroughAttempts == 1 and now - lastBreakthroughTryAt >= 10)

    if not shouldClick then
        setStatus("Breakthrough click sent; waiting for progression update.", COLORS.warning)
        return
    end

    local row = statusPanel:FindFirstChild("BreakthroughRow")
    local button = row and row:FindFirstChild("BreakthroughBanner")
    if not button or not button:IsA("TextButton") or button.Text ~= "Breakthrough" then
        setStatus("100% reached; exact BreakthroughBanner not found.", COLORS.warning)
        return
    end
    if not row.Visible or not isVisibleInTree(button) or not button.Active then
        setStatus("100% reached; waiting for the actual Breakthrough button to activate.", COLORS.warning)
        return
    end

    local sent, backend = clickGuiButton(button)
    lastBreakthroughTryAt = now
    if sent then
        breakthroughAttempts = breakthroughAttempts + 1
        setStatus(
            mode .. " at 100%; activated BreakthroughBanner (attempt " .. tostring(breakthroughAttempts) .. ").",
            COLORS.success
        )
        DIAG.log("INFO", "BREAKTHROUGH", "button_activated", {mode = mode, realm = realmText, signature = signature, percent = percent, backend = backend, attempt = breakthroughAttempts})
        print("[CU AutoCultivation] " .. mode .. " 100% -> Breakthrough click, " .. tostring(realmText) .. " via " .. backend)
    else
        DIAG.log("ERROR", "BREAKTHROUGH", "button_activation_failed", {mode = mode, realm = realmText, reason = tostring(backend), signature = signature})
        setStatus("Breakthrough click failed: " .. tostring(backend), COLORS.danger)
    end
end

local function getRealmNumber(mode)
    local state = mode == "Qi" and qiState or bodyState
    if type(state) ~= "table" then
        return nil
    end
    if mode == "Qi" then
        return tonumber(state.realm)
    end
    return tonumber(state.bodyRealm)
end

local function chooseBestZone(mode, realmNumber)
    if not realmNumber then
        return nil
    end
    local list = ZONES[mode]
    local chosen = nil
    for _, zone in ipairs(list) do
        if realmNumber >= zone.realm then
            chosen = zone
        end
    end
    return chosen
end

local function getCharacterParts()
    local character = LocalPlayer.Character
    if not character then
        return nil, nil
    end
    local root = character:FindFirstChild("HumanoidRootPart")
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not root or not humanoid or humanoid.Health <= 0 then
        return nil, humanoid
    end
    return root, humanoid
end

local function getZoneCoordinates(mode, zone)
    local folderName = mode == "Qi" and "CultivationZones" or "BodyCultivationZones"
    local folder = Workspace:FindFirstChild(folderName)
    local part = folder and folder:FindFirstChild(zone.name)

    local x, y, z = zone.x, zone.y, zone.z
    local size = zone.size
    local thickness = 2

    if part and part:IsA("BasePart") and part.Size.Y <= 3 then
        -- Some Body folders also contain a second, taller trigger-volume part
        -- with the same name. Prefer the thin floor marker when available.
        x, y, z = part.Position.X, part.Position.Y, part.Position.Z
        size = math.max(part.Size.X, part.Size.Z)
        thickness = part.Size.Y
    end

    -- Zone part is the thin floor marker. Put the HumanoidRootPart above it,
    -- inside the verified zone volume, rather than at the floor's center.
    local targetY = y + (thickness / 2) + 3.0
    return Vector3.new(x, targetY, z), size
end

local function isInsideZone(root, target, size)
    if not root then
        return false
    end
    local dx = root.Position.X - target.X
    local dz = root.Position.Z - target.Z
    local horizontal = math.sqrt(dx * dx + dz * dz)
    local vertical = math.abs(root.Position.Y - target.Y)
    return horizontal <= math.max(8, size / 2 - 7) and vertical <= 28
end

local function zoneBonusVerified(mode, zone)
    if mode == "Qi" then
        if type(qiState) ~= "table" then
            return false
        end
        local currentZone = tostring(qiState.currentZone or "")
        local multiplier = tonumber(qiState.zoneMultiplier)
        return currentZone == zone.name and multiplier ~= nil and multiplier >= zone.multiplier - 0.02
    end

    if type(bodyState) ~= "table" then
        return false
    end
    local multiplier = tonumber(bodyState.bodyZoneMultiplier)
    return multiplier ~= nil and multiplier >= zone.multiplier - 0.02
end

local function teleportToZone(mode, zone)
    if teleporting or (lastTeleportAt > 0 and os.clock() - lastTeleportAt < 8) then
        return
    end

    local root = getCharacterParts()
    if not root then
        setStatus("Waiting for your character to load before travelling.", COLORS.warning)
        return
    end

    local target, size = getZoneCoordinates(mode, zone)
    if isInsideZone(root, target, size) then
        return
    end

    teleporting = true
    lastTeleportAt = os.clock()
    lastTeleportTarget = zone.name
    DIAG.log("INFO", "CULTIVATION", "zone_travel_started", {mode = mode, zone = zone.name, target = target, size = size, realm = getRealmNumber(mode), multiplier = zone.multiplier})
    setStatus("Travelling to " .. zone.name .. "...", COLORS.warning)

    task.spawn(function()
        -- Cancel a pending travel if the user switches Auto Cultivation OFF
        -- or changes to the other mode before the teleport task runs.
        if not running or paused or selectedAutoMode ~= mode or CHEST.teleportActive then
            teleporting = false
            return
        end

        local currentRoot = getCharacterParts()
        if not currentRoot then
            teleporting = false
            return
        end

        local look = currentRoot.CFrame.LookVector
        local destination = CFrame.new(target, target + look)
        local ok, err = pcall(function()
            currentRoot.AssemblyLinearVelocity = Vector3.zero
            currentRoot.AssemblyAngularVelocity = Vector3.zero
            currentRoot.CFrame = destination
        end)

        if not ok then
            DIAG.log("ERROR", "CULTIVATION", "zone_teleport_failed", {mode = mode, zone = zone.name, reason = tostring(err)})
            setStatus("Teleport failed: " .. tostring(err), COLORS.danger)
            teleporting = false
            return
        end

        task.wait(2.5)
        local verifyRoot = getCharacterParts()
        local arrived = verifyRoot and isInsideZone(verifyRoot, target, size)
        if selectedAutoMode == mode and running then
            if arrived then
                DIAG.log("INFO", "CULTIVATION", "zone_arrival_verified_locally", {mode = mode, zone = zone.name, position = verifyRoot.Position, target = target})
                setStatus("Arrived at " .. zone.name .. "; checking the server zone bonus.", COLORS.success)
            else
                DIAG.log("WARN", "CULTIVATION", "zone_teleport_not_retained", {mode = mode, zone = zone.name, position = verifyRoot and verifyRoot.Position or nil, target = target})
                setStatus("Teleport was not retained by the game. Server may be correcting CFrame movement.", COLORS.danger)
            end
        end
        teleporting = false
    end)
end

local function readCharacterBool(name)
    local characterModel = Workspace:FindFirstChild(LocalPlayer.Name)
    local valueObject = characterModel and characterModel:FindFirstChild(name)
    if valueObject and valueObject:IsA("BoolValue") then
        return valueObject.Value
    end
    return nil
end

local function isTrainingActive(mode)
    if mode == "Qi" then
        if type(qiState) == "table" and qiState.isMeditating == true then
            return true
        end
        return readCharacterBool("IsMeditating") == true
    end

    if type(bodyState) == "table" and bodyState.isPushingUp == true then
        return true
    end
    return readCharacterBool("IsPushingUp") == true
end

local function activateTraining(mode)
    local now = os.clock()
    if now - trainingToggleAt < 3.5 then
        return
    end
    if trainingToggleAttempts >= 2 and now - trainingToggleAt < 10 then
        return
    end
    if now - trainingToggleAt >= 10 then
        trainingToggleAttempts = 0
    end

    local frame, statusPanel = getFrameForMode(mode)
    local candidates = {}
    if frame then
        if mode == "Qi" then
            table.insert(candidates, frame:FindFirstChild("MeditateButton"))
        else
            table.insert(candidates, frame:FindFirstChild("PushupButton2"))
            table.insert(candidates, frame:FindFirstChild("PushupButton"))
            local mainFrame = statusPanel and statusPanel:FindFirstChild("MainFrame")
            table.insert(candidates, mainFrame and mainFrame:FindFirstChild("PushupButton"))
        end
    end

    local sent = false
    local backend = nil
    for _, button in ipairs(candidates) do
        if button and button:IsA("GuiButton") and button.Active and isVisibleInTree(button) then
            local text = tostring(button.Text or "")
            local shouldActivate = mode == "Qi"
                and not string.find(string.lower(text), "stop meditating", 1, true)
                or mode == "Body" and not string.find(string.lower(text), "stop", 1, true)
            if shouldActivate then
                sent, backend = clickGuiButton(button)
                if sent then
                    break
                end
            end
        end
    end

    if not sent then
        local key = mode == "Qi" and Enum.KeyCode.M or Enum.KeyCode.P
        sent, backend = sendKey(key)
    end

    trainingToggleAt = now
    trainingToggleAttempts = trainingToggleAttempts + 1
    if sent then
        autoStartedTrainingMode = mode
        DIAG.log("INFO", "CULTIVATION", "training_start_input_sent", {mode = mode, backend = backend, key = mode == "Qi" and "M" or "P"})
        setStatus("Starting " .. (mode == "Qi" and "Qi meditation" or "Body push-ups") .. " via " .. tostring(backend) .. ".", COLORS.success)
    else
        DIAG.log("ERROR", "CULTIVATION", "training_start_input_failed", {mode = mode, backend = backend})
        setStatus("Could not send the " .. (mode == "Qi" and "M" or "P") .. " training input: " .. tostring(backend), COLORS.danger)
    end
end

local function stopAutomationOwnedTraining(mode)
    if autoStartedTrainingMode ~= mode then
        return true, false, nil
    end

    if not isTrainingActive(mode) then
        autoStartedTrainingMode = nil
        return true, false, nil
    end

    local key = mode == "Qi" and Enum.KeyCode.M or Enum.KeyCode.P
    local sent, backend = sendKey(key)
    if not sent then
        return false, false, backend
    end

    autoStartedTrainingMode = nil
    DIAG.log("INFO", "CULTIVATION", "automation_owned_training_stopped", {mode = mode, backend = backend})
    return true, true, backend
end

local function processAutoCultivation()
    if SETTINGS.loaded and not SETTINGS.restoreReady then return end
    if UI.heavenly.active or INHERITANCE.busy or herbCollectorBusy or CHEST.busy or CHEST.teleportActive or SILVER.busy or autoBrewBusy or cauldronPanelIsOpen() or not selectedAutoMode or paused or not running then
        return
    end
    -- Never relocate or restart training while a breakthrough/tribulation is
    -- loading, active, or waiting for its progression update.
    if UI.heavenly.active or activeTrialGui or getActiveTrialGui() or breakthroughTrialSeen then
        return
    end

    local mode = selectedAutoMode
    local state = mode == "Qi" and qiState or bodyState
    if type(state) ~= "table" then
        setStatus("Waiting for replicated " .. mode .. " realm data.", COLORS.warning)
        return
    end

    local realmNumber = getRealmNumber(mode)
    local zone = chooseBestZone(mode, realmNumber)
    if not zone then
        setStatus("Could not determine your " .. mode .. " realm yet.", COLORS.warning)
        return
    end

    if DIAG.lastZoneByMode[mode] ~= zone.name then
        DIAG.lastZoneByMode[mode] = zone.name
        DIAG.log("INFO", "CULTIVATION", "best_zone_selected", {mode = mode, zone = zone.name, realm = realmNumber, requiredRealm = zone.realm, multiplier = zone.multiplier, coordinates = {x = zone.x, y = zone.y, z = zone.z}})
    end

    local frame = getFrameForMode(mode)
    local percent = frame and getModeProgress(mode, frame)
    if percent and percent >= 99.95 then
        setStatus(mode .. " is at 100%; letting Auto Breakthrough handle it.", COLORS.warning)
        return
    end

    local root = getCharacterParts()
    if not root then
        setStatus("Waiting for character/respawn.", COLORS.warning)
        return
    end

    local target, size = getZoneCoordinates(mode, zone)
    local inside = isInsideZone(root, target, size)
    local verified = zoneBonusVerified(mode, zone)

    if zoneLabel then
        zoneLabel.Text = string.format(
            "Best zone: %s | %.2fx | Realm %d+",
            zone.name,
            zone.multiplier,
            zone.realm
        )
    end

    if not inside then
        if not teleporting then
            teleportToZone(mode, zone)
        end
        return
    end

    if not verified then
        setStatus("Inside " .. zone.name .. "; waiting for the server to confirm its " .. string.format("%.2fx", zone.multiplier) .. " bonus.", COLORS.warning)
        return
    end

    if isTrainingActive(mode) then
        trainingToggleAttempts = 0
        if DIAG.lastTrainingState[mode] ~= true then
            DIAG.lastTrainingState[mode] = true
            DIAG.log("INFO", "CULTIVATION", "training_active_verified", {mode = mode, zone = zone.name, multiplier = zone.multiplier, state = mode == "Qi" and qiState or bodyState})
        end
        setStatus(mode .. " training active at " .. zone.name .. " (" .. string.format("%.2fx", zone.multiplier) .. ").", COLORS.success)
        return
    end
    if DIAG.lastTrainingState[mode] ~= false then
        DIAG.lastTrainingState[mode] = false
        DIAG.log("WARN", "CULTIVATION", "training_not_active", {mode = mode, zone = zone.name, multiplierVerified = verified})
    end

    activateTraining(mode)
end

-- Herb collection -----------------------------------------------------------
-- The user's recording showed CollectHerbPrompt with ActionText="Collect",
-- KeyboardKeyCode=E, HoldDuration=2.5, MaxActivationDistance=10. The game also
-- exposes HerbInventoryUpdate. We use the prompt rather than directly invoking the collection remote.

local function getHerbPromptPosition(prompt)
    local parent = prompt and prompt.Parent
    if not parent then
        return nil
    end
    if parent:IsA("BasePart") then
        return parent.Position
    end
    if parent:IsA("Model") then
        local ok, pivot = pcall(function()
            return parent:GetPivot()
        end)
        if ok and pivot then
            return pivot.Position
        end
    end
    local part = parent:FindFirstChildWhichIsA("BasePart", true)
    return part and part.Position or nil
end

local function getHerbPromptName(prompt)
    if not prompt then
        return "Unknown herb"
    end
    local objectText = tostring(prompt.ObjectText or "")
    if objectText ~= "" then
        return objectText
    end
    return prompt.Parent and prompt.Parent.Name or "Unknown herb"
end

local function getHerbMetadata(prompt)
    local node = prompt and prompt.Parent
    local age, herbType, species
    local depth = 0

    while node and depth < 6 do
        if age == nil then
            local ok, value = pcall(function()
                return node:GetAttribute("HerbYear")
            end)
            if ok then age = tonumber(value) end
        end
        if herbType == nil then
            local ok, value = pcall(function()
                return node:GetAttribute("HerbType")
            end)
            if ok then herbType = tonumber(value) end
        end
        if age ~= nil and herbType ~= nil then
            break
        end
        if node.Name == "HerbSpots" or node.Name == "Herbs" then
            break
        end
        node = node.Parent
        depth = depth + 1
    end

    species = (herbType and HERB_TYPE_NAMES[herbType]) or getHerbPromptName(prompt)
    for _, known in ipairs(HERB_SPECIES) do
        if string.find(string.lower(species), string.lower(known), 1, true) then
            species = known
            break
        end
    end

    return species, age, herbType
end

local function isHerbSpeciesAllowed(species)
    for _, known in ipairs(HERB_SPECIES) do
        if species == known then
            return herbSpeciesSelection[known] == true
        end
    end

    -- Unknown/spirit herb species are allowed only when all normal-herb
    -- filters are enabled; selecting specific species excludes unknown types.
    for _, known in ipairs(HERB_SPECIES) do
        if not herbSpeciesSelection[known] then
            return false
        end
    end
    return true
end

HERB_MONITOR.isAgeAllowed = function(age)
    -- Unknown ages are only allowed when every age tier is selected. This is
    -- important for strict filters such as 1000-year-only: unknown is not 1000.
    if age == nil then
        for _, knownAge in ipairs(HERB_MONITOR.ageOptions) do
            if not HERB_MONITOR.ageSelection[knownAge] then return false end
        end
        return true
    end
    if HERB_MONITOR.ageSelection[age] ~= nil then
        return HERB_MONITOR.ageSelection[age] == true
    end
    for _, knownAge in ipairs(HERB_MONITOR.ageOptions) do
        if not HERB_MONITOR.ageSelection[knownAge] then return false end
    end
    return true
end

HERB_MONITOR.getAgeScanInterval = function()
    local only1000 = HERB_MONITOR.ageSelection[1000] == true
        and HERB_MONITOR.ageSelection[100] ~= true
        and HERB_MONITOR.ageSelection[10] ~= true
        and HERB_MONITOR.ageSelection[1] ~= true
    return only1000 and 0.85 or 1.5
end

local function getHerbFolders()
    local folders = {}
    local normal = Workspace:FindFirstChild("HerbSpots")
    if normal then
        table.insert(folders, normal)
    end
    local spiritWorld = Workspace:FindFirstChild("SpiritWorld")
    local spiritHerbs = spiritWorld and spiritWorld:FindFirstChild("Herbs")
    if spiritHerbs then
        table.insert(folders, spiritHerbs)
    end
    return folders
end

HERB_HOP.isStrict1000Only = function()
    return HERB_MONITOR.ageSelection[1000] == true
        and HERB_MONITOR.ageSelection[100] ~= true
        and HERB_MONITOR.ageSelection[10] ~= true
        and HERB_MONITOR.ageSelection[1] ~= true
end

-- Count only live, enabled, unpicked prompts whose replicated HerbYear is exactly 1000.
-- This scan is deliberately separate from the nearest-prompt picker so a 12-second
-- retry cooldown on one failed prompt cannot falsely make the server look empty.
HERB_HOP.countAvailable1000 = function()
    local count = 0
    local scanned = 0
    local folders = getHerbFolders()
    for _, folder in ipairs(folders) do
        for _, node in ipairs(folder:GetDescendants()) do
            if node:IsA("ProximityPrompt") and node.Name == "CollectHerbPrompt" and node.Parent then
                scanned = scanned + 1
                if node.Enabled then
                    local picked = false
                    local parent = node.Parent
                    local depth = 0
                    while parent and depth < 6 do
                        local ok, value = pcall(function() return parent:GetAttribute("Picked") end)
                        if ok and value == true then picked = true break end
                        parent = parent.Parent
                        depth = depth + 1
                    end
                    if not picked and not herbCollectedPrompts[node] then
                        local species, age = getHerbMetadata(node)
                        if age == 1000 and isHerbSpeciesAllowed(species) then
                            count = count + 1
                        end
                    end
                end
            end
        end
    end
    return count, scanned, #folders
end

HERB_HOP.resetEmptyTimer = function(reason)
    HERB_HOP.emptySince = nil
    HERB_HOP.lastAvailableCount = nil
    if reason then HERB_HOP.status = reason end
end

HERB_HOP.update = function()
    if not HERB_HOP.enabled then
        HERB_HOP.resetEmptyTimer("OFF")
        return false
    end
    if not autoHerbsEnabled then
        HERB_HOP.resetEmptyTimer("waiting for Auto Herbs")
        return false
    end
    if not HERB_HOP.isStrict1000Only() then
        HERB_HOP.resetEmptyTimer("requires 1,000 YEARS ONLY filter")
        return false
    end
    if paused or not running or not SETTINGS.restoreReady or not getCharacterParts()
        or herbCollectorBusy or UI.heavenly.active or activeTrialGui or getActiveTrialGui()
        or breakthroughTrialSeen or isBreakthroughPending() or autoBrewBusy
        or cauldronPanelIsOpen() or REJOIN.busy then
        HERB_HOP.resetEmptyTimer("waiting for farming activity to become idle")
        return false
    end

    local now = os.clock()
    if now < HERB_HOP.nextAttemptAt then return false end
    if now - HERB_HOP.lastCountAt < 3 then return false end
    HERB_HOP.lastCountAt = now

    local count, scanned, folderCount = HERB_HOP.countAvailable1000()
    HERB_HOP.lastAvailableCount = count
    if folderCount == 0 then
        HERB_HOP.resetEmptyTimer("waiting for herb folders to replicate")
        setHerbStatus("waiting for herb folders; server-hop timer not started")
        return false
    end
    if count > 0 then
        if HERB_HOP.emptySince then
            DIAG.log("INFO", "HERB_HOP", "matching_herbs_found", {available = count, graceReset = true})
        end
        HERB_HOP.resetEmptyTimer("1k herbs available: " .. tostring(count))
        return false
    end

    if not HERB_HOP.emptySince then
        HERB_HOP.emptySince = now
        HERB_HOP.status = "no eligible 1k herbs; grace period started"
        DIAG.log("INFO", "HERB_HOP", "empty_server_confirmed", {available = count, scannedPrompts = scanned, graceSeconds = HERB_HOP.graceSeconds})
        setHerbStatus("no 1k herbs visible; waiting " .. tostring(HERB_HOP.graceSeconds) .. "s before server hop")
        return false
    end

    local elapsed = now - HERB_HOP.emptySince
    local remaining = math.max(0, HERB_HOP.graceSeconds - elapsed)
    HERB_HOP.status = string.format("no 1k herbs; hopping in %ds", math.ceil(remaining))
    setHerbStatus(HERB_HOP.status)
    if elapsed >= HERB_HOP.graceSeconds then
        if herbCollectorBusy or REJOIN.busy or not HERB_HOP.enabled or not autoHerbsEnabled then return false end
        HERB_HOP.nextAttemptAt = now + 90
        DIAG.log("INFO", "HERB_HOP", "grace_period_elapsed", {graceSeconds = HERB_HOP.graceSeconds, available = count, scannedPrompts = scanned})
        setHerbStatus("no eligible 1k herbs after " .. tostring(HERB_HOP.graceSeconds) .. "s; requesting public server hop")
        local requested = REJOIN.serverHop()
        if requested then
            HERB_HOP.status = "server hop requested"
            return true
        end
        HERB_HOP.status = "server hop request failed; retry cooldown 90s"
        DIAG.log("WARN", "HERB_HOP", "server_hop_request_not_started", {retryAfterSeconds = 90})
    end
    return false
end

local function findNearestHerbPrompt()
    local root = getCharacterParts()
    if not root then
        return nil, nil, nil, nil, nil
    end

    local bestPrompt, bestPosition, bestName, bestAge = nil, nil, nil, nil
    local bestDistance = math.huge
    local bestAgeRank = -1
    local now = os.clock()

    for _, folder in ipairs(getHerbFolders()) do
        for _, descendant in ipairs(folder:GetDescendants()) do
            if descendant:IsA("ProximityPrompt")
                and descendant.Name == "CollectHerbPrompt"
                and descendant.Parent then

                if herbCollectedPrompts[descendant] and not descendant.Enabled then
                    herbCollectedPrompts[descendant] = nil
                end

                local alreadyCollected = herbCollectedPrompts[descendant] == true
                local picked = false
                pcall(function()
                    picked = descendant.Parent:GetAttribute("Picked") == true
                end)

                local lastAttempt = herbAttemptTimes[descendant]
                local coolingDown = lastAttempt and (now - lastAttempt < 12)
                if descendant.Enabled and not alreadyCollected and not picked and not coolingDown then
                    local species, age = getHerbMetadata(descendant)
                    if isHerbSpeciesAllowed(species) and HERB_MONITOR.isAgeAllowed(age) then
                        local position = getHerbPromptPosition(descendant)
                        if position then
                            local distance = (root.Position - position).Magnitude
                            -- Highest HerbYear always wins; distance breaks ties.
                            -- Missing age is ranked below known 1-year herbs.
                            local ageRank = age or -1
                            if ageRank > bestAgeRank
                                or (ageRank == bestAgeRank and distance < bestDistance) then
                                bestPrompt = descendant
                                bestPosition = position
                                bestName = species
                                bestAge = age
                                bestDistance = distance
                                bestAgeRank = ageRank
                            end
                        end
                    end
                end
            end
        end
    end

    return bestPrompt, bestPosition, bestName, bestDistance, bestAge
end

local function herbWait(seconds)
    local finishAt = os.clock() + seconds
    while os.clock() < finishAt do
        if not running or not autoHerbsEnabled or paused or UI.heavenly.active then
            return false
        end
        task.wait(0.05)
    end
    return true
end

local function holdHerbPrompt(prompt, inventoryBefore)
    local holdDuration = math.clamp(tonumber(prompt.HoldDuration) or 2.5, 0.1, 5)

    -- Optional quick-interaction probe: fires the actual ProximityPrompt through
    -- the executor helper, then requires a real inventory/prompt-state confirmation.
    -- If the server enforces HoldDuration, it falls back to the normal hold.
    if QUICK_INTERACT.enabled and type(fireproximityprompt) == "function" then
        QUICK_INTERACT.attempts = QUICK_INTERACT.attempts + 1
        DIAG.log("INFO", "HERBS", "quick_interact_attempt", {prompt = prompt:GetFullName(), species = getHerbPromptName(prompt), age = select(2, getHerbMetadata(prompt)), holdDuration = holdDuration})
        local quickOk, quickErr = pcall(fireproximityprompt, prompt, 0)
        if quickOk then
            local deadline = os.clock() + 0.55
            while os.clock() < deadline do
                local picked = false
                pcall(function() picked = prompt.Parent and prompt.Parent:GetAttribute("Picked") == true end)
                if herbInventoryRevision > (inventoryBefore or 0) or not prompt.Parent or not prompt.Enabled or picked then
                    QUICK_INTERACT.successes = QUICK_INTERACT.successes + 1
                    DIAG.log("INFO", "HERBS", "quick_interact_verified", {prompt = prompt.Name, species = getHerbPromptName(prompt), age = select(2, getHerbMetadata(prompt))})
                    return true, "quick prompt (verified)"
                end
                task.wait(0.05)
            end
        else
            DIAG.log("WARN", "HERBS", "quick_interact_api_failed", {reason = tostring(quickErr)})
        end
        QUICK_INTERACT.fallbacks = QUICK_INTERACT.fallbacks + 1
        DIAG.log("WARN", "HERBS", "quick_interact_not_confirmed_fallback", {prompt = prompt.Name, holdDuration = holdDuration})
    elseif QUICK_INTERACT.enabled then
        QUICK_INTERACT.fallbacks = QUICK_INTERACT.fallbacks + 1
        DIAG.log("WARN", "HERBS", "quick_interact_api_unavailable", {prompt = prompt.Name, fallback = "normal hold"})
    end

    -- Prefer the real ProximityPrompt hold lifecycle. It respects the game's
    -- HoldDuration and lets the server validate the normal interaction.
    local began = pcall(function()
        prompt:InputHoldBegin()
    end)
    if began then
        local completed = herbWait(holdDuration + 0.12)
        pcall(function()
            prompt:InputHoldEnd()
        end)
        return completed, completed and "ProximityPrompt hold" or "cancelled"
    end

    -- Executor compatibility fallback. This still targets the actual prompt.
    if type(fireproximityprompt) == "function" then
        local ok, err = pcall(fireproximityprompt, prompt, holdDuration)
        return ok, ok and "fireproximityprompt" or tostring(err)
    end

    -- Last fallback: hold E through VirtualInputManager for the prompt's
    -- configured duration. Always release the key, including cancellation.
    local virtualInput
    local okService, service = pcall(function()
        return game:GetService("VirtualInputManager")
    end)
    if okService then
        virtualInput = service
    end
    if not virtualInput then
        return false, "no supported ProximityPrompt input method"
    end

    local keyDown = pcall(function()
        virtualInput:SendKeyEvent(true, Enum.KeyCode.E, false, game)
    end)
    if not keyDown then
        return false, "could not press E"
    end
    local completed = herbWait(holdDuration + 0.12)
    pcall(function()
        virtualInput:SendKeyEvent(false, Enum.KeyCode.E, false, game)
    end)
    return completed, completed and "VirtualInputManager E hold" or "cancelled"
end

local function getHerbResumeMode()
    if selectedAutoMode then
        return selectedAutoMode
    end
    if type(qiState) == "table" and qiState.isMeditating == true then
        return "Qi"
    end
    if type(bodyState) == "table" and bodyState.isPushingUp == true then
        return "Body"
    end
    return nil
end

local function beginHerbSweep()
    if herbCollectorBusy then
        return
    end

    local root = getCharacterParts()
    herbReturnCFrame = root and root.CFrame or nil

    herbResumeMode = getHerbResumeMode()
    herbCollectorBusy = true

    if herbResumeMode and isTrainingActive(herbResumeMode) then
        local key = herbResumeMode == "Qi" and Enum.KeyCode.M or Enum.KeyCode.P
        sendKey(key)
        task.wait(0.35)
    end
end

local function finishHerbSweep(reason)
    herbCollectorBusy = false

    -- With Auto Cultivation enabled, its normal controller will return to the
    -- best unlocked zone. Otherwise restore the user's previous position.
    if not UI.heavenly.active and not selectedAutoMode and herbReturnCFrame then
        local root = getCharacterParts()
        if root then
            pcall(function()
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
                root.CFrame = herbReturnCFrame
            end)
            task.wait(0.65)
        end
    end

    local resumeMode = herbResumeMode
    herbReturnCFrame = nil
    herbResumeMode = nil

    if not UI.heavenly.active and not selectedAutoMode and resumeMode and running and not paused then
        if not isTrainingActive(resumeMode) then
            activateTraining(resumeMode)
        end
    end

    setHerbStatus(reason or "waiting for herbs")
end

local function collectHerbPrompt(prompt, position, herbName, herbAge)
    if not prompt or not prompt.Parent or not prompt.Enabled then
        return false, "herb is no longer available"
    end

    local root = getCharacterParts()
    if not root then
        return false, "waiting for character"
    end

    local maxDistance = tonumber(prompt.MaxActivationDistance) or 10
    local distance = (root.Position - position).Magnitude
    if distance > math.max(2, maxDistance - 1.0) then
        local destination = position + Vector3.new(0, 3.0, 0)
        local look = root.CFrame.LookVector
        local moved, moveError = pcall(function()
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            root.CFrame = CFrame.new(destination, destination + look)
        end)
        if not moved then
            return false, "teleport failed: " .. tostring(moveError)
        end
        if not herbWait(1.0) then
            return false, "cancelled"
        end
        root = getCharacterParts()
        if not root then
            return false, "character unavailable after moving"
        end
        position = getHerbPromptPosition(prompt) or position
        distance = (root.Position - position).Magnitude
    end

    if not prompt.Parent or not prompt.Enabled then
        return false, "herb became unavailable before interaction"
    end
    if distance > maxDistance then
        return false, string.format("outside prompt range (%.1f/%.1f)", distance, maxDistance)
    end

    local inventoryBefore = herbInventoryRevision
    DIAG.log("INFO", "HERBS", "collect_attempt", {species = herbName, age = herbAge, prompt = prompt:GetFullName(), holdDuration = prompt.HoldDuration, distance = distance, quickInteract = QUICK_INTERACT.enabled})
    local sent, backend = holdHerbPrompt(prompt, inventoryBefore)
    if not sent then
        if backend == "cancelled" then
            return false, "cancelled"
        end
        return false, "input failed: " .. tostring(backend)
    end
    if not herbWait(0.55) then
        return false, "cancelled"
    end

    local inventoryChanged = herbInventoryRevision > inventoryBefore
    local promptConsumed = not prompt.Parent or not prompt.Enabled
    if inventoryChanged or promptConsumed then
        herbCollectedCount = herbCollectedCount + 1
        if prompt.Parent and prompt.Enabled then
            herbCollectedPrompts[prompt] = true
        end
        local ageText = herbAge and (tostring(herbAge) .. "-year") or "age unknown"
        setHerbStatus("collected " .. herbName .. " (" .. ageText .. ")")
        DIAG.log("INFO", "HERBS", "collect_verified", {species = herbName, age = herbAge, backend = backend, inventoryRevision = herbInventoryRevision})
        print("[CU AutoCultivation] Collected " .. herbName .. " (" .. ageText .. ") via " .. tostring(backend))
        return true, "collected"
    end

    herbFailedCount = herbFailedCount + 1
    DIAG.log("WARN", "HERBS", "collect_not_verified", {species = herbName, age = herbAge, backend = backend, promptEnabled = prompt and prompt.Enabled, inventoryRevision = herbInventoryRevision})
    return false, "no inventory/prompt confirmation; will retry later"
end

local function isBreakthroughPending()
    if UI.heavenly.active then return true end
    if not breakthroughEnabled then
        return false
    end
    local mode, frame = getActiveMode()
    if not mode or not frame then
        return false
    end
    local percent = getModeProgress(mode, frame)
    return percent ~= nil and percent >= 99.95
end

-- Auto Silver removed in v1.0.6 pending a verified native combat activation path.
SILVER.getNpcRoot = function() return nil end
SILVER.findTarget = function() return nil, nil, nil, nil end
SILVER.wait = function() return false end
SILVER.detectWeaponState = function() return false, "Auto Silver retired", nil end
SILVER.ensureWeaponDrawn = function() return false, "Auto Silver retired" end
SILVER.basicAttack = function() return false, "Auto Silver retired" end
SILVER.run = function() return false, "Auto Silver retired pending verified attack mechanism" end

local function runHerbCollector()
    if herbCollectorTaskRunning then
        return
    end

    herbCollectorTaskRunning = true
    task.spawn(function()
        while running and autoHerbsEnabled do
            if paused then
                setHerbStatus("paused")
                task.wait(0.25)
            elseif UI.heavenly.active or INHERITANCE.busy or CHEST.busy or CHEST.teleportActive or SILVER.busy or autoBrewBusy or cauldronPanelIsOpen() or activeTrialGui or getActiveTrialGui() or breakthroughTrialSeen or isBreakthroughPending() then
                setHerbStatus("waiting for breakthrough")
                task.wait(0.25)
            else
                local root = getCharacterParts()
                if not root then
                    setHerbStatus("waiting for character")
                    task.wait(0.5)
                else
                    local prompt, position, herbName, herbDistance, herbAge = findNearestHerbPrompt()
                    if prompt then
                        if herbAge == 1000 then
                            HERB_HOP.resetEmptyTimer("1k herb found; empty timer reset")
                        end
                        if not herbCollectorBusy then
                            beginHerbSweep()
                        end
                        herbAttemptTimes[prompt] = os.clock()
                        local ageText = herbAge and (tostring(herbAge) .. "-year") or "age unknown"
                        setHerbStatus("collecting " .. tostring(herbName) .. " (" .. ageText .. ")")
                        local ok, result = collectHerbPrompt(prompt, position, herbName, herbAge)
                        if ok then
                            -- Keep a successful prompt marked until the game disables
                            -- it for collection; this prevents repeat farming of one node.
                        elseif result == "cancelled" then
                            herbAttemptTimes[prompt] = nil
                        else
                            setHerbStatus(tostring(herbName) .. ": " .. tostring(result))
                        end
                        task.wait(0.15)
                    else
                        if herbCollectorBusy then
                            finishHerbSweep("sweep complete; checking respawns")
                        else
                            setHerbStatus("scanning enabled prompts")
                            HERB_HOP.update()
                        end
                        task.wait(HERB_MONITOR.getAgeScanInterval())
                    end
                end
            end
        end

        if herbCollectorBusy then
            finishHerbSweep("auto herb collection stopped")
        end
        herbCollectorTaskRunning = false
    end)
end

-- Live herb monitor ----------------------------------------------------------
-- Counts currently spawned CollectHerbPrompt nodes by age and source folder.
-- It does not collect or modify any herb objects.

HERB_MONITOR.isPicked = function(prompt)
    local node = prompt and prompt.Parent
    local depth = 0
    while node and depth < 6 do
        local ok, picked = pcall(function()
            return node:GetAttribute("Picked")
        end)
        if ok and picked == true then
            return true
        end
        if node.Name == "HerbSpots" or node.Name == "Herbs" then
            break
        end
        node = node.Parent
        depth = depth + 1
    end
    return false
end

HERB_MONITOR.scan = function()
    local counts = {
        Normal = {available = {[1] = 0, [10] = 0, [100] = 0, [1000] = 0, unknown = 0}, locked = 0},
        Spirit = {available = {[1] = 0, [10] = 0, [100] = 0, [1000] = 0, unknown = 0}, locked = 0},
    }
    for _, folder in ipairs(getHerbFolders()) do
        local source = folder.Name == "HerbSpots" and "Normal" or "Spirit"
        for _, node in ipairs(folder:GetDescendants()) do
            if node:IsA("ProximityPrompt") and node.Name == "CollectHerbPrompt" then
                local _, age = getHerbMetadata(node)
                local bucket = counts[source]
                if node.Enabled and not HERB_MONITOR.isPicked(node) then
                    if age == 1 or age == 10 or age == 100 or age == 1000 then
                        bucket.available[age] = bucket.available[age] + 1
                    else
                        bucket.available.unknown = bucket.available.unknown + 1
                    end
                else
                    bucket.locked = bucket.locked + 1
                end
            end
        end
    end
    return counts
end

HERB_MONITOR.update = function(force)
    if not UI.herbMonitorLabel then
        return
    end
    if not force and os.clock() - HERB_MONITOR.lastScanAt < 2 then
        return
    end
    HERB_MONITOR.lastScanAt = os.clock()
    local ok, counts = pcall(HERB_MONITOR.scan)
    if not ok then
        UI.herbMonitorLabel.Text = "Herb scan: error reading live nodes"
        return
    end
    HERB_MONITOR.ageCounts = counts
    local n, s = counts.Normal, counts.Spirit
    UI.herbMonitorLabel.Text = string.format(
        "N 1/10/100/1k %d/%d/%d/%d | S %d/%d/%d/%d | locked %d/%d",
        n.available[1], n.available[10], n.available[100], n.available[1000],
        s.available[1], s.available[10], s.available[100], s.available[1000],
        n.locked, s.locked
    )
end

-- Auto Chest, Chest Teleport and Immortal Inheritance removed in v1.0.6.
-- Compatibility stubs keep shared status/stop guards safe; no scanning,
-- prompt interaction, event listener, travel, or claim logic remains.
CHEST.setStatus = function(message)
    CHEST.activeName = tostring(message or "retired")
end
CHEST.updateMonitor = function() end
CHEST.updateFilterPicker = function() end
local BREW = {}
do
-- Auto Brew -----------------------------------------------------------------
-- Uses only the real CauldronGui buttons. It never fires game remotes.

local function getCauldronUi()
    local cauldronGui = PlayerGui:FindFirstChild("CauldronGui")
    if not cauldronGui or not cauldronGui:IsA("ScreenGui") or not cauldronGui.Enabled then
        return nil, nil, nil
    end
    local cauldronPanel = cauldronGui:FindFirstChild("CauldronPanel")
    if not cauldronPanel or not cauldronPanel.Visible then
        return cauldronGui, nil, nil
    end
    return cauldronGui, cauldronPanel, cauldronPanel:FindFirstChild("Body")
end

local function getSelectedBrewRecipeKeys()
    local selected = {}
    local count = #BREW_RECIPE_ORDER
    for offset = 0, count - 1 do
        local index = ((brewRecipeCursor - 1 + offset) % count) + 1
        local key = BREW_RECIPE_ORDER[index]
        if brewRecipeSelection[key] then
            table.insert(selected, key)
        end
    end
    return selected
end

local function advanceBrewRecipeCursor(recipeKey)
    for index, key in ipairs(BREW_RECIPE_ORDER) do
        if key == recipeKey then
            brewRecipeCursor = (index % #BREW_RECIPE_ORDER) + 1
            if SETTINGS and SETTINGS.save then SETTINGS.save("brew_recipe_cursor_advanced") end
            return
        end
    end
end

local function brewWaitFor(predicate, timeout)
    local deadline = os.clock() + (timeout or 2)
    while running and autoBrewEnabled do
        if paused or UI.heavenly.active then
            task.wait(0.1)
            deadline = deadline + 0.1
        else
            local ok, result = pcall(predicate)
            if ok and result then
                return true
            end
            if os.clock() >= deadline then
                return false
            end
            task.wait(0.025)
        end
    end
    return false
end

local function readHerbCount(entry)
    local content = entry and entry:FindFirstChild("Content")
    local countLabel = content and content:FindFirstChild("Count")
    local countText = countLabel and tostring(countLabel.Text or "") or ""
    return tonumber(string.match(countText, "x(%d+)")) or 0
end

local function buildBrewPlan(scroll, recipe)
    if not scroll or not recipe then
        return nil, "Herb picker or recipe unavailable."
    end

    local allowedAges = {}
    local selectedAgeCount = 0
    for _, age in ipairs(BREW_AGE_OPTIONS) do
        if brewAgeSelection[age] == true then
            allowedAges[age] = true
            selectedAgeCount = selectedAgeCount + 1
        end
    end
    if selectedAgeCount == 0 then
        return nil, "No brewing herb ages selected. Choose at least one age; Brew will remain idle."
    end

    local reserved = {}
    local plan = {}
    for _, ingredient in ipairs(recipe.ingredients) do
        for _ = 1, ingredient.count do
            local chosen = nil
            for _, age in ipairs(BREW_AGE_ORDER) do
                if allowedAges[age] then
                local key = "Herb_" .. tostring(ingredient.id) .. "_" .. tostring(age)
                local entry = scroll:FindFirstChild(key)
                local content = entry and entry:FindFirstChild("Content")
                local action = content and content:FindFirstChild("Action")
                local available = entry and readHerbCount(entry) or 0
                local alreadyReserved = reserved[key] or 0
                if available - alreadyReserved > 0
                    and action and action:IsA("GuiButton")
                    and action.Active and action.Text == "Choose" then
                    chosen = {
                        key = key,
                        age = age,
                        name = ingredient.name,
                    }
                    reserved[key] = alreadyReserved + 1
                    break
                end
                end -- allowed age only; disabled ages are never fallback candidates
            end
            if not chosen then
                local ageNames = {}
                for _, age in ipairs(BREW_AGE_ORDER) do
                    if allowedAges[age] then table.insert(ageNames, tostring(age) .. "y") end
                end
                return nil, "Not enough " .. ingredient.name .. " at selected age(s) [" .. table.concat(ageNames, ", ") .. "] to make " .. recipe.name .. ". Brew will wait; disabled ages will not be substituted."
            end
            table.insert(plan, chosen)
        end
    end
    return plan
end

local function ensureHerbEntryVisible(scroll, entry)
    if not scroll or not entry or not scroll:IsA("ScrollingFrame") then
        return
    end
    local canvas = scroll.CanvasPosition
    local contentY = entry.AbsolutePosition.Y - scroll.AbsolutePosition.Y + canvas.Y
    local top = canvas.Y
    local bottom = top + scroll.AbsoluteSize.Y
    local nextY = top
    if contentY < top then
        nextY = contentY
    elseif contentY + entry.AbsoluteSize.Y > bottom then
        nextY = contentY + entry.AbsoluteSize.Y - scroll.AbsoluteSize.Y
    end
    if math.abs(nextY - canvas.Y) > 1 then
        scroll.CanvasPosition = Vector2.new(canvas.X, math.max(0, nextY))
        task.wait(0.04)
    end
end

local function allBrewSlotsEmpty(body)
    local slots = body and body:FindFirstChild("Slots")
    if not slots then
        return false, "Cauldron slots were not found."
    end
    for index = 1, 3 do
        local slot = slots:FindFirstChild("Slot" .. tostring(index))
        local label = slot and slot:FindFirstChild("HerbName")
        if not label then
            return false, "Slot " .. tostring(index) .. " is missing its HerbName label."
        end
        if tostring(label.Text) ~= "Add herb" then
            return false, "Cauldron has existing selections. Empty all 3 slots before enabling Auto Brew."
        end
    end
    return true
end

local function fillBrewSlots(panel, body, recipe)
    local slots = body and body:FindFirstChild("Slots")
    local picker = panel and panel:FindFirstChild("HerbPicker")
    local scroll = picker and picker:FindFirstChild("Scroll")
    if not slots or not picker or not scroll then
        return false, "Cauldron slot/picker hierarchy is incomplete."
    end

    local empty, emptyReason = allBrewSlotsEmpty(body)
    if not empty then
        return false, emptyReason
    end

    -- The game lazily populates HerbPicker.Scroll when the first slot is opened.
    -- Open it before reading counts; this avoids planning against an empty list.
    if not picker.Visible then
        local firstSlot = slots:FindFirstChild("Slot1")
        local opened, openBackend = clickGuiButton(firstSlot)
        if not opened then
            return false, "Could not open the first herb slot: " .. tostring(openBackend)
        end
        if not brewWaitFor(function()
            if not picker.Visible then
                return false
            end
            for _, child in ipairs(scroll:GetChildren()) do
                if string.match(child.Name, "^Herb_%d+_%d+$") then
                    return true
                end
            end
            return false
        end, 2) then
            return false, "Herb picker did not populate after opening Slot 1."
        end
        task.wait(0.15)
    end

    local plan, planError = buildBrewPlan(scroll, recipe)
    if not plan then
        return false, planError
    end

    local planText = {}
    for index, item in ipairs(plan) do
        planText[index] = tostring(item.age) .. "y " .. item.name
    end
    setStatus("Selecting oldest available ingredients: " .. table.concat(planText, ", "), COLORS.warning)

    for index, item in ipairs(plan) do
        if not running or not autoBrewEnabled then
            return false, "Auto Brew was disabled."
        end
        local slot = slots:FindFirstChild("Slot" .. tostring(index))
        if not slot or not slot:IsA("GuiButton") then
            return false, "Slot " .. tostring(index) .. " is not clickable."
        end

        if not picker.Visible then
            local slotClicked, slotBackend = clickGuiButton(slot)
            if not slotClicked then
                return false, "Could not open slot " .. tostring(index) .. ": " .. tostring(slotBackend)
            end
            if not brewWaitFor(function() return picker.Visible end, 2) then
                return false, "Herb picker did not open for slot " .. tostring(index) .. "."
            end
        end

        local entry = scroll:FindFirstChild(item.key)
        if entry then
            ensureHerbEntryVisible(scroll, entry)
        end
        local content = entry and entry:FindFirstChild("Content")
        local action = content and content:FindFirstChild("Action")
        if not action or not action:IsA("GuiButton") or not action.Active or action.Text ~= "Choose" then
            return false, "Selected herb is no longer available: " .. item.key
        end
        if readHerbCount(entry) <= 0 then
            return false, "Herb count reached zero for " .. item.key
        end

        local chosen, chooseBackend = clickGuiButton(action)
        if not chosen then
            return false, "Could not choose " .. item.name .. ": " .. tostring(chooseBackend)
        end

        local expectedTier = tostring(item.age) .. "-Year"
        local selected = brewWaitFor(function()
            local nameLabel = slot:FindFirstChild("HerbName")
            local tierLabel = slot:FindFirstChild("Tier")
            return nameLabel and tierLabel
                and nameLabel.Text == item.name
                and tierLabel.Text == expectedTier
                and not picker.Visible
        end, 2)
        if not selected then
            return false, "Slot " .. tostring(index) .. " did not confirm " .. item.name .. " (" .. expectedTier .. ")."
        end
    end

    -- Final exact recipe verification before the irreversible Brew click.
    for index, item in ipairs(plan) do
        local slot = slots:FindFirstChild("Slot" .. tostring(index))
        local nameLabel = slot and slot:FindFirstChild("HerbName")
        local tierLabel = slot and slot:FindFirstChild("Tier")
        if not nameLabel or not tierLabel
            or nameLabel.Text ~= item.name
            or tierLabel.Text ~= tostring(item.age) .. "-Year" then
            return false, "Final slot verification failed; Brew was not clicked."
        end
    end

    return true, planText
end

local function fillNextSelectedBrewRecipe(panel, body)
    local keys = getSelectedBrewRecipeKeys()
    if #keys == 0 then
        return nil, "No pill recipes selected. Open PILLS and select at least one recipe."
    end

    local missing = {}
    for _, key in ipairs(keys) do
        local recipe = BREW_RECIPES[key]
        if recipe then
            local filled, result = fillBrewSlots(panel, body, recipe)
            if filled then
                return key, result
            end
            local reason = tostring(result or "Unknown recipe error")
            if string.find(reason, "Not enough ", 1, true) then
                table.insert(missing, reason)
            else
                return nil, reason
            end
        end
    end

    if #missing > 0 then
        return nil, "Waiting for ingredients for selected pills. " .. table.concat(missing, " | ")
    end
    return nil, "No selected pill recipe is currently available."
end

local function getStokeGeometry(stoke)
    local bar = stoke and stoke:FindFirstChild("HeatBar", true)
    local flame = bar and bar:FindFirstChild("Flame", true)
    local gold = bar and bar:FindFirstChild("GoldBand", true)
    local perfect = gold and gold:FindFirstChild("Perfect", true)
    local button = stoke and stoke:FindFirstChild("Stoke", true)
    if not bar or not flame or not perfect or not button or not button:IsA("GuiButton") then
        return nil
    end
    local barWidth = bar.AbsoluteSize.X
    if barWidth <= 0 or flame.AbsoluteSize.X <= 0 or perfect.AbsoluteSize.X <= 0 then
        return nil
    end
    local flameCenter = (flame.AbsolutePosition.X + flame.AbsoluteSize.X / 2 - bar.AbsolutePosition.X) / barWidth
    local perfectCenter = (perfect.AbsolutePosition.X + perfect.AbsoluteSize.X / 2 - bar.AbsolutePosition.X) / barWidth
    return {
        barWidth = barWidth,
        flameCenter = flameCenter,
        perfectCenter = perfectCenter,
        button = button,
    }
end

local function processAutoStoke(stoke)
    local serial = cauldronBrewSerial
    if cauldronStokeHandledSerial == serial then
        return true
    end
    if lastStokeRoot == stoke and os.clock() - lastStokeClickAt < 2.0 then
        return true
    end

    local startedAt = os.clock()
    local previousCenter = nil

    while running and autoBrewEnabled and not UI.heavenly.active
        and stoke and stoke.Parent and stoke.Visible
        and serial == cauldronBrewSerial do

        if paused then
            task.wait(0.08)
            startedAt = startedAt + 0.08
        else
            if os.clock() - startedAt >= 6.0 then
                break
            end
            local geometry = getStokeGeometry(stoke)
            if geometry then
                local target = cauldronStartZone
                if type(target) ~= "number" or target < 0 or target > 1
                    or math.abs(target - geometry.perfectCenter) > 0.04 then
                    target = geometry.perfectCenter
                end

                local current = geometry.flameCenter
                local crossed = previousCenter ~= nil
                    and (previousCenter - target) * (current - target) <= 0
                local nearCenter = math.abs(current - target) <= 0.0065

                if crossed or nearCenter then
                    local offsetPixels = (current - target) * geometry.barWidth
                    local sent, backend = clickGuiButton(geometry.button)
                    cauldronStokeHandledSerial = serial
                    lastStokeRoot = stoke
                    lastStokeClickAt = os.clock()
                    if sent then
                        setStatus(
                            "Auto Stoke at " .. string.format("%.2fpx", offsetPixels)
                                .. " from Perfect center; waiting for server result.",
                            COLORS.success
                        )
                        print("[CU AutoCultivation] Auto Stoke target=" .. string.format("%.5f", target)
                            .. " flame=" .. string.format("%.5f", current)
                            .. " offsetPx=" .. string.format("%.2f", offsetPixels)
                            .. " via " .. tostring(backend))
                    else
                        setStatus("Auto Stoke activation failed: " .. tostring(backend), COLORS.danger)
                    end
                    return sent
                end

                previousCenter = current
            end
            RunService.RenderStepped:Wait()
        end
    end

    if stoke and stoke.Parent and stoke.Visible and autoBrewEnabled and serial == cauldronBrewSerial then
        cauldronStokeHandledSerial = serial
        setStatus("Stoke window expired before a reliable Perfect-center crossing; not spamming clicks.", COLORS.danger)
        return false
    end
    return true
end

local function cauldronUiReturnedToIdle(body)
    local status = body and body:FindFirstChild("Status")
    local slots = body and body:FindFirstChild("Slots")
    if not status or not slots or status.Text ~= "Choose 3 herbs to brew a pill." then
        return false
    end
    for index = 1, 3 do
        local slot = slots:FindFirstChild("Slot" .. tostring(index))
        local nameLabel = slot and slot:FindFirstChild("HerbName")
        if not nameLabel or nameLabel.Text ~= "Add herb" then
            return false
        end
    end
    return true
end

local function clickBrewClaim(body, expectedValid)
    local claimButton = body and body:FindFirstChild("Brew")
    if not claimButton or not claimButton:IsA("GuiButton")
        or claimButton.Text ~= "Claim" or not claimButton.Visible then
        return false, "The cauldron's actual Claim button is not ready."
    end
    if expectedValid ~= true then
        return false, "The server has not validated this brew as a valid pill; Claim was not clicked."
    end

    local inventoryRevisionBefore = cauldronPillInventoryRevision
    cauldronClaimResult = nil
    local sent, backend = clickGuiButton(claimButton)
    if not sent then
        return false, "Could not activate the actual Claim button: " .. tostring(backend)
    end

    local confirmed = brewWaitFor(function()
        if cauldronClaimResult and cauldronClaimResult.success == false then
            return true
        end
        local serverConfirmed = cauldronClaimResult and cauldronClaimResult.success == true
        local inventoryConfirmed = cauldronPillInventoryRevision > inventoryRevisionBefore
        return (serverConfirmed or inventoryConfirmed) and cauldronUiReturnedToIdle(body)
    end, 5)

    if not confirmed then
        return false, "Claim was clicked, but server/inventory confirmation and empty slots were not both observed. Auto Brew will stop to prevent duplicate claims."
    end
    if cauldronClaimResult and cauldronClaimResult.success == false then
        return false, "Server rejected the Claim: " .. tostring(cauldronClaimResult.message or "unknown reason")
    end
    if not cauldronUiReturnedToIdle(body) then
        return false, "Claim response arrived, but the cauldron has not returned to its empty-slot state."
    end
    return true, "claimed and verified"
end

local function runAutoBrew()
    if autoBrewTaskRunning then
        return
    end
    autoBrewTaskRunning = true
    task.spawn(function()
        while running and autoBrewEnabled do
            if paused then
                task.wait(0.15)
            elseif UI.heavenly.active or INHERITANCE.busy or CHEST.busy or SILVER.busy then
                setStatus("Auto Brew waiting for tribulation, inheritance, chest, or Silver activity to finish.", COLORS.warning)
                task.wait(0.2)
            else
                local cauldronGui, cauldronPanel, body = getCauldronUi()
                if not cauldronPanel or not body then
                    autoBrewBusy = false
                    setStatus("Auto Brew is ON. Open the Alchemy Cauldron to begin.", COLORS.warning)
                    task.wait(0.4)
                else
                    autoBrewBusy = true
                    if activeTrialGui or getActiveTrialGui() then
                        setStatus("Auto Brew waiting for the active tribulation to finish.", COLORS.warning)
                        task.wait(0.2)
                    else
                        local stoke = cauldronGui:FindFirstChild("StokeTheFire")
                        if stoke and stoke.Visible then
                            processAutoStoke(stoke)
                            task.wait(0.04)
                        else
                            local statusObject = body:FindFirstChild("Status")
                            local statusText = statusObject and tostring(statusObject.Text or "") or ""
                            local brew = body:FindFirstChild("Brew")

                            if string.find(statusText, "Brewing", 1, true) then
                                setStatus(statusText .. " | Auto Brew waiting.", COLORS.muted)
                                task.wait(0.15)
                            elseif brew and brew:IsA("GuiButton") and brew.Visible and brew.Text == "Claim" then
                                local record = type(cauldronState) == "table" and cauldronState.record or nil
                                local readyText = statusText
                                -- The ready-state UI is also authoritative if the script was
                                -- attached after CauldronStateUpdate had already fired.
                                local readyFromUi = string.find(readyText, " is ready!", 1, true) ~= nil
                                local valid = (type(record) == "table" and record.valid == true) or readyFromUi
                                local tier = type(record) == "table" and tonumber(record.tier) or nil
                                tier = tier or tonumber(string.match(readyText, "Tier%s+(%d+)"))
                                local pillKey = type(record) == "table" and tostring(record.pillKey or "Pill") or nil
                                pillKey = pillKey or string.match(readyText, "^(.-)%s*%(") or "Pill"
                                local claimed, claimMessage = clickBrewClaim(body, valid)
                                if claimed then
                                    cauldronLastTier = tier
                                    setStatus("Claimed " .. pillKey .. (tier and (" | Tier " .. tostring(tier)) or "") .. ". Inventory and cauldron reset verified; moving to next selected pill.", COLORS.success)
                                    cauldronState = nil
                                    cauldronStartResult = nil
                                    cauldronStartZone = nil
                                    cauldronStokeResult = nil
                                    cauldronBrewComplete = nil
                                    cauldronClaimResult = nil
                                    task.wait(0.3)
                                else
                                    autoBrewEnabled = false
                                    autoBrewBusy = false
                                    updateModeButtons()
                                    setStatus(claimMessage .. " BREW switched OFF; claim manually if needed.", COLORS.danger)
                                    task.wait(0.3)
                                end
                            elseif brew and brew:IsA("GuiButton") and brew.Visible and brew.Text == "Dismiss" then
                                autoBrewEnabled = false
                                autoBrewBusy = false
                                updateModeButtons()
                                setStatus("The cauldron returned Dismiss instead of Claim. Auto Brew stopped; no pill was counted as claimed.", COLORS.danger)
                                task.wait(0.3)
                            elseif brew and brew:IsA("GuiButton") and brew.Visible and brew.Text == "Brew"
                                and string.find(statusText, "Choose 3 herbs", 1, true) then
                                local recipeKey, fillResult = fillNextSelectedBrewRecipe(cauldronPanel, body)
                                local recipe = recipeKey and BREW_RECIPES[recipeKey] or nil
                                if not recipe then
                                    setStatus(tostring(fillResult), COLORS.warning)
                                    DIAG.log("INFO", "ALCHEMY", "waiting_for_selected_age_ingredients", {reason = tostring(fillResult), ageSelection = brewAgeSelection})
                                    task.wait(0.7)
                                else
                                    -- Exact recipe and each selected herb age were verified before the irreversible Brew click.
                                    cauldronState = nil
                                    cauldronStartResult = nil
                                    cauldronStartZone = nil
                                    cauldronStokeResult = nil
                                    cauldronBrewComplete = nil
                                    cauldronClaimResult = nil
                                    local sent, backend = clickGuiButton(brew)
                                    if not sent then
                                        setStatus("Brew button activation failed: " .. tostring(backend), COLORS.danger)
                                        task.wait(0.4)
                                    else
                                        setStatus("Started " .. recipe.name .. " using selected-age ingredients. Waiting for game validation.", COLORS.success)
                                        local gotRecord = brewWaitFor(function()
                                            return type(cauldronState) == "table" and type(cauldronState.record) == "table"
                                        end, 3)
                                        if not gotRecord then
                                            autoBrewEnabled = false
                                            autoBrewBusy = false
                                            updateModeButtons()
                                            setStatus("No CauldronStateUpdate record received. Auto Brew stopped safely.", COLORS.danger)
                                        elseif cauldronState.record.valid ~= true then
                                            setStatus("Game rejected the selected recipe. Waiting for result; no further batch will start.", COLORS.danger)
                                        else
                                            advanceBrewRecipeCursor(recipeKey)
                                            local tier = tonumber(cauldronState.record.tier)
                                            local pillKey = tostring(cauldronState.record.pillKey or recipeKey)
                                            setStatus("Recipe validated: " .. pillKey .. (tier and (" | Tier " .. tostring(tier)) or "") .. ". Waiting for Stoke and brew completion.", COLORS.success)
                                        end
                                        task.wait(0.2)
                                    end
                                end
                            else
                                setStatus("Auto Brew ready. Waiting for an idle cauldron and 3 empty ingredient slots.", COLORS.muted)
                                task.wait(0.25)
                            end
                        end
                    end
                end
            end
        end
        autoBrewBusy = false
        autoBrewTaskRunning = false
    end)
end

local function getBrewAgeFilterSummary()
    local selected = {}
    for _, age in ipairs(BREW_AGE_OPTIONS) do
        if brewAgeSelection[age] then
            table.insert(selected, age == 1000 and "1K" or tostring(age))
        end
    end
    if #selected == 0 then return "BREW AGE: NONE" end
    if #selected == #BREW_AGE_OPTIONS then return "BREW AGE: ALL" end
    return "BREW AGE: " .. table.concat(selected, "/")
end

local function updateBrewAgeFilterPicker()
    for age, button in pairs(UI.brewAgeFilterToggleButtons) do
        if button then
            local selected = brewAgeSelection[age] == true
            button.Text = (selected and "[ON] " or "[  ] ") .. (age == 1000 and "1,000 years" or (tostring(age) .. " years"))
            button.BackgroundColor3 = selected and COLORS.success or COLORS.panel2
        end
    end
    if UI.brewAgeFilterButton then
        UI.brewAgeFilterButton.Text = getBrewAgeFilterSummary()
        local count = 0
        for _, age in ipairs(BREW_AGE_OPTIONS) do
            if brewAgeSelection[age] then count = count + 1 end
        end
        UI.brewAgeFilterButton.BackgroundColor3 = count == #BREW_AGE_OPTIONS and COLORS.panel2 or (count == 0 and COLORS.danger or COLORS.accent)
    end
end

local function getBrewRecipeSummary()
    local selected = {}
    for _, key in ipairs(BREW_RECIPE_ORDER) do
        if brewRecipeSelection[key] then
            table.insert(selected, BREW_RECIPES[key].short)
        end
    end
    if #selected == 0 then
        return "PILLS: NONE"
    elseif #selected == 1 then
        return "PILLS: " .. selected[1]
    elseif #selected == 2 then
        return "PILLS: " .. selected[1] .. "+" .. selected[2]
    end
    return "PILLS: " .. tostring(#selected) .. " ON"
end

local function updateBrewRecipePicker()
    for key, button in pairs(brewRecipeToggleButtons) do
        local selected = brewRecipeSelection[key] == true
        local short = BREW_RECIPES[key] and BREW_RECIPES[key].short or key
        if button then
            button.Text = (selected and "[ON] " or "[  ] ") .. short
            button.BackgroundColor3 = selected and COLORS.success or COLORS.panel2
        end
    end
end



    BREW.run = runAutoBrew
    BREW.getSummary = getBrewRecipeSummary
    BREW.updatePicker = updateBrewRecipePicker
    -- These helpers live inside this do-scope but are called by GUI code
    -- outside it. Export them explicitly so createGui/updateModeButtons
    -- never resolve them as nil globals.
    BREW.getAgeFilterSummary = getBrewAgeFilterSummary
    BREW.updateAgeFilterPicker = updateBrewAgeFilterPicker
end

HERB_MONITOR.getSpeciesFilterSummary = function()
    local count = 0
    for _, species in ipairs(HERB_SPECIES) do
        if herbSpeciesSelection[species] then
            count = count + 1
        end
    end
    if count == #HERB_SPECIES then
        return "HERB FILTER: ALL"
    elseif count == 0 then
        return "HERB FILTER: NONE"
    end
    return "HERB FILTER: " .. tostring(count) .. "/" .. tostring(#HERB_SPECIES)
end

local function updateHerbFilterPicker()
    for species, button in pairs(herbFilterToggleButtons) do
        if button then
            local selected = herbSpeciesSelection[species] == true
            button.Text = (selected and "[ON] " or "[  ] ") .. species
            button.BackgroundColor3 = selected and COLORS.success or COLORS.panel2
        end
    end
    if herbFilterButton then
        herbFilterButton.Text = HERB_MONITOR.getSpeciesFilterSummary()
        local count = 0
        for _, species in ipairs(HERB_SPECIES) do
            if herbSpeciesSelection[species] then count = count + 1 end
        end
        herbFilterButton.BackgroundColor3 = count == #HERB_SPECIES and COLORS.panel2 or (count == 0 and COLORS.danger or COLORS.accent)
    end
end

HERB_MONITOR.getAgeFilterSummary = function()
    local count = 0
    for _, age in ipairs(HERB_MONITOR.ageOptions) do
        if HERB_MONITOR.ageSelection[age] then count = count + 1 end
    end
    if count == #HERB_MONITOR.ageOptions then return "HERB AGE: ALL" end
    if count == 1 and HERB_MONITOR.ageSelection[1000] then return "HERB AGE: 1K ONLY" end
    if count == 0 then return "HERB AGE: NONE" end
    return "HERB AGE: " .. tostring(count) .. "/4"
end

HERB_MONITOR.updateAgeFilterPicker = function()
    for age, button in pairs(UI.herbAgeFilterToggleButtons) do
        if button then
            local selected = HERB_MONITOR.ageSelection[age] == true
            local ageText = age == 1000 and "1,000 years" or (tostring(age) .. " years")
            button.Text = (selected and "[ON] " or "[  ] ") .. ageText
            button.BackgroundColor3 = selected and COLORS.success or COLORS.panel2
        end
    end
    if UI.herbAgeFilterButton then
        UI.herbAgeFilterButton.Text = HERB_MONITOR.getAgeFilterSummary()
        local count = 0
        for _, age in ipairs(HERB_MONITOR.ageOptions) do
            if HERB_MONITOR.ageSelection[age] then count = count + 1 end
        end
        UI.herbAgeFilterButton.BackgroundColor3 = count == #HERB_MONITOR.ageOptions and COLORS.panel2 or (count == 0 and COLORS.danger or COLORS.accent)
    end
end

updateModeButtons = function()
    if qiButton then
        qiButton.Text = selectedAutoMode == "Qi" and "QI AUTO: ON" or "QI AUTO: OFF"
        qiButton.BackgroundColor3 = selectedAutoMode == "Qi" and COLORS.qi or COLORS.panel2
    end
    if bodyButton then
        bodyButton.Text = selectedAutoMode == "Body" and "BODY AUTO: ON" or "BODY AUTO: OFF"
        bodyButton.BackgroundColor3 = selectedAutoMode == "Body" and COLORS.body or COLORS.panel2
    end
    if breakthroughButton then
        breakthroughButton.Text = breakthroughEnabled and "BREAKTHROUGH: ON" or "BREAKTHROUGH: OFF"
        breakthroughButton.BackgroundColor3 = breakthroughEnabled and COLORS.success or COLORS.panel2
    end
    if antiAfkButton then
        antiAfkButton.Text = antiAfkEnabled and "ANTI-AFK: ON" or "ANTI-AFK: OFF"
        antiAfkButton.BackgroundColor3 = antiAfkEnabled and COLORS.success or COLORS.panel2
    end
    if herbButton then
        herbButton.Text = autoHerbsEnabled and "HERBS: ON" or "HERBS: OFF"
        herbButton.BackgroundColor3 = autoHerbsEnabled and COLORS.success or COLORS.panel2
    end
    if brewButton then
        brewButton.Text = autoBrewEnabled and "BREW: ON" or "BREW: OFF"
        brewButton.BackgroundColor3 = autoBrewEnabled and COLORS.success or COLORS.panel2
    end
    if UI.quickInteractButton then
        UI.quickInteractButton.Text = QUICK_INTERACT.enabled and "INSTANT HERB: ON" or "INSTANT HERB: OFF"
        UI.quickInteractButton.BackgroundColor3 = QUICK_INTERACT.enabled and COLORS.success or COLORS.panel2
    end
    if UI.autoHopNo1kButton then
        UI.autoHopNo1kButton.Text = HERB_HOP.enabled and "AUTO HOP: NO 1K HERBS ON" or "AUTO HOP: NO 1K HERBS OFF"
        UI.autoHopNo1kButton.BackgroundColor3 = HERB_HOP.enabled and COLORS.success or COLORS.panel2
    end
    if brewRecipeButton then
        local selectedCount = 0
        for _, key in ipairs(BREW_RECIPE_ORDER) do
            if brewRecipeSelection[key] then
                selectedCount = selectedCount + 1
            end
        end
        brewRecipeButton.Text = BREW.getSummary()
        brewRecipeButton.BackgroundColor3 = selectedCount > 0 and COLORS.panel2 or COLORS.danger
    end
    BREW.updatePicker()
    BREW.updateAgeFilterPicker()
    updateHerbFilterPicker()
    HERB_MONITOR.updateAgeFilterPicker()
    if herbInfoLabel then
        herbInfoLabel.Text = string.format("Herbs: %d collected | %s", herbCollectedCount, herbActiveName)
    end
    HERB_MONITOR.update(false)
    ECONOMY.updateUI()
    if SILVER.setStatus then SILVER.setStatus(SILVER.activeName) end
end

REJOIN.requestHttp = function()
    local candidates = {}
    local ok, value = pcall(function() return Env.request end)
    if ok and type(value) == "function" then table.insert(candidates, value) end
    ok, value = pcall(function() return Env.http_request end)
    if ok and type(value) == "function" then table.insert(candidates, value) end
    ok, value = pcall(function() return Env.syn and Env.syn.request end)
    if ok and type(value) == "function" then table.insert(candidates, value) end
    ok, value = pcall(function() return _G.request end)
    if ok and type(value) == "function" then table.insert(candidates, value) end
    ok, value = pcall(function() return _G.http_request end)
    if ok and type(value) == "function" then table.insert(candidates, value) end
    return candidates[1]
end

REJOIN.setStatus = function(message, color)
    REJOIN.status = tostring(message or "ready")
    if UI.settingsStatusLabel then UI.settingsStatusLabel.Text = REJOIN.status end
    setStatus(REJOIN.status, color or COLORS.warning)
end

REJOIN.rejoinPrivateServer = function()
    if REJOIN.busy then return false end
    if game.PrivateServerId == nil or game.PrivateServerId == "" then
        REJOIN.setStatus("This is not a private server. Use Server Hop instead.", COLORS.danger)
        return false
    end
    if game.JobId == nil or game.JobId == "" then
        REJOIN.setStatus("Current server JobId is unavailable; cannot target this instance.", COLORS.danger)
        return false
    end
    if not SETTINGS.saveBeforeTravel("private_server_rejoin") then return false end

    REJOIN.busy = true
    REJOIN.lastPrivateServerId = game.PrivateServerId
    REJOIN.lastPrivateJobId = game.JobId
    DIAG.log("INFO", "REJOIN", "private_rejoin_requested", {
        placeId = game.PlaceId, privateServerId = game.PrivateServerId,
        jobId = game.JobId, ownerId = game.PrivateServerOwnerId
    })
    REJOIN.setStatus("Requesting rejoin to the same live private-server instance...", COLORS.warning)
    local ok, err = pcall(function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
    end)
    if not ok then
        REJOIN.busy = false
        DIAG.log("ERROR", "REJOIN", "private_rejoin_failed", {reason = tostring(err), jobId = game.JobId})
        REJOIN.setStatus("Private rejoin failed: " .. tostring(err) .. ". If that instance closed, rejoin through the private-server page/link.", COLORS.danger)
        return false
    end
    REJOIN.setStatus("Private rejoin requested. Auto Execute should reload saved settings after arrival.", COLORS.success)
    return true
end

REJOIN.serverHop = function()
    if REJOIN.busy then return false end
    if not SETTINGS.saveBeforeTravel("public_server_hop") then return false end
    local requestFn = REJOIN.requestHttp()
    if not requestFn then
        REJOIN.setStatus("Server Hop needs an executor HTTP request function (request/http_request).", COLORS.danger)
        return false
    end

    REJOIN.busy = true
    REJOIN.setStatus("Fetching public server list...", COLORS.warning)
    task.spawn(function()
        local url = "https://games.roblox.com/v1/games/" .. tostring(game.PlaceId)
            .. "/servers/Public?sortOrder=Asc&limit=100"
        local requestOk, response = pcall(function()
            return requestFn({Url = url, Method = "GET", Headers = {Accept = "application/json"}})
        end)
        if not requestOk or type(response) ~= "table" then
            REJOIN.busy = false
            DIAG.log("ERROR", "REJOIN", "server_list_request_failed", {reason = tostring(response)})
            REJOIN.setStatus("Server list request failed: " .. tostring(response), COLORS.danger)
            return
        end
        local statusCode = tonumber(response.StatusCode or response.Status or response.status_code)
        local body = response.Body or response.body
        if (statusCode and (statusCode < 200 or statusCode >= 300)) or type(body) ~= "string" then
            REJOIN.busy = false
            DIAG.log("ERROR", "REJOIN", "server_list_bad_response", {status = statusCode, bodyType = type(body)})
            REJOIN.setStatus("Server list returned an invalid response (" .. tostring(statusCode) .. ").", COLORS.danger)
            return
        end
        local decodeOk, decoded = pcall(function() return HttpService:JSONDecode(body) end)
        if not decodeOk or type(decoded) ~= "table" or type(decoded.data) ~= "table" then
            REJOIN.busy = false
            REJOIN.setStatus("Could not decode public server list.", COLORS.danger)
            return
        end

        local recent = {}
        for _, id in ipairs(REJOIN.recentServers) do recent[tostring(id)] = true end
        local candidates, fallback = {}, {}
        for _, server in ipairs(decoded.data) do
            local id = tostring(server.id or "")
            local playing = tonumber(server.playing) or 0
            local maxPlayers = tonumber(server.maxPlayers) or 0
            if id ~= "" and id ~= game.JobId and maxPlayers > 0 and playing < maxPlayers then
                local entry = {id = id, playing = playing, maxPlayers = maxPlayers}
                table.insert(fallback, entry)
                if not recent[id] then table.insert(candidates, entry) end
            end
        end
        if #candidates == 0 then candidates = fallback end
        if #candidates == 0 then
            REJOIN.busy = false
            REJOIN.setStatus("No other joinable public servers found on this page.", COLORS.warning)
            return
        end

        table.sort(candidates, function(a,b)
            if a.playing == b.playing then return a.id < b.id end
            return a.playing < b.playing
        end)
        local shortlist = {}
        for i = 1, math.min(12, #candidates) do shortlist[i] = candidates[i] end
        local chosen = shortlist[math.random(1, #shortlist)]
        table.insert(REJOIN.recentServers, chosen.id)
        while #REJOIN.recentServers > 12 do table.remove(REJOIN.recentServers, 1) end
        SETTINGS.save("server_hop_target_saved")
        DIAG.log("INFO", "REJOIN", "public_server_selected", {
            targetJobId = chosen.id, playing = chosen.playing,
            maxPlayers = chosen.maxPlayers, candidateCount = #candidates
        })
        REJOIN.setStatus(string.format("Joining another public server (%d/%d players)...", chosen.playing, chosen.maxPlayers), COLORS.success)
        local teleportOk, teleportErr = pcall(function()
            TeleportService:TeleportToPlaceInstance(game.PlaceId, chosen.id, LocalPlayer)
        end)
        if not teleportOk then
            REJOIN.busy = false
            DIAG.log("ERROR", "REJOIN", "server_hop_teleport_failed", {targetJobId = chosen.id, reason = tostring(teleportErr)})
            REJOIN.setStatus("Server hop failed: " .. tostring(teleportErr), COLORS.danger)
            return
        end
        REJOIN.setStatus("Server hop requested. Auto Execute should reload saved settings after arrival.", COLORS.success)
    end)
    return true
end

-- Auto Sell: uses Merchant Gao's visible Sell all / Sell 1 GUI buttons only.
-- No selling remotes are invoked. Every transaction must be confirmed by both
-- HerbInventoryUpdate and a positive Silver balance change before continuing.
local AUTO_SELL_SPECIES = {
    [1] = "Ginseng", [2] = "Azure Lotus", [3] = "Verdant Moss",
    [4] = "Golden Fern", [5] = "Violet Sage",
}

local function autoSellInventoryCount(key)
    if type(herbCounts) ~= "table" then return nil end
    return math.max(0, math.floor(tonumber(herbCounts[key]) or 0))
end

local function autoSellReservedCount(herbId, age)
    local key = tostring(herbId) .. "_" .. tostring(age)
    local availableAge = brewAgeSelection[age] == true
    if not availableAge then return 0 end
    local reserve = 0
    for recipeKey, recipe in pairs(BREW_RECIPES) do
        if brewRecipeSelection[recipeKey] == true then
            for _, ingredient in ipairs(recipe.ingredients) do
                if ingredient.id == herbId then
                    reserve = reserve + ingredient.count
                end
            end
        end
    end
    return reserve
end

local function autoSellFindMerchantRoot()
    local roots = {PlayerGui}
    for _, root in ipairs(roots) do
        for _, node in ipairs(root:GetDescendants()) do
            if (node:IsA("TextLabel") or node:IsA("TextButton"))
                and string.find(string.upper(tostring(node.Text or "")), "MERCHANT GAO", 1, true)
                and isVisibleInTree(node) then
                local ancestor = node
                for _ = 1, 8 do
                    if not ancestor or ancestor == root then break end
                    if ancestor:IsA("Frame") or ancestor:IsA("ScreenGui") then
                        local hasSell = false
                        for _, child in ipairs(ancestor:GetDescendants()) do
                            if child:IsA("TextButton") then
                                local label = string.lower(tostring(child.Text or ""))
                                if label == "sell all" or label == "sell 1" then hasSell = true break end
                            end
                        end
                        if hasSell then return ancestor end
                    end
                    ancestor = ancestor.Parent
                end
            end
        end
    end
    return nil
end

local function autoSellFindRowButtons(merchantRoot, herbId, age)
    if not merchantRoot then return nil, nil end
    local species = AUTO_SELL_SPECIES[herbId]
    if not species then return nil, nil end
    local wantedAge = tostring(age) .. "-year herb"
    local bestRow, bestDepth = nil, math.huge
    local sellAllButton, sellOneButton = nil, nil
    for _, button in ipairs(merchantRoot:GetDescendants()) do
        if button:IsA("TextButton") and isVisibleInTree(button) then
            local text = string.lower((tostring(button.Text or ""):gsub("%s+", " ")))
            if text == "sell all" or text == "sell 1" then
                local ancestor = button.Parent
                local depth = 0
                while ancestor and ancestor ~= merchantRoot and depth < 8 do
                    local labels = {}
                    for _, child in ipairs(ancestor:GetDescendants()) do
                        if child:IsA("TextLabel") or child:IsA("TextButton") then
                            table.insert(labels, string.lower(tostring(child.Text or "")))
                        end
                    end
                    local combined = table.concat(labels, " | ")
                    if string.find(combined, string.lower(species), 1, true)
                        and string.find(combined, wantedAge, 1, true) then
                        if depth < bestDepth then
                            bestDepth = depth
                            bestRow = ancestor
                            sellAllButton, sellOneButton = nil, nil
                        end
                        if ancestor == bestRow then
                            if text == "sell all" then sellAllButton = button else sellOneButton = button end
                        end
                        break
                    end
                    ancestor = ancestor.Parent
                    depth = depth + 1
                end
            end
        end
    end
    return sellAllButton, sellOneButton
end

local function autoSellWaitForConfirmation(key, beforeCount, beforeSilver, timeout)
    local startRevision = herbInventoryRevision
    local deadline = os.clock() + (timeout or 3.0)
    local inventoryConfirmed, silverConfirmed = false, false
    while running and os.clock() < deadline do
        local current = autoSellInventoryCount(key)
        local silver = tonumber(LocalPlayer:GetAttribute("Silver")) or ECONOMY.silver
        if current ~= nil and current < beforeCount and herbInventoryRevision > startRevision then
            inventoryConfirmed = true
        end
        if silver and beforeSilver and silver > beforeSilver then
            silverConfirmed = true
        end
        if inventoryConfirmed and silverConfirmed then
            local delta = silver - beforeSilver
            AUTO_SELL.soldCount = AUTO_SELL.soldCount + (beforeCount - current)
            AUTO_SELL.silverEarned = AUTO_SELL.silverEarned + delta
            ECONOMY.updateUI()
            DIAG.log("INFO", "AUTO_SELL", "sale_verified", {
                inventoryKey = key, before = beforeCount, after = current,
                quantity = beforeCount - current, silverBefore = beforeSilver,
                silverAfter = silver, silverEarned = delta,
            })
            return true, beforeCount - current, delta
        end
        task.wait(0.05)
    end
    return false, nil, nil
end

local function autoSellOneStack(herbId, age, config, merchantRoot)
    local key = tostring(herbId) .. "_" .. tostring(age)
    local count = autoSellInventoryCount(key)
    if count == nil or count <= 0 then return true, "empty" end
    local reserve = autoSellReservedCount(herbId, age)
    local sellable = math.max(0, count - reserve)
    if sellable <= 0 then return true, "reserved for Alchemy" end
    local requested = config.mode == "COUNT" and math.min(sellable, config.amount) or sellable
    if requested <= 0 then return true, "quantity is zero" end

    local sellAll, sellOne = autoSellFindRowButtons(merchantRoot, herbId, age)
    if not sellOne then return false, "Sell 1 button not found for " .. AUTO_SELL_SPECIES[herbId] .. " " .. tostring(age) .. "y" end

    -- Sell All is only safe when the entire stack is sellable and requested.
    if requested == count and reserve == 0 and config.mode ~= "COUNT" and sellAll then
        local beforeSilver = tonumber(LocalPlayer:GetAttribute("Silver")) or ECONOMY.silver
        local clicked, reason = clickGuiButton(sellAll)
        if not clicked then return false, "Sell all click failed: " .. tostring(reason) end
        local ok = autoSellWaitForConfirmation(key, count, beforeSilver, 4.0)
        if not ok then return false, "Sell all was not confirmed by inventory and Silver updates" end
        return true, "sold all"
    end

    for index = 1, requested do
        if not running or (not AUTO_SELL.enabled and not AUTO_SELL.sellNowRequested) then
            return false, "Auto Sell stopped"
        end
        if not merchantRoot.Parent or not isVisibleInTree(merchantRoot) then
            return false, "Merchant Gao window closed"
        end
        local current = autoSellInventoryCount(key)
        if current == nil or current <= reserve then return true, "inventory reserve reached" end
        local beforeSilver = tonumber(LocalPlayer:GetAttribute("Silver")) or ECONOMY.silver
        local before = current
        local _, currentSellOne = autoSellFindRowButtons(merchantRoot, herbId, age)
        if not currentSellOne then return false, "Sell 1 button disappeared" end
        local clicked, reason = clickGuiButton(currentSellOne)
        if not clicked then return false, "Sell 1 click failed: " .. tostring(reason) end
        local ok = autoSellWaitForConfirmation(key, before, beforeSilver, 3.0)
        if not ok then
            DIAG.log("WARN", "AUTO_SELL", "sale_unconfirmed_stop", {inventoryKey = key, attempt = index, before = before})
            return false, "Sale was not confirmed; stopped to prevent duplicate selling"
        end
        task.wait(0.08)
    end
    return true, "sold configured quantity"
end

local function autoSellRun()
    if AUTO_SELL.busy then return end
    AUTO_SELL.busy = true
    task.spawn(function()
        local manual = AUTO_SELL.sellNowRequested
        local merchantRoot = autoSellFindMerchantRoot()
        if not merchantRoot then
            AUTO_SELL.status = "Open Merchant Gao's Herbs window first"
            if UI.autoSellStatusLabel then UI.autoSellStatusLabel.Text = AUTO_SELL.status end
            DIAG.log("INFO", "AUTO_SELL", "merchant_not_open", {manual = manual})
            AUTO_SELL.busy = false
            AUTO_SELL.sellNowRequested = false
            return
        end
        AUTO_SELL.status = "Selling selected herb stacks..."
        if UI.autoSellStatusLabel then UI.autoSellStatusLabel.Text = AUTO_SELL.status end
        DIAG.log("INFO", "AUTO_SELL", "sale_run_started", {manual = manual})
        local stoppedReason = nil
        for herbId = 1, 5 do
            for _, age in ipairs({1, 10, 100, 1000}) do
                local key = tostring(herbId) .. "_" .. tostring(age)
                local config = AUTO_SELL.config[key]
                if config and config.enabled then
                    local ok, result = autoSellOneStack(herbId, age, config, merchantRoot)
                    if not ok then stoppedReason = result break end
                end
                if not AUTO_SELL.enabled and not AUTO_SELL.sellNowRequested then stoppedReason = "stopped" break end
            end
            if stoppedReason then break end
        end
        AUTO_SELL.status = stoppedReason and ("Stopped: " .. stoppedReason) or "Sale pass complete"
        if stoppedReason and AUTO_SELL.enabled then
            AUTO_SELL.enabled = false
            if SETTINGS.save then SETTINGS.save("auto_sell_safety_stop") end
        end
        if UI.autoSellStatusLabel then UI.autoSellStatusLabel.Text = AUTO_SELL.status end
        if UI.autoSellButton then
            UI.autoSellButton.Text = AUTO_SELL.enabled and "AUTO SELL: ON" or "AUTO SELL: OFF"
            UI.autoSellButton.BackgroundColor3 = AUTO_SELL.enabled and COLORS.success or COLORS.panel2
        end
        DIAG.log(stoppedReason and "WARN" or "INFO", "AUTO_SELL", "sale_run_finished", {
            reason = stoppedReason, soldCount = AUTO_SELL.soldCount,
            silverEarned = AUTO_SELL.silverEarned,
        })
        AUTO_SELL.busy = false
        AUTO_SELL.sellNowRequested = false
    end)
end

local function autoSellSetPresetAllExcept1000()
    for herbId = 1, 5 do
        for _, age in ipairs({1, 10, 100, 1000}) do
            local key = tostring(herbId) .. "_" .. tostring(age)
            local config = AUTO_SELL.config[key]
            config.enabled = age ~= 1000
            config.mode = "ALL"
            config.amount = 0
        end
    end
    if SETTINGS.save then SETTINGS.save("auto_sell_preset_all_except_1000") end
    DIAG.log("INFO", "AUTO_SELL", "preset_applied", {preset = "ALL_EXCEPT_1000"})
end

local function autoSellUpdateButton()
    if UI.autoSellButton then
        UI.autoSellButton.Text = AUTO_SELL.enabled and "AUTO SELL: ON" or "AUTO SELL: OFF"
        UI.autoSellButton.BackgroundColor3 = AUTO_SELL.enabled and COLORS.success or COLORS.panel2
    end
    if UI.autoSellStatusLabel then UI.autoSellStatusLabel.Text = AUTO_SELL.status end
end

local function autoSellRefreshConfig()
    for key, controls in pairs(UI.autoSellRows) do
        local config = AUTO_SELL.config[key]
        if config and controls then
            controls.enabled.Text = config.enabled and "ON" or "OFF"
            controls.enabled.BackgroundColor3 = config.enabled and COLORS.success or COLORS.panel
            controls.mode.Text = config.mode == "COUNT" and "QTY" or "ALL"
            controls.mode.BackgroundColor3 = config.mode == "COUNT" and COLORS.warning or COLORS.accent
            controls.amount.Text = tostring(config.amount or 0)
        end
    end
    autoSellUpdateButton()
end

local function createGui()
    local parent = getGuiParent()
    -- Remove every known prior suite GUI. A single chained `or` lookup only
    -- destroys the first match and can leave stale panels intercepting clicks.
    local oldGuiNames = {
        "CUAutoCultivation_v08", "CUAutoCultivation_v09", "CUAutoCultivation_v091",
        "CUAutoCultivation_v10", "CUAutoCultivation_v101", "CUAutoCultivation_v102",
        "CUAutoCultivation_v105", "CUAutoCultivation_v107", "CUAutoCultivation_v1081",
        "CUAutoCultivation_v1082", "CUAutoCultivation_v1083", "CUAutoCultivation_v10831"
    }
    for _, oldName in ipairs(oldGuiNames) do
        local old = parent:FindFirstChild(oldName)
        if old then pcall(function() old:Destroy() end) end
    end

    gui = make("ScreenGui", {
        Name = "CUAutoCultivation_v10831",
        ResetOnSpawn = false,
        IgnoreGuiInset = false,
        DisplayOrder = 999900,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    }, parent)

    panel = make("Frame", {
        Name = "Panel",
        Position = UDim2.new(0, 14, 0, 72),
        Size = UDim2.fromOffset(660, 540),
        BackgroundColor3 = COLORS.bg,
        BackgroundTransparency = 0.03,
        BorderSizePixel = 0,
        Active = true,
        Draggable = true,
        ClipsDescendants = false,
    }, gui)
    round(panel, 12)
    make("UIStroke", {Color = Color3.fromRGB(118, 91, 42), Thickness = 1.2}, panel)

    -- Persistent floating restore control: hiding the main panel never hides
    -- the only way to bring it back.
    UI.restoreButton = make("TextButton", {
        Name = "CUFloatingRestore",
        Position = UDim2.new(0, 14, 0, 72),
        Size = UDim2.fromOffset(48, 48),
        BackgroundColor3 = Color3.fromRGB(31, 39, 54),
        BorderSizePixel = 0,
        AutoButtonColor = true,
        Font = Enum.Font.GothamBold,
        Text = "CU",
        TextColor3 = Color3.fromRGB(246, 218, 157),
        TextSize = 14,
        Visible = false,
        Active = true,
        Selectable = true,
        ZIndex = 100,
    }, gui)
    round(UI.restoreButton, 24)
    make("UIStroke", {Color = Color3.fromRGB(190, 145, 65), Thickness = 1.5}, UI.restoreButton)
    addConnection(UI.restoreButton.MouseButton1Click, function()
        UI.setPanelVisible(true)
    end)

    local header = make("Frame", {
        Name = "Header",
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.new(1, 0, 0, 40),
        BackgroundColor3 = Color3.fromRGB(29, 25, 21),
        BorderSizePixel = 0,
        Active = true,
        Draggable = true,
    }, panel)
    round(header, 12)
    make("TextLabel", {
        Position = UDim2.fromOffset(14, 7),
        Size = UDim2.new(1, -110, 0, 25),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        Text = "CULTIVATION UNBOUND  |  AUTO SUITE v1.0.8.3.1",
        TextColor3 = Color3.fromRGB(246, 218, 157),
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 10,
    }, header)
    local headerState = make("TextLabel", {
        Position = UDim2.new(1, -112, 0, 8),
        Size = UDim2.fromOffset(64, 22),
        BackgroundColor3 = COLORS.success,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Text = "RUNNING",
        TextColor3 = Color3.fromRGB(15, 25, 20),
        TextSize = 9,
        ZIndex = 10,
    }, header)
    round(headerState, 6)
    UI.headerState = headerState
    local minimizeButton = make("TextButton", {
        Position = UDim2.new(1, -42, 0, 7),
        Size = UDim2.fromOffset(32, 25),
        BackgroundColor3 = COLORS.panel2,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Text = "_",
        TextColor3 = COLORS.text,
        TextSize = 14,
        ZIndex = 10,
    }, header)
    round(minimizeButton, 5)
    addConnection(minimizeButton.MouseButton1Click, function()
        UI.setPanelVisible(false)
    end)

    local pageNames = {"Overview", "Cultivation", "Farming", "Alchemy", "Economy", "Settings", "Diagnostics"}
    local pageFrames = {}
    for _, name in ipairs(pageNames) do
        local page = make("Frame", {
            Name = name .. "Page",
            Position = UDim2.fromOffset(12, 82),
            Size = UDim2.new(1, -24, 1, -132),
            BackgroundColor3 = Color3.fromRGB(23, 25, 31),
            BackgroundTransparency = 0.12,
            BorderSizePixel = 0,
            Visible = name == "Overview",
            ClipsDescendants = false,
            ZIndex = 1,
        }, panel)
        round(page, 9)
        pageFrames[name] = page
        UI.pages[name] = page
    end

    local tabWidth = 76
    for index, name in ipairs(pageNames) do
        local tab = make("TextButton", {
            Name = name .. "Tab",
            Position = UDim2.fromOffset(12 + (index - 1) * 78, 46),
            Size = UDim2.fromOffset(tabWidth, 28),
            BackgroundColor3 = name == "Overview" and COLORS.accent or COLORS.panel2,
            BorderSizePixel = 0,
            AutoButtonColor = true,
            Font = Enum.Font.GothamBold,
            Text = string.upper(name),
            TextColor3 = COLORS.text,
            TextSize = 8,
            Active = true,
            Selectable = true,
            ZIndex = 10,
        }, panel)
        round(tab, 6)
        UI.tabs[name] = tab
        addConnection(tab.MouseButton1Click, function()
            for pageName, page in pairs(pageFrames) do
                page.Visible = pageName == name
                local button = UI.tabs[pageName]
                if button then
                    button.BackgroundColor3 = pageName == name and COLORS.accent or COLORS.panel2
                end
            end
            if herbFilterPicker then herbFilterPicker.Visible = false end
            if UI.herbAgeFilterPicker then UI.herbAgeFilterPicker.Visible = false end
            if brewRecipePicker then brewRecipePicker.Visible = false end
            if UI.brewAgeFilterPicker then UI.brewAgeFilterPicker.Visible = false end
            if UI.autoSellPicker then UI.autoSellPicker.Visible = false end
        end)
    end

    local function makeLabel(parentFrame, text, x, y, w, h, size, color, font)
        return make("TextLabel", {
            Position = UDim2.fromOffset(x, y),
            Size = UDim2.fromOffset(w, h),
            BackgroundTransparency = 1,
            Font = font or Enum.Font.Gotham,
            Text = text,
            TextColor3 = color or COLORS.text,
            TextSize = size or 11,
            TextWrapped = true,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Center,
            ZIndex = 2,
        }, parentFrame)
    end

    local function makeButton(parentFrame, text, x, y, width, color, height)
        local button = make("TextButton", {
            Position = UDim2.fromOffset(x, y),
            Size = UDim2.fromOffset(width, height or 30),
            BackgroundColor3 = color or COLORS.panel2,
            BorderSizePixel = 0,
            AutoButtonColor = true,
            Font = Enum.Font.GothamBold,
            Text = text,
            TextColor3 = COLORS.text,
            TextSize = 10,
            Active = true,
            Selectable = true,
            ZIndex = 3,
        }, parentFrame)
        round(button, 6)
        return button
    end

    local function makeCard(parentFrame, x, y, w, h, titleText, accent)
        local card = make("Frame", {
            Position = UDim2.fromOffset(x, y),
            Size = UDim2.fromOffset(w, h),
            BackgroundColor3 = COLORS.panel,
            BorderSizePixel = 0,
            ZIndex = 2,
        }, parentFrame)
        round(card, 8)
        make("UIStroke", {Color = accent or Color3.fromRGB(75, 78, 89), Thickness = 1}, card)
        makeLabel(card, titleText, 11, 5, w - 22, 18, 10, COLORS.muted, Enum.Font.GothamBold)
        return card
    end

    -- OVERVIEW PAGE
    local overview = pageFrames.Overview
    makeLabel(overview, "LIVE STATUS", 16, 10, 260, 20, 11, COLORS.qi, Enum.Font.GothamBold)
    modeLabel = makeLabel(overview, "Mode: manual monitor", 16, 39, 290, 18, 11, COLORS.qi, Enum.Font.GothamBold)
    progressLabel = makeLabel(overview, "Progress: --", 16, 61, 290, 18, 10, COLORS.text)
    zoneLabel = makeLabel(overview, "Best zone: --", 16, 83, 290, 18, 10, COLORS.muted)
    statusLabel = makeLabel(overview, "Waiting...", 16, 108, 600, 34, 10, COLORS.muted)
    trialLabel = makeLabel(overview, "Trial: idle", 16, 146, 600, 18, 9, COLORS.warning)

    local silverCard = makeCard(overview, 330, 12, 282, 66, "SILVER", COLORS.warning)
    UI.overviewSilverLabel = makeLabel(silverCard, ECONOMY.formatNumber(ECONOMY.silver), 11, 26, 260, 28, 20, COLORS.text, Enum.Font.GothamBold)
    local stoneCard = makeCard(overview, 330, 88, 282, 66, "PRIMORDIAL STONES", COLORS.qi)
    UI.overviewStoneLabel = makeLabel(stoneCard, ECONOMY.formatNumber(ECONOMY.stones), 11, 26, 260, 28, 20, COLORS.text, Enum.Font.GothamBold)

    local overviewHint = makeCard(overview, 16, 184, 596, 150, "AUTOMATION STATUS", COLORS.accent)
    makeLabel(overviewHint, "Active modules: Qi cultivation, Body cultivation, breakthrough, herbs and brewing.", 12, 30, 568, 34, 11, COLORS.text)
    makeLabel(overviewHint, "Chest automation, Immortal Inheritance, Auto Silver and Experiments are removed from this release.", 12, 70, 568, 42, 10, COLORS.muted)
    makeLabel(overviewHint, "Heavenly Tribulation now uses continuous-pulse detection and feedback-based timing calibration.", 12, 116, 568, 20, 9, COLORS.warning)

    -- CULTIVATION PAGE
    local cultivationPage = pageFrames.Cultivation
    makeLabel(cultivationPage, "QI AND BODY ARE INDEPENDENT MODES; ONE CHARACTER CAN TRAIN ONLY ONE AT A TIME.", 16, 12, 600, 26, 10, COLORS.muted, Enum.Font.GothamBold)
    local qiCard = makeCard(cultivationPage, 16, 48, 292, 135, "QI CULTIVATION", COLORS.qi)
    makeLabel(qiCard, "Reads Qi realm and mastery, selects the best eligible Qi zone, then meditates.", 12, 31, 266, 43, 10, COLORS.text)
    qiButton = makeButton(qiCard, "QI AUTO: OFF", 12, 88, 266, COLORS.panel2, 32)
    local bodyCard = makeCard(cultivationPage, 322, 48, 292, 135, "BODY CULTIVATION", COLORS.body)
    makeLabel(bodyCard, "Reads Body realm and EXP, selects the best eligible Body zone, then trains.", 12, 31, 266, 43, 10, COLORS.text)
    bodyButton = makeButton(bodyCard, "BODY AUTO: OFF", 12, 88, 266, COLORS.panel2, 32)
    local breakCard = makeCard(cultivationPage, 16, 198, 598, 110, "BREAKTHROUGH ENGINE", COLORS.success)
    makeLabel(breakCard, "Shared Qi + Body per-layer breakthrough and tribulation timing. Uses the actual Breakthrough and Tap buttons.", 12, 30, 570, 38, 10, COLORS.text)
    breakthroughButton = makeButton(breakCard, "BREAKTHROUGH: ON", 12, 72, 570, COLORS.success, 28)

    -- FARMING PAGE: Chest, Inheritance and Auto Silver controls retired.
    local farmingPage = pageFrames.Farming
    makeLabel(farmingPage, "HERB COLLECTION", 16, 10, 600, 20, 11, COLORS.success, Enum.Font.GothamBold)
    local herbCard = makeCard(farmingPage, 16, 38, 598, 190, "HERB COLLECTION", COLORS.success)
    herbButton = makeButton(herbCard, "HERBS: OFF", 12, 28, 150, COLORS.panel2, 27)
    herbFilterButton = makeButton(herbCard, "HERB FILTER: ALL", 174, 28, 180, COLORS.panel2, 27)
    UI.herbAgeFilterButton = makeButton(herbCard, "HERB AGE: ALL", 12, 59, 342, COLORS.panel2, 25)
    herbInfoLabel = makeLabel(herbCard, "Herbs: 0 collected | idle", 12, 92, 560, 16, 9, COLORS.muted)
    UI.herbMonitorLabel = makeLabel(herbCard, "Normal/Spirit 1/10/100/1k: scanning...", 12, 113, 560, 45, 9, COLORS.muted, Enum.Font.Code)
    UI.quickInteractButton = makeButton(farmingPage, "INSTANT HERB: OFF", 16, 246, 598, COLORS.panel2, 27)
    UI.autoHopNo1kButton = makeButton(farmingPage, "AUTO HOP: NO 1K HERBS OFF", 16, 280, 598, COLORS.panel2, 27)
    local autoSellCard = makeCard(farmingPage, 16, 316, 598, 78, "MERCHANT GAO | AUTO SELL HERBS", COLORS.warning)
    UI.autoSellButton = makeButton(autoSellCard, "AUTO SELL: OFF", 12, 28, 180, COLORS.panel2, 27)
    UI.autoSellConfigButton = makeButton(autoSellCard, "SELL CONFIGURATION", 202, 28, 220, COLORS.accent, 27)
    UI.autoSellNowButton = makeButton(autoSellCard, "SELL NOW", 432, 28, 142, COLORS.warning, 27)
    UI.autoSellStatusLabel = makeLabel(autoSellCard, "Waiting for Merchant Gao's Herbs window.", 12, 56, 560, 16, 8, COLORS.muted)

    UI.autoSellPicker = make("Frame", {
        Name = "AutoSellConfiguration",
        Position = UDim2.fromOffset(300, 8),
        Size = UDim2.fromOffset(300, 380),
        BackgroundColor3 = COLORS.bg,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 30,
    }, farmingPage)
    round(UI.autoSellPicker, 8)
    make("UIStroke", {Color = COLORS.warning, Thickness = 1.2}, UI.autoSellPicker)
    makeLabel(UI.autoSellPicker, "MERCHANT GAO | SELL CONFIG", 10, 5, 280, 20, 10, COLORS.text, Enum.Font.GothamBold)
    UI.autoSellPresetButton = makeButton(UI.autoSellPicker, "SELL ALL EXCEPT 1,000-YEAR", 8, 29, 284, COLORS.warning, 24)
    UI.autoSellScroll = make("ScrollingFrame", {
        Position = UDim2.fromOffset(8, 59), Size = UDim2.fromOffset(284, 265),
        BackgroundColor3 = COLORS.panel, BorderSizePixel = 0, ScrollBarThickness = 5,
        CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ZIndex = 31,
    }, UI.autoSellPicker)
    make("UIListLayout", {Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder}, UI.autoSellScroll)
    for herbId = 1, 5 do
        for _, age in ipairs({1, 10, 100, 1000}) do
            local key = tostring(herbId) .. "_" .. tostring(age)
            local row = make("Frame", {
                Size = UDim2.new(1, -8, 0, 42), BackgroundColor3 = COLORS.panel2,
                BorderSizePixel = 0, ZIndex = 32,
            }, UI.autoSellScroll)
            round(row, 5)
            local speciesLabel = makeLabel(row, AUTO_SELL_SPECIES[herbId] .. " | " .. tostring(age) .. "y", 6, 2, 115, 16, 9, COLORS.text, Enum.Font.GothamBold)
            local enabledButton = makeButton(row, "OFF", 124, 7, 42, COLORS.panel, 25)
            local modeButton = makeButton(row, "ALL", 171, 7, 45, COLORS.accent, 25)
            local amountBox = make("TextBox", {
                Position = UDim2.fromOffset(222, 7), Size = UDim2.fromOffset(54, 25),
                BackgroundColor3 = COLORS.bg, BorderSizePixel = 0, ClearTextOnFocus = false,
                Font = Enum.Font.Gotham, Text = "0", TextColor3 = COLORS.text,
                TextSize = 10, PlaceholderText = "Qty", ZIndex = 34,
            }, row)
            round(amountBox, 4)
            UI.autoSellRows[key] = {enabled = enabledButton, mode = modeButton, amount = amountBox, label = speciesLabel}
            addConnection(enabledButton.MouseButton1Click, function()
                AUTO_SELL.config[key].enabled = not AUTO_SELL.config[key].enabled
                if SETTINGS.save then SETTINGS.save("auto_sell_stack_enabled") end
                autoSellRefreshConfig()
            end)
            addConnection(modeButton.MouseButton1Click, function()
                AUTO_SELL.config[key].mode = AUTO_SELL.config[key].mode == "ALL" and "COUNT" or "ALL"
                if SETTINGS.save then SETTINGS.save("auto_sell_stack_mode") end
                autoSellRefreshConfig()
            end)
            addConnection(amountBox.FocusLost, function()
                local value = math.max(0, math.floor(tonumber(amountBox.Text) or 0))
                AUTO_SELL.config[key].amount = value
                AUTO_SELL.config[key].mode = "COUNT"
                if value > 0 then AUTO_SELL.config[key].enabled = true end
                if SETTINGS.save then SETTINGS.save("auto_sell_stack_quantity") end
                autoSellRefreshConfig()
            end)
        end
    end
    UI.autoSellDoneButton = makeButton(UI.autoSellPicker, "DONE", 8, 332, 284, COLORS.accent, 25)
    for _, descendant in ipairs(UI.autoSellPicker:GetDescendants()) do
        if descendant:IsA("GuiObject") then descendant.ZIndex = 33 end
    end
    addConnection(UI.autoHopNo1kButton.MouseButton1Click, function()
        HERB_HOP.enabled = not HERB_HOP.enabled
        HERB_HOP.resetEmptyTimer(HERB_HOP.enabled and "enabled; waiting for empty-server scan" or "OFF")
        if SETTINGS.save then SETTINGS.save("auto_hop_no_1k_toggled") end
        updateModeButtons()
        DIAG.log("INFO", "HERB_HOP", "toggle_changed", {enabled = HERB_HOP.enabled, graceSeconds = HERB_HOP.graceSeconds})
        setStatus(HERB_HOP.enabled and "Auto Hop enabled. It only works with Auto Herbs ON and 1,000 YEARS ONLY selected; waits 60 seconds after a confirmed empty scan." or "Auto Hop disabled.", HERB_HOP.enabled and COLORS.success or COLORS.warning)
    end)
    addConnection(UI.autoSellButton.MouseButton1Click, function()
        AUTO_SELL.enabled = not AUTO_SELL.enabled
        AUTO_SELL.status = AUTO_SELL.enabled and "Enabled; open Merchant Gao's Herbs window to sell." or "OFF"
        if SETTINGS.save then SETTINGS.save("auto_sell_toggled") end
        autoSellRefreshConfig()
        DIAG.log("INFO", "AUTO_SELL", "toggle_changed", {enabled = AUTO_SELL.enabled})
        if AUTO_SELL.enabled then autoSellRun() end
    end)
    addConnection(UI.autoSellNowButton.MouseButton1Click, function()
        AUTO_SELL.sellNowRequested = true
        autoSellRun()
    end)
    addConnection(UI.autoSellConfigButton.MouseButton1Click, function()
        UI.autoSellPicker.Visible = not UI.autoSellPicker.Visible
        herbFilterPicker.Visible = false
        UI.herbAgeFilterPicker.Visible = false
        autoSellRefreshConfig()
    end)
    addConnection(UI.autoSellPresetButton.MouseButton1Click, function()
        autoSellSetPresetAllExcept1000()
        autoSellRefreshConfig()
        setStatus("Preset applied: sell all 1/10/100-year herbs; all 1,000-year stacks are protected.", COLORS.success)
    end)
    addConnection(UI.autoSellDoneButton.MouseButton1Click, function()
        UI.autoSellPicker.Visible = false
    end)
    autoSellRefreshConfig()

    addConnection(UI.quickInteractButton.MouseButton1Click, function()
        QUICK_INTERACT.enabled = not QUICK_INTERACT.enabled
        if SETTINGS.save then SETTINGS.save("quick_interact_toggled") end
        UI.quickInteractButton.Text = QUICK_INTERACT.enabled and "INSTANT HERB: ON" or "INSTANT HERB: OFF"
        UI.quickInteractButton.BackgroundColor3 = QUICK_INTERACT.enabled and COLORS.success or COLORS.panel2
        DIAG.log("INFO", "SETTINGS", "quick_interact_toggled", {enabled = QUICK_INTERACT.enabled})
        setStatus(QUICK_INTERACT.enabled and "Instant herb interaction enabled; server confirmation is required, with normal hold fallback." or "Instant herb interaction disabled; herbs use the configured hold duration.", QUICK_INTERACT.enabled and COLORS.success or COLORS.warning)
    end)

    -- ALCHEMY PAGE
    local alchemyPage = pageFrames.Alchemy
    makeLabel(alchemyPage, "ALCHEMY QUEUE", 16, 12, 600, 20, 11, COLORS.warning, Enum.Font.GothamBold)
    local brewCard = makeCard(alchemyPage, 16, 44, 598, 220, "AUTO BREW", COLORS.warning)
    brewButton = makeButton(brewCard, "BREW: OFF", 12, 31, 170, COLORS.panel2, 32)
    brewRecipeButton = makeButton(brewCard, BREW.getSummary(), 194, 31, 380, COLORS.panel2, 32)
    makeLabel(brewCard, "Auto Brew checks the selected recipes and ingredient ages before choosing anything.", 12, 82, 570, 30, 10, COLORS.text)
    makeLabel(brewCard, "If selected-age ingredients are unavailable, brewing waits. Disabled ages are never substituted. The Robux Finish Now option is never used.", 12, 126, 570, 42, 9, COLORS.muted)

    -- Dedicated card keeps the age control visible and independent from the
    -- Pills popup. The picker itself opens only when this button is clicked.
    local brewAgeCard = makeCard(alchemyPage, 16, 278, 598, 88, "BREW INGREDIENT AGE FILTER", COLORS.accent)
    UI.brewAgeFilterButton = makeButton(brewAgeCard, BREW.getAgeFilterSummary(), 12, 29, 574, COLORS.panel2, 28)
    makeLabel(brewAgeCard, "Only checked ages can be consumed. Choose 1, 10, 100 and/or 1,000 years.", 12, 60, 570, 18, 9, COLORS.muted)

    -- ECONOMY PAGE
    local economyPage = pageFrames.Economy
    makeLabel(economyPage, "CURRENCY AND DESTINY REROLL PLANNER", 16, 10, 600, 20, 11, COLORS.warning, Enum.Font.GothamBold)
    local economySilverCard = makeCard(economyPage, 16, 40, 292, 82, "SILVER BALANCE", COLORS.warning)
    UI.currencySilverLabel = makeLabel(economySilverCard, ECONOMY.formatNumber(ECONOMY.silver), 12, 27, 268, 32, 20, COLORS.text, Enum.Font.GothamBold)
    local economyStoneCard = makeCard(economyPage, 322, 40, 292, 82, "PRIMORDIAL STONES", COLORS.qi)
    UI.currencyStoneLabel = makeLabel(economyStoneCard, ECONOMY.formatNumber(ECONOMY.stones), 12, 27, 268, 32, 20, COLORS.text, Enum.Font.GothamBold)
    UI.economySilverDetail = makeLabel(economyPage, "NPC Silver earned this session: 0 | NPC kill rewards: 0", 16, 136, 598, 20, 10, COLORS.text)
    UI.economyRateDetail = makeLabel(economyPage, "Observed NPC reward rate: -- Silver/min", 16, 160, 598, 20, 10, COLORS.muted)
    UI.economyStoneDetail = makeLabel(economyPage, "Stone source not verified. Prior recording showed two +1 balance updates about 10m10s apart; this may be timed, but two samples are not proof.", 16, 184, 598, 38, 9, COLORS.muted)
    local oddsCard = makeCard(economyPage, 16, 230, 598, 150, "DESTINY REROLLS - ODDS FROM YOUR SCREENSHOT", COLORS.accent)
    makeLabel(oddsCard, "Common 69.89%   |   Uncommon 20%   |   Rare 8%   |   Legendary 2%", 12, 29, 570, 22, 10, COLORS.text)
    makeLabel(oddsCard, "Mythical 0.1%   |   Divine 0.01%   |   Clan single-roll cost shown: 5,000 Silver", 12, 55, 570, 22, 10, COLORS.text)
    UI.rerollOddsLabel = makeLabel(oddsCard, "At 5,000 Silver/roll: average Legendary 50 rolls / 250k; Mythical 1,000 / 5M; Divine 10,000 / 50M. About 50% chance: 35 / 693 / 6,932 rolls. Assumes no pity or batch discount.", 12, 83, 570, 54, 9, COLORS.warning)

    -- SETTINGS PAGE
    local settingsPage = pageFrames.Settings
    makeLabel(settingsPage, "SAFETY AND CONTROL", 16, 12, 600, 20, 11, COLORS.accent, Enum.Font.GothamBold)
    local safetyCard = makeCard(settingsPage, 16, 42, 598, 215, "AUTOMATION CONTROLS", COLORS.accent)
    antiAfkButton = makeButton(safetyCard, "ANTI-AFK: ON", 12, 31, 180, COLORS.success, 30)
    pauseButton = makeButton(safetyCard, "PAUSE", 204, 31, 170, COLORS.panel2, 30)
    local hideButton = makeButton(safetyCard, "HIDE PANEL", 386, 31, 188, COLORS.panel2, 30)
    local stopButton = makeButton(safetyCard, "STOP ALL", 12, 76, 562, COLORS.danger, 32)
    makeLabel(safetyCard, "Ctrl + Home: show/hide   |   Ctrl + P: pause/resume   |   Ctrl + End: stop   |   Floating CU icon restores the panel", 12, 128, 570, 35, 9, COLORS.muted)
    makeLabel(safetyCard, "Anti-AFK handles Roblox's normal Idled event only. Game-specific server AFK checks may still apply.", 12, 169, 570, 28, 9, COLORS.muted)

    local travelCard = makeCard(settingsPage, 16, 268, 598, 124, "REJOIN / SERVER HOP", COLORS.warning)
    UI.privateRejoinButton = makeButton(travelCard, "REJOIN PRIVATE SERVER", 12, 30, 276, COLORS.accent, 30)
    UI.serverHopButton = makeButton(travelCard, "SERVER HOP", 300, 30, 274, COLORS.warning, 30)
    UI.settingsStatusLabel = makeLabel(travelCard, SETTINGS.status, 12, 70, 570, 18, 9, COLORS.muted)
    makeLabel(travelCard, "Private rejoin targets this live private-server instance. Server Hop searches public servers. Auto Execute restores saved settings after arrival.", 12, 91, 570, 25, 8, COLORS.muted)

    -- DIAGNOSTICS PAGE: only logs actions and server confirmations related to this suite.
    local diagnosticsPage = pageFrames.Diagnostics
    makeLabel(diagnosticsPage, "INTEGRATED OBSERVER | ACTIONS + SERVER-ACCEPTED RESULTS ONLY", 16, 10, 600, 20, 10, COLORS.success, Enum.Font.GothamBold)
    local diagStatusCard = makeCard(diagnosticsPage, 16, 38, 598, 72, "OBSERVER STATUS", COLORS.success)
    UI.diagSummaryLabel = makeLabel(diagStatusCard, "Observer ON | waiting for events", 12, 28, 570, 18, 10, COLORS.text)
    local diagProgressCard = makeCard(diagnosticsPage, 16, 118, 598, 88, "FAST PROGRESS AUDIT (OBSERVED RATES)", COLORS.qi)
    UI.diagProgressLabel = makeLabel(diagProgressCard, "Qi UI --%/s | raw qi --/s\nBody UI --%/s | raw EXP --/s", 12, 28, 570, 48, 10, COLORS.text, Enum.Font.Code)
    local diagLogCard = makeCard(diagnosticsPage, 16, 214, 598, 150, "RECENT MODULE EVENTS (NEWEST FIRST)", COLORS.accent)
    local diagScroll = make("ScrollingFrame", {
        Position = UDim2.fromOffset(10, 28), Size = UDim2.new(1, -20, 1, -36),
        BackgroundColor3 = COLORS.bg, BorderSizePixel = 0, ScrollBarThickness = 5,
        CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ZIndex = 3,
    }, diagLogCard)
    UI.diagEventLabel = make("TextLabel", {
        Position = UDim2.fromOffset(7, 5), Size = UDim2.new(1, -17, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
        Font = Enum.Font.Code, Text = "No automation events recorded yet.",
        TextColor3 = COLORS.text, TextSize = 9, TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
        ZIndex = 4,
    }, diagScroll)
    UI.diagExportButton = makeButton(diagnosticsPage, "EXPORT DIAGNOSTICS", 16, 374, 290, COLORS.accent, 27)
    UI.diagClearButton = makeButton(diagnosticsPage, "CLEAR BUFFER", 322, 374, 292, COLORS.panel2, 27)
    addConnection(UI.diagExportButton.MouseButton1Click, function()
        local ok, message = DIAG.export()
        setStatus(ok and ("Diagnostics exported: " .. tostring(message)) or ("Diagnostics export failed: " .. tostring(message)), ok and COLORS.success or COLORS.warning)
    end)
    addConnection(UI.diagClearButton.MouseButton1Click, function()
        DIAG.events = {}
        DIAG.errorCount = 0
        DIAG.warningCount = 0
        DIAG.sequence = 0
        DIAG.log("INFO", "DIAGNOSTICS", "buffer_cleared", {})
        DIAG.refreshUI(true)
    end)

    -- Experiments page and controls removed in v1.0.6.

    -- FILTER PICKERS: placed inside their relevant tabs so they never spill
    -- outside the redesigned panel.
    herbFilterPicker = make("Frame", {
        Name = "HerbFilterPicker",
        Position = UDim2.fromOffset(390, 12),
        Size = UDim2.fromOffset(210, 218),
        BackgroundColor3 = COLORS.bg,
        BackgroundTransparency = 0.02,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 22,
    }, farmingPage)
    round(herbFilterPicker, 8)
    make("UIStroke", {Color = Color3.fromRGB(80, 96, 124), Thickness = 1}, herbFilterPicker)
    makeLabel(herbFilterPicker, "SELECT HERB SPECIES", 9, 5, 190, 18, 10, COLORS.text, Enum.Font.GothamBold)
    local allHerbsButton = makeButton(herbFilterPicker, "SELECT ALL", 8, 27, 194, COLORS.accent, 22)
    addConnection(allHerbsButton.MouseButton1Click, function()
        for _, species in ipairs(HERB_SPECIES) do herbSpeciesSelection[species] = true end
        if SETTINGS.save then SETTINGS.save("herb_species_all") end
        updateModeButtons()
        setStatus("All five normal herb species enabled. Oldest available herbs are prioritized.", COLORS.success)
    end)
    for index, species in ipairs(HERB_SPECIES) do
        local toggle = makeButton(herbFilterPicker, species, 8, 53 + (index - 1) * 27, 194, COLORS.success, 23)
        herbFilterToggleButtons[species] = toggle
        addConnection(toggle.MouseButton1Click, function()
            herbSpeciesSelection[species] = not herbSpeciesSelection[species]
            if SETTINGS.save then SETTINGS.save("herb_species_changed") end
            updateModeButtons()
            setStatus(species .. (herbSpeciesSelection[species] and " enabled for collection." or " excluded from collection."), COLORS.success)
        end)
    end
    local herbFilterDone = makeButton(herbFilterPicker, "DONE", 8, 190, 194, COLORS.accent, 22)
    addConnection(herbFilterDone.MouseButton1Click, function() herbFilterPicker.Visible = false end)

    UI.herbAgeFilterPicker = make("Frame", {
        Name = "HerbAgeFilterPicker",
        Position = UDim2.fromOffset(390, 12),
        Size = UDim2.fromOffset(210, 205),
        BackgroundColor3 = COLORS.bg,
        BackgroundTransparency = 0.02,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 22,
    }, farmingPage)
    round(UI.herbAgeFilterPicker, 8)
    make("UIStroke", {Color = Color3.fromRGB(80, 96, 124), Thickness = 1}, UI.herbAgeFilterPicker)
    makeLabel(UI.herbAgeFilterPicker, "SELECT HERB AGE", 9, 5, 190, 18, 10, COLORS.text, Enum.Font.GothamBold)
    addConnection(makeButton(UI.herbAgeFilterPicker, "SELECT ALL AGES", 8, 27, 194, COLORS.accent, 22).MouseButton1Click, function()
        for _, age in ipairs(HERB_MONITOR.ageOptions) do HERB_MONITOR.ageSelection[age] = true end
        if SETTINGS.save then SETTINGS.save("herb_age_all") end
        updateModeButtons()
        DIAG.log("INFO", "HERBS", "age_filter_preset", {preset = "ALL"})
        setStatus("All herb ages enabled; oldest available age is prioritized.", COLORS.success)
    end)
    addConnection(makeButton(UI.herbAgeFilterPicker, "1,000 YEARS ONLY", 8, 52, 194, COLORS.warning, 22).MouseButton1Click, function()
        for _, age in ipairs(HERB_MONITOR.ageOptions) do HERB_MONITOR.ageSelection[age] = (age == 1000) end
        if SETTINGS.save then SETTINGS.save("herb_age_1000_only") end
        updateModeButtons()
        DIAG.log("INFO", "HERBS", "age_filter_preset", {preset = "1000_ONLY"})
        setStatus("Strict 1,000-year-only collection enabled. Lower and unknown ages will be ignored.", COLORS.success)
    end)
    for index, age in ipairs(HERB_MONITOR.ageOptions) do
        UI.herbAgeFilterToggleButtons[age] = makeButton(UI.herbAgeFilterPicker, age == 1000 and "1,000 years" or (tostring(age) .. " years"), 8, 77 + (index - 1) * 25, 194, COLORS.success, 22)
        addConnection(UI.herbAgeFilterToggleButtons[age].MouseButton1Click, function()
            HERB_MONITOR.ageSelection[age] = not HERB_MONITOR.ageSelection[age]
            if SETTINGS.save then SETTINGS.save("herb_age_changed") end
            updateModeButtons()
            DIAG.log("INFO", "HERBS", "age_filter_changed", {age = age, enabled = HERB_MONITOR.ageSelection[age]})
            setStatus((age == 1000 and "1,000 years" or (tostring(age) .. " years")) .. (HERB_MONITOR.ageSelection[age] and " enabled." or " excluded."), COLORS.success)
        end)
    end
    addConnection(makeButton(UI.herbAgeFilterPicker, "DONE", 8, 180, 194, COLORS.accent, 20).MouseButton1Click, function() UI.herbAgeFilterPicker.Visible = false end)

    brewRecipePicker = make("Frame", {
        Name = "BrewRecipePicker",
        Position = UDim2.fromOffset(390, 12),
        Size = UDim2.fromOffset(210, 174),
        BackgroundColor3 = COLORS.bg,
        BackgroundTransparency = 0.02,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 22,
    }, alchemyPage)
    round(brewRecipePicker, 8)
    make("UIStroke", {Color = Color3.fromRGB(80, 96, 124), Thickness = 1}, brewRecipePicker)
    makeLabel(brewRecipePicker, "SELECT MULTIPLE PILLS", 9, 5, 190, 18, 10, COLORS.text, Enum.Font.GothamBold)
    local recipePickerRows = {
        {key = "QiSpeed", y = 27},
        {key = "BodySpeed", y = 54},
        {key = "Damage", y = 81},
        {key = "HP", y = 108},
    }
    for _, row in ipairs(recipePickerRows) do
        local recipe = BREW_RECIPES[row.key]
        local toggle = makeButton(brewRecipePicker, recipe.name, 8, row.y, 194, COLORS.success, 23)
        brewRecipeToggleButtons[row.key] = toggle
        addConnection(toggle.MouseButton1Click, function()
            brewRecipeSelection[row.key] = not brewRecipeSelection[row.key]
            if SETTINGS.save then SETTINGS.save("brew_recipe_changed") end
            updateModeButtons()
        end)
    end
    local recipeDone = makeButton(brewRecipePicker, "DONE", 8, 145, 194, COLORS.accent, 22)
    addConnection(recipeDone.MouseButton1Click, function() brewRecipePicker.Visible = false end)

    UI.brewAgeFilterPicker = make("Frame", {
        Name = "BrewAgeFilterPicker",
        Position = UDim2.fromOffset(390, 205),
        Size = UDim2.fromOffset(210, 166),
        BackgroundColor3 = COLORS.bg,
        BackgroundTransparency = 0.02,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 22,
    }, alchemyPage)
    round(UI.brewAgeFilterPicker, 8)
    make("UIStroke", {Color = Color3.fromRGB(80, 96, 124), Thickness = 1}, UI.brewAgeFilterPicker)
    makeLabel(UI.brewAgeFilterPicker, "ALLOWED BREW HERB AGES", 9, 5, 190, 18, 10, COLORS.text, Enum.Font.GothamBold)
    addConnection(makeButton(UI.brewAgeFilterPicker, "SELECT ALL AGES", 8, 27, 194, COLORS.accent, 22).MouseButton1Click, function()
        for _, age in ipairs(BREW_AGE_OPTIONS) do brewAgeSelection[age] = true end
        if SETTINGS.save then SETTINGS.save("brew_age_select_all") end
        updateModeButtons()
        setStatus("Alchemy may use all four selected herb ages, preferring the oldest available selected age.", COLORS.success)
    end)
    for index, age in ipairs(BREW_AGE_OPTIONS) do
        local ageText = age == 1000 and "1,000 years" or (tostring(age) .. " years")
        local toggle = makeButton(UI.brewAgeFilterPicker, ageText, 8, 53 + (index - 1) * 24, 194, COLORS.success, 21)
        UI.brewAgeFilterToggleButtons[age] = toggle
        addConnection(toggle.MouseButton1Click, function()
            brewAgeSelection[age] = not brewAgeSelection[age]
            if SETTINGS.save then SETTINGS.save("brew_age_filter_changed") end
            updateModeButtons()
            DIAG.log("INFO", "ALCHEMY", "brew_age_filter_changed", {age = age, enabled = brewAgeSelection[age]})
            setStatus("Brew age " .. tostring(age) .. " years " .. (brewAgeSelection[age] and "enabled." or "disabled. Disabled ages will never be substituted."), COLORS.success)
        end)
    end
    addConnection(makeButton(UI.brewAgeFilterPicker, "DONE", 8, 151, 194, COLORS.accent, 18).MouseButton1Click, function()
        UI.brewAgeFilterPicker.Visible = false
    end)

    for _, picker in ipairs({herbFilterPicker, UI.herbAgeFilterPicker, brewRecipePicker, UI.brewAgeFilterPicker}) do
        for _, descendant in ipairs(picker:GetDescendants()) do
            if descendant:IsA("GuiObject") then descendant.ZIndex = 23 end
        end
    end

    -- Global footer status is visible on every tab.
    footerStatusLabel = makeLabel(panel, "Ready.", 14, 510, 632, 18, 9, COLORS.muted)

    -- BUTTON CALLBACKS ------------------------------------------------------
    addConnection(qiButton.MouseButton1Click, function()
        if selectedAutoMode == "Qi" then
            selectedAutoMode = nil
            if SETTINGS.save then SETTINGS.save("qi_auto_toggled") end
            local ok, stopped, backend = stopAutomationOwnedTraining("Qi")
            if not ok then setStatus("Qi Auto is OFF, but its training input could not be stopped: " .. tostring(backend), COLORS.danger)
            elseif stopped then setStatus("Qi Auto OFF; script-started meditation stopped.", COLORS.warning)
            else setStatus("Qi Auto OFF. Manually started meditation is left alone.", COLORS.warning) end
        else
            if selectedAutoMode == "Body" then
                local ok, _, backend = stopAutomationOwnedTraining("Body")
                if not ok then setStatus("Could not stop script-started Body training; Qi was not enabled: " .. tostring(backend), COLORS.danger); return end
            end
            selectedAutoMode = "Qi"
            if SETTINGS.save then SETTINGS.save("qi_auto_toggled") end
            DIAG.log("INFO", "CULTIVATION", "qi_auto_enabled", {})
            setStatus("Qi Auto Cultivation ON. Selecting the best unlocked Qi zone.", COLORS.success)
        end
        trainingToggleAttempts = 0
        trainingToggleAt = 0
        lastTeleportTarget = nil
        updateModeButtons()
    end)

    addConnection(bodyButton.MouseButton1Click, function()
        if selectedAutoMode == "Body" then
            selectedAutoMode = nil
            if SETTINGS.save then SETTINGS.save("body_auto_toggled") end
            local ok, stopped, backend = stopAutomationOwnedTraining("Body")
            if not ok then setStatus("Body Auto is OFF, but its training input could not be stopped: " .. tostring(backend), COLORS.danger)
            elseif stopped then setStatus("Body Auto OFF; script-started push-ups stopped.", COLORS.warning)
            else setStatus("Body Auto OFF. Manually started push-ups are left alone.", COLORS.warning) end
        else
            if selectedAutoMode == "Qi" then
                local ok, _, backend = stopAutomationOwnedTraining("Qi")
                if not ok then setStatus("Could not stop script-started Qi meditation; Body was not enabled: " .. tostring(backend), COLORS.danger); return end
            end
            selectedAutoMode = "Body"
            if SETTINGS.save then SETTINGS.save("body_auto_toggled") end
            DIAG.log("INFO", "CULTIVATION", "body_auto_enabled", {})
            setStatus("Body Auto Cultivation ON. Selecting the best unlocked Body zone.", COLORS.success)
        end
        trainingToggleAttempts = 0
        trainingToggleAt = 0
        lastTeleportTarget = nil
        updateModeButtons()
    end)

    addConnection(herbButton.MouseButton1Click, function()
        autoHerbsEnabled = not autoHerbsEnabled
        if SETTINGS.save then SETTINGS.save("auto_herbs_toggled") end
        DIAG.log("INFO", "HERBS", "auto_toggle", {enabled = autoHerbsEnabled})
        updateModeButtons()
        if autoHerbsEnabled then
            setHerbStatus("scanning enabled prompts")
            setStatus("Auto Herb Collection enabled; cultivation will resume after each sweep.", COLORS.success)
            runHerbCollector()
        else
            setHerbStatus("turning off")
            setStatus("Auto Herb Collection disabled; finishing the current hold safely.", COLORS.warning)
        end
    end)

    addConnection(herbFilterButton.MouseButton1Click, function()
        herbFilterPicker.Visible = not herbFilterPicker.Visible
        UI.herbAgeFilterPicker.Visible = false
        brewRecipePicker.Visible = false
        if UI.brewAgeFilterPicker then UI.brewAgeFilterPicker.Visible = false end
        updateModeButtons()
        setStatus("Choose which herb species Auto Herbs may collect. Oldest HerbYear is prioritized.", COLORS.success)
    end)

    addConnection(UI.herbAgeFilterButton.MouseButton1Click, function()
        UI.herbAgeFilterPicker.Visible = not UI.herbAgeFilterPicker.Visible
        herbFilterPicker.Visible = false
        brewRecipePicker.Visible = false
        if UI.brewAgeFilterPicker then UI.brewAgeFilterPicker.Visible = false end
        updateModeButtons()
        setStatus("Choose herb ages. Use 1,000 YEARS ONLY to ignore every lower or unknown age and resume cultivation between spawns.", COLORS.success)
    end)

    -- Auto Chest, Immortal Inheritance and Auto Silver callbacks removed in v1.0.6.

    addConnection(brewButton.MouseButton1Click, function()
        autoBrewEnabled = not autoBrewEnabled
        if SETTINGS.save then SETTINGS.save("auto_brew_toggled") end
        updateModeButtons()
        if autoBrewEnabled then
            setStatus("Auto Brew enabled. Open the Alchemy Cauldron; only selected herb ages are eligible, preferring the oldest selected age.", COLORS.success)
            BREW.run()
        else
            setStatus("Auto Brew disabled. Current in-progress brew will be left untouched.", COLORS.warning)
        end
    end)

    addConnection(brewRecipeButton.MouseButton1Click, function()
        brewRecipePicker.Visible = not brewRecipePicker.Visible
        herbFilterPicker.Visible = false
        UI.herbAgeFilterPicker.Visible = false
        if UI.brewAgeFilterPicker then UI.brewAgeFilterPicker.Visible = false end
        updateModeButtons()
        setStatus("Select any combination of Qi, Body, Bloodfury, and Vitality pills. Auto Brew rotates through selected recipes.", COLORS.success)
    end)
    addConnection(UI.brewAgeFilterButton.MouseButton1Click, function()
        UI.brewAgeFilterPicker.Visible = not UI.brewAgeFilterPicker.Visible
        herbFilterPicker.Visible = false
        UI.herbAgeFilterPicker.Visible = false
        brewRecipePicker.Visible = false
        updateModeButtons()
        setStatus("Choose exactly which herb ages Alchemy may consume. If ingredients at selected ages are unavailable, brewing waits without using other ages.", COLORS.success)
    end)

    -- No Auto Silver or sword auto-carry controls in v1.0.6.

    addConnection(breakthroughButton.MouseButton1Click, function()
        breakthroughEnabled = not breakthroughEnabled
        if SETTINGS.save then SETTINGS.save("breakthrough_toggled") end
        updateModeButtons()
        setStatus(breakthroughEnabled and "Auto Breakthrough enabled." or "Auto Breakthrough disabled.", breakthroughEnabled and COLORS.success or COLORS.warning)
    end)

    addConnection(antiAfkButton.MouseButton1Click, function()
        antiAfkEnabled = not antiAfkEnabled
        if SETTINGS.save then SETTINGS.save("anti_afk_toggled") end
        updateModeButtons()
        setStatus(antiAfkEnabled and "Anti-AFK enabled." or "Anti-AFK disabled.", antiAfkEnabled and COLORS.success or COLORS.warning)
    end)

    addConnection(UI.privateRejoinButton.MouseButton1Click, REJOIN.rejoinPrivateServer)
    addConnection(UI.serverHopButton.MouseButton1Click, REJOIN.serverHop)

    addConnection(pauseButton.MouseButton1Click, function()
        paused = not paused
        pauseButton.Text = paused and "RESUME" or "PAUSE"
        pauseButton.BackgroundColor3 = paused and COLORS.warning or COLORS.panel2
        if UI.headerState then
            UI.headerState.Text = paused and "PAUSED" or "RUNNING"
            UI.headerState.BackgroundColor3 = paused and COLORS.warning or COLORS.success
        end
        setStatus(paused and "Paused; automation actions suspended." or "Resumed.", paused and COLORS.warning or COLORS.success)
    end)

    addConnection(hideButton.MouseButton1Click, function() UI.setPanelVisible(false) end)
    addConnection(stopButton.MouseButton1Click, function() stop("stop button") end)

    updateModeButtons()
    DIAG.log("INFO", "ALCHEMY", "brew_age_filter_ui_created", {
        button = UI.brewAgeFilterButton and UI.brewAgeFilterButton:GetFullName() or "missing",
        picker = UI.brewAgeFilterPicker and UI.brewAgeFilterPicker:GetFullName() or "missing",
        layout = "dedicated card below Auto Brew"
    })
    ECONOMY.updateUI()
    SILVER.setStatus("idle")
    autoSellRefreshConfig()
end

-- Read replicated game state. These are inbound listeners only.
do
    local eventsFolder = ReplicatedStorage:FindFirstChild("CultivationEvents")
    if not eventsFolder then
        pcall(function()
            eventsFolder = ReplicatedStorage:WaitForChild("CultivationEvents", 8)
        end)
    end

    if eventsFolder then
        local moneyRemote = eventsFolder:FindFirstChild("UpdateMoney")
        if moneyRemote and moneyRemote:IsA("RemoteEvent") then
            addConnection(moneyRemote.OnClientEvent, function(value)
                local newValue = tonumber(value)
                if newValue then
                    if ECONOMY.silver == nil then ECONOMY.silverStart = newValue end
                    ECONOMY.silver = newValue
                    ECONOMY.updateUI()
                    DIAG.log("INFO", "ECONOMY", "silver_balance_update", {silver = newValue})
                end
            end)
        end

        local stonesRemote = eventsFolder:FindFirstChild("UpdatePrimordialStones")
        if stonesRemote and stonesRemote:IsA("RemoteEvent") then
            addConnection(stonesRemote.OnClientEvent, function(value)
                local newValue = tonumber(value)
                if newValue then
                    local oldValue = ECONOMY.stones
                    if oldValue == nil then ECONOMY.stonesStart = newValue end
                    if oldValue ~= nil and newValue ~= oldValue then
                        ECONOMY.lastStoneDelta = newValue - oldValue
                        ECONOMY.lastStoneChangeAt = os.time()
                        ECONOMY.lastStoneChangeClock = os.clock()
                        if newValue > oldValue then ECONOMY.stonesEarned = ECONOMY.stonesEarned + (newValue - oldValue) end
                    end
                    ECONOMY.stones = newValue
                    ECONOMY.updateUI()
                    DIAG.log("INFO", "ECONOMY", "primordial_stone_balance_update", {stones = newValue, delta = oldValue and (newValue - oldValue) or nil})
                end
            end)
        end

        local npcSilverRemote = eventsFolder:FindFirstChild("NpcKillSilver")
        if npcSilverRemote and npcSilverRemote:IsA("RemoteEvent") then
            addConnection(npcSilverRemote.OnClientEvent, function(value)
                local amount = tonumber(value) or 0
                if amount > 0 then
                    ECONOMY.npcSilverEarned = ECONOMY.npcSilverEarned + amount
                    ECONOMY.npcKillCount = ECONOMY.npcKillCount + 1
                    SILVER.lastReward = amount
                    if SILVER.autoEnabled and SILVER.currentTarget then
                        SILVER.earned = SILVER.earned + amount
                        SILVER.kills = SILVER.kills + 1
                    end
                    ECONOMY.updateUI()
                    DIAG.log("INFO", "SILVER", "server_kill_reward", {amount = amount, target = SILVER.currentTarget and SILVER.currentTarget.Name or nil, total = ECONOMY.silver})
                    if SILVER.autoEnabled then SILVER.setStatus("Silver reward +" .. ECONOMY.formatNumber(amount) .. " received") end
                end
            end)
        end

        local qiRemote = eventsFolder:FindFirstChild("UpdateClient")
        if qiRemote and qiRemote:IsA("RemoteEvent") then
            addConnection(qiRemote.OnClientEvent, function(data)
                if type(data) == "table" then
                    qiState = data
                    DIAG.lastQiStateAt = os.clock()
                end
            end)
        end

        local bodyRemote = eventsFolder:FindFirstChild("UpdateBodyClient")
        if bodyRemote and bodyRemote:IsA("RemoteEvent") then
            addConnection(bodyRemote.OnClientEvent, function(data)
                if type(data) == "table" then
                    bodyState = data
                    DIAG.lastBodyStateAt = os.clock()
                end
            end)
        end

        local herbInventoryRemote = eventsFolder:FindFirstChild("HerbInventoryUpdate")
        if herbInventoryRemote and herbInventoryRemote:IsA("RemoteEvent") then
            addConnection(herbInventoryRemote.OnClientEvent, function(data)
                herbInventoryRevision = herbInventoryRevision + 1
                if type(data) == "table" then
                    herbCounts = data
                    lastAction = "Herb inventory update received."
                end
                setHerbStatus("inventory updated")
                DIAG.log("INFO", "HERBS", "server_inventory_update", {revision = herbInventoryRevision, inventory = data})
            end)
        end

        local cauldronStateRemote = eventsFolder:FindFirstChild("CauldronStateUpdate")
        if cauldronStateRemote and cauldronStateRemote:IsA("RemoteEvent") then
            addConnection(cauldronStateRemote.OnClientEvent, function(data)
                if type(data) == "table" then
                    cauldronState = data
                    if type(data.record) == "table" then
                        cauldronLastTier = tonumber(data.record.tier)
                    end
                end
            end)
        end

        local cauldronStartRemote = eventsFolder:FindFirstChild("CauldronStartBrewResult")
        if cauldronStartRemote and cauldronStartRemote:IsA("RemoteEvent") then
            addConnection(cauldronStartRemote.OnClientEvent, function(success, message, extra)
                cauldronStartResult = {success = success, message = message, extra = extra}
                DIAG.log(success and "INFO" or "WARN", "ALCHEMY", "brew_start_result", {success = success, message = message, extra = extra})
                cauldronStartZone = type(extra) == "table" and tonumber(extra.zone) or nil
                cauldronBrewSerial = cauldronBrewSerial + 1
                cauldronStokeHandledSerial = 0
                cauldronStokeResult = nil
                cauldronBrewComplete = nil
                cauldronClaimResult = nil
            end)
        end

        local cauldronStokeRemote = eventsFolder:FindFirstChild("CauldronStokeResult")
        if cauldronStokeRemote and cauldronStokeRemote:IsA("RemoteEvent") then
            addConnection(cauldronStokeRemote.OnClientEvent, function(result, message)
                cauldronStokeResult = {result = tostring(result or "unknown"), message = tostring(message or "")}
                DIAG.log("INFO", "ALCHEMY", "stoke_result", {result = result, message = message, target = cauldronStartZone})
                setStatus("Stoke result: " .. cauldronStokeResult.result .. " - " .. cauldronStokeResult.message, COLORS.success)
            end)
        end

        local cauldronCompleteRemote = eventsFolder:FindFirstChild("CauldronBrewComplete")
        if cauldronCompleteRemote and cauldronCompleteRemote:IsA("RemoteEvent") then
            addConnection(cauldronCompleteRemote.OnClientEvent, function(success)
                cauldronBrewComplete = success
            end)
        end

        local cauldronClaimRemote = eventsFolder:FindFirstChild("CauldronClaimResult")
        if cauldronClaimRemote and cauldronClaimRemote:IsA("RemoteEvent") then
            addConnection(cauldronClaimRemote.OnClientEvent, function(success, message)
                cauldronClaimResult = {success = success, message = message}
                DIAG.log(success and "INFO" or "WARN", "ALCHEMY", "claim_result", {success = success, message = message})
            end)
        end

        -- Inheritance and ChestWorldOpened listeners removed in v1.0.6.

        local pillInventoryRemote = eventsFolder:FindFirstChild("PillInventoryUpdate")
        if pillInventoryRemote and pillInventoryRemote:IsA("RemoteEvent") then
            addConnection(pillInventoryRemote.OnClientEvent, function(data)
                cauldronPillInventoryRevision = cauldronPillInventoryRevision + 1
            end)
        end

        -- The recorder showed this signal arrives before the trial GUI finishes
        -- constructing. Lock breakthrough retries immediately to avoid a second
        -- click while the tribulation interface is still loading.
        local startTrialRemote = eventsFolder:FindFirstChild("StartBreakthroughMinigame")
        if startTrialRemote and startTrialRemote:IsA("RemoteEvent") then
            addConnection(startTrialRemote.OnClientEvent, function()
                breakthroughTrialSeen = true
                lastTrialText = "Trial: starting..."
                setStatus("Game signalled a tribulation; waiting for its prompt UI.", COLORS.warning)
            end)
        end
    end
end

-- Destiny reroll audit: observe manual UI clicks and server completion events.
-- This records samples only; it does not automate rolls or modify RNG requests.
local function getRerollContext(button)
    local rerollGui = PlayerGui:FindFirstChild("RerollGui")
    local window = rerollGui and rerollGui:FindFirstChild("DestinyRerollWindow")
    local activeCategory = "Unknown"
    local tabBar = window and window:FindFirstChild("TabBar")
    if tabBar then
        for _, tab in ipairs(tabBar:GetChildren()) do
            if tab:IsA("GuiButton") then
                local style = tab:GetAttribute("UiStyle")
                if style == "tabActive" then
                    activeCategory = string.gsub(tab.Name, "Tab$", "")
                    break
                end
            end
        end
    end
    local bulk = "Unknown"
    local column = window and window:FindFirstChild("Body") and window.Body:FindFirstChild("Column1")
    if column then
        for _, name in ipairs({"Bulk1", "Bulk10", "Bulk100"}) do
            local item = column:FindFirstChild(name)
            if item and item:IsA("GuiButton") then
                local selected = item:GetAttribute("UiStyle") == "buttonActive" or item.BackgroundColor3 == COLORS.success
                if selected then bulk = name break end
            end
        end
    end
    local displayedOdds = {}
    if window then
        for _, node in ipairs(window:GetDescendants()) do
            if node:IsA("TextLabel") then
                local text = tostring(node.Text or "")
                local lower = string.lower(text)
                if string.find(lower, "common", 1, true)
                    or string.find(lower, "uncommon", 1, true)
                    or string.find(lower, "rare", 1, true)
                    or string.find(lower, "legendary", 1, true)
                    or string.find(lower, "mythical", 1, true)
                    or string.find(lower, "divine", 1, true)
                    or string.find(lower, "beginner luck", 1, true)
                    or string.find(lower, "2x luck", 1, true)
                    or string.find(lower, "cost", 1, true) then
                    table.insert(displayedOdds, text)
                end
            end
        end
    end
    return {
        category = activeCategory, button = button and button.Name,
        text = button and button.Text, bulk = bulk, displayedOdds = displayedOdds,
        silver = tonumber(LocalPlayer:GetAttribute("Silver")),
        stones = tonumber(LocalPlayer:GetAttribute("PrimordialStones")),
    }
end

local function watchRerollButton(object)
    if not object or DIAG.rerollWatched[object] then return end
    if not object:IsA("GuiButton") then return end
    local fullName = ""
    pcall(function() fullName = object:GetFullName() end)
    if not string.find(fullName, "DestinyRerollWindow", 1, true) then return end
    if object.Name ~= "RerollButton" and object.Name ~= "FreeRollButton" and object.Name ~= "Bulk1" and object.Name ~= "Bulk10" and object.Name ~= "Bulk100" then return end
    DIAG.rerollWatched[object] = true
    addConnection(object.MouseButton1Click, function()
        DIAG.log("INFO", "RNG", "manual_reroll_click", getRerollContext(object))
    end)
end

local function watchRerollGui()
    local rerollGui = PlayerGui:FindFirstChild("RerollGui")
    if not rerollGui then return end
    for _, object in ipairs(rerollGui:GetDescendants()) do watchRerollButton(object) end
end
watchRerollGui()
addConnection(PlayerGui.DescendantAdded, function(object)
    if string.find(object.Name, "Reroll", 1, true) or object:IsA("GuiButton") then
        task.defer(watchRerollButton, object)
    end
end)

local rerollResultNames = {
    "ClanRerollComplete", "SpiritualRootRerollComplete", "QiColourRerollComplete",
    "BodyConstitutionRerollComplete", "RaceRerollComplete",
}
local eventsFolderForAudit = ReplicatedStorage:FindFirstChild("CultivationEvents")
if eventsFolderForAudit then
    for _, remoteName in ipairs(rerollResultNames) do
        local remote = eventsFolderForAudit:FindFirstChild(remoteName)
        if remote and remote:IsA("RemoteEvent") then
            addConnection(remote.OnClientEvent, function(...)
                local args = {}
                for i = 1, select("#", ...) do args[i] = diagClean(select(i, ...), 0, {}) end
                DIAG.log("INFO", "RNG", "server_reroll_result", {
                    remote = remoteName, args = args,
                    silver = tonumber(LocalPlayer:GetAttribute("Silver")),
                    stones = tonumber(LocalPlayer:GetAttribute("PrimordialStones")),
                })
            end)
        end
    end
    for _, remoteName in ipairs({"BreakthroughEffect", "BreakthroughMinigameResult", "HitFeedback", "CombatLogNotice", "WeaponStateSync", "FieldBossReward", "QuestRewardGranted", "OrbBonusGranted", "CoinCollected", "ClanUpdateAll", "SpiritualRootUpdateAll", "QiColourUpdateAll", "BodyConstitutionUpdateAll", "RaceUpdateAll"}) do
        local remote = eventsFolderForAudit:FindFirstChild(remoteName)
        if remote and remote:IsA("RemoteEvent") then
            addConnection(remote.OnClientEvent, function(...)
                local args = {}
                for i = 1, select("#", ...) do args[i] = diagClean(select(i, ...), 0, {}) end
                DIAG.log("INFO", "SERVER_EVENT", remoteName, {args = args})
            end)
        end
    end
end

-- Manual sword input trace removed with Auto Silver in v1.0.6.

-- Standard Roblox idle notification. This only addresses the normal Idled event;
-- game-specific server AFK systems may still disconnect the player.
addConnection(LocalPlayer.Idled, function()
    if not running or not antiAfkEnabled then
        return
    end
    local ok, err = pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new(0, 0))
    end)
    if ok then
        DIAG.log("INFO", "ANTI_AFK", "idle_input_sent", {})
        print("[CU AutoCultivation] Anti-AFK input sent.")
    else
        lastError = tostring(err)
        DIAG.log("ERROR", "ANTI_AFK", "idle_input_failed", {reason = lastError})
        warn("[CU AutoCultivation] Anti-AFK failed: " .. lastError)
    end
end)

-- Initial currency read and attribute-change fallbacks.
local function refreshEconomyAttributes()
    local silver = tonumber(LocalPlayer:GetAttribute("Silver"))
    local stones = tonumber(LocalPlayer:GetAttribute("PrimordialStones"))
    if silver ~= nil then
        if ECONOMY.silverStart == nil then ECONOMY.silverStart = silver end
        ECONOMY.silver = silver
    end
    if stones ~= nil then
        if ECONOMY.stonesStart == nil then ECONOMY.stonesStart = stones end
        local oldStones = ECONOMY.stones
        if oldStones ~= nil and stones ~= oldStones then
            ECONOMY.lastStoneDelta = stones - oldStones
            ECONOMY.lastStoneChangeAt = os.time()
            ECONOMY.lastStoneChangeClock = os.clock()
            if stones > oldStones then ECONOMY.stonesEarned = ECONOMY.stonesEarned + (stones - oldStones) end
        end
        ECONOMY.stones = stones
    end
    ECONOMY.updateUI()
end
refreshEconomyAttributes()
addConnection(LocalPlayer:GetAttributeChangedSignal("Silver"), refreshEconomyAttributes)
addConnection(LocalPlayer:GetAttributeChangedSignal("PrimordialStones"), refreshEconomyAttributes)

createGui()
HERB_MONITOR.update(true)
DIAG.log("INFO", "SYSTEM", "initialized", {version = "1.0.8.3.1", placeId = game.PlaceId, player = LocalPlayer.Name, quickHerb = QUICK_INTERACT.enabled, retiredModules = {"CHEST", "INHERITANCE", "SILVER", "EXPERIMENTS"}, settingsLoaded = SETTINGS.loaded})
DIAG.refreshUI(true)
if UI.settingsStatusLabel then UI.settingsStatusLabel.Text = SETTINGS.status end

addConnection(TeleportService.TeleportInitFailed, function(player, result, message, placeId)
    if player ~= LocalPlayer then return end
    REJOIN.busy = false
    DIAG.log("ERROR", "REJOIN", "teleport_init_failed", {result = tostring(result), message = tostring(message), placeId = placeId})
    REJOIN.setStatus("Teleport failed: " .. tostring(message or result), COLORS.danger)
end)

-- Restore saved automation only after the client and character are ready.
-- This is intentionally delayed so replicated Qi/Body state and trial UI can initialize first.
task.spawn(function()
    if not game:IsLoaded() then game.Loaded:Wait() end
    if not LocalPlayer.Character then LocalPlayer.CharacterAdded:Wait() end
    task.wait(5)
    if not running then return end
    SETTINGS.restoreReady = true
    updateModeButtons()
    if selectedAutoMode then
        DIAG.log("INFO", "SETTINGS", "auto_mode_restored", {mode = selectedAutoMode})
        setStatus("Restored " .. selectedAutoMode .. " Auto Cultivation from saved settings; waiting for replicated state before acting.", COLORS.success)
    end
    if autoHerbsEnabled then
        DIAG.log("INFO", "SETTINGS", "auto_herbs_restored", {ageSelection = HERB_MONITOR.ageSelection})
        runHerbCollector()
    end
    if autoBrewEnabled then
        DIAG.log("INFO", "SETTINGS", "auto_brew_restored", {})
        BREW.run()
    end
end)

task.spawn(function()
    while running do
        task.wait(1)
        if running then
            local ok, err = pcall(DIAG.sampleProgress)
            if not ok then DIAG.log("ERROR", "PROGRESS", "sampler_error", {reason = tostring(err)}) end
            DIAG.flush()
            DIAG.refreshUI(true)
        end
    end
end)

task.spawn(function()
    while running do
        task.wait(2)
        if running then
            HERB_MONITOR.update(true)
        end
    end
end)

-- Auto Sell watcher: never opens Merchant Gao or travels to him. It only acts
-- while the player's normal Merchant Gao Herbs window is already open.
task.spawn(function()
    while running do
        task.wait(0.75)
        if running and AUTO_SELL.enabled and not AUTO_SELL.busy and not paused
            and not UI.heavenly.active and not herbCollectorBusy and not autoBrewBusy
            and not cauldronPanelIsOpen() then
            local merchantRoot = autoSellFindMerchantRoot()
            if merchantRoot then
                autoSellRun()
            else
                AUTO_SELL.status = "Auto Sell ON | waiting for Merchant Gao's Herbs window"
                if UI.autoSellStatusLabel then UI.autoSellStatusLabel.Text = AUTO_SELL.status end
            end
        end
    end
end)

-- Keyboard controls:
-- Ctrl + Home: show/hide panel (floating CU icon is also available)
-- Ctrl + P: pause/resume
-- Ctrl + End: stop script
addConnection(UserInputService.InputBegan, function(input, gameProcessed)
    if not running then return end
    local controlDown = UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
        or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
    if not controlDown then return end

    -- Handle the restore hotkey before the gameProcessed guard so the panel
    -- can always be recovered while Roblox UI/gameplay has focus.
    if input.KeyCode == Enum.KeyCode.Home then
        UI.setPanelVisible(not (panel and panel.Visible))
        return
    end
    if gameProcessed then return end

    if input.KeyCode == Enum.KeyCode.P then
        paused = not paused
        if pauseButton then
            pauseButton.Text = paused and "RESUME" or "PAUSE"
            pauseButton.BackgroundColor3 = paused and COLORS.warning or COLORS.panel2
        end
        if UI.headerState then
            UI.headerState.Text = paused and "PAUSED" or "RUNNING"
            UI.headerState.BackgroundColor3 = paused and COLORS.warning or COLORS.success
        end
        setStatus(paused and "Paused; automation actions suspended." or "Resumed.", paused and COLORS.warning or COLORS.success)
    elseif input.KeyCode == Enum.KeyCode.End then
        stop("Ctrl+End")
    end
end)

-- High-frequency tribulation timing; lower-frequency cultivation and progress checks.
local frameCounter = 0
addConnection(RunService.RenderStepped, function()
    if not running or paused then
        return
    end
    if SETTINGS.loaded and not SETTINGS.restoreReady then
        return
    end

    frameCounter = frameCounter + 1

    local okTrial, trialActiveOrError = pcall(processTrial)
    if not okTrial then
        lastError = tostring(trialActiveOrError)
        setStatus("Trial monitor error: " .. lastError, COLORS.danger)
        return
    end

    if not trialActiveOrError and not herbCollectorBusy and not CHEST.busy and not SILVER.busy and frameCounter % 6 == 0 then
        local okBreak, breakError = pcall(processBreakthrough)
        if not okBreak then
            lastError = tostring(breakError)
            setStatus("Breakthrough monitor error: " .. lastError, COLORS.danger)
        end
    end

    if frameCounter % 30 == 0 then
        local now = os.clock()
        if now - lastAutoCheckAt >= 0.8 then
            lastAutoCheckAt = now
            local okAuto, autoError = pcall(processAutoCultivation)
            if not okAuto then
                lastError = tostring(autoError)
                setStatus("Auto Cultivation error: " .. lastError, COLORS.danger)
            end
        end
    end

    if trialLabel then
        trialLabel.Text = lastTrialText
    end
end)

print("[CU AutoCultivation] v1.0.8.3.1 loaded. Qi/Body cultivation, breakthrough, herbs and brewing retained.")
print("[CU AutoCultivation] Retired: Auto Chest, Chest TP, Immortal Inheritance, Auto Silver and Experiments.")
print("[CU AutoCultivation] Heavenly Tribulation: continuous-pulse rearming, smoothed ring velocity, short SPACE pulse, feedback-based timing calibration.")
print("[CU AutoCultivation] No chest teleport, chest opening, inheritance travel, or Auto Silver runner is active in this release.")
print("[CU AutoCultivation] Settings persist to " .. SETTINGS.file .. "; Settings tab has Private Rejoin and Public Server Hop.")
DIAG.log("INFO", "SYSTEM", "ready", {version = "1.0.8.3.1"})
setStatus("Loaded v1.0.8.3.1. Auto Hop waits for a confirmed empty 1k-herb scan, then uses public Server Hop.", COLORS.success)
