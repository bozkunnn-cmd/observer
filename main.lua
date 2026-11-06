--[[
    CULTIVATION UNBOUND - AUTO CULTIVATION + ECONOMY
    Version: 0.9.1

    Built on the user's working Auto Breakthrough v0.2.

    FEATURES
      - Qi Auto Cultivation: select best eligible Qi zone, teleport, meditate.
      - Body Auto Cultivation: select best eligible Body zone, teleport, push-ups.
      - Re-evaluate the best zone after realm breakthroughs.
      - Preserve the working BreakthroughBanner and tribulation Tap logic.
      - Tribulation processing does not require a readable hit counter.
      - Anti-AFK toggle using LocalPlayer.Idled / VirtualUser.
      - Auto Herb Collection: scans enabled CollectHerbPrompt objects in both
        normal HerbSpots and SpiritWorld.Herbs folders; reads HerbYear and
        prioritizes oldest age first, with optional species filters.
      - Holds the real 2.5-second collection prompt and verifies the result.
      - Temporarily pauses cultivation during a herb sweep, then resumes.
      - Auto Brew: exact recipe validation, oldest available herbs first,
        timed Stoke at the center of the Perfect band, and automatic claiming.
      - Auto Chest: scans Workspace.ChestSpots, applies tier filters, opens
        Celestial > Jade > Bronze > Wooden, and verifies ChestWorldOpened.
      - Herb Monitor: live age counts split between normal and SpiritWorld nodes,
        including disabled/locked prompt counts.
      - Economy dashboard: Silver and Primordial Stone balances, NPC Silver rewards,
        session deltas, and Destiny reroll probability/cost estimates.
      - Auto Silver: targets eligible non-boss cultivators in Workspace.CultivatorCamps
        using normal client-side weapon input; no fabricated reward remotes.
      - Redesigned tabbed UI with Overview, Cultivation, Farming, Alchemy, Economy, Settings.

    IMPORTANT
      - No RemoteEvent:FireServer calls.
      - Chest reward confirmation uses the inbound ChestWorldOpened event only.
      - Teleport uses local character CFrame and may be corrected by the server.
      - Zone activation is checked against replicated zone multipliers before
        the script starts meditation or push-ups.
      - Qi and Body auto modes are mutually exclusive because one character
        can only run one selected cultivation activity at a time.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local VirtualUser = game:GetService("VirtualUser")

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
local HERB_MONITOR = {ageCounts = nil, lastScanAt = 0}

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
    autoEnabled = false,
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
local herbFilterButton = nil
local UI = {chestFilterToggleButtons = {}, pages = {}, tabs = {}}
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
local CHEST_TIER_ORDER = {"Celestial", "Jade", "Bronze", "Wooden"}

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
    if UI.silverInfoLabel then
        UI.silverInfoLabel.Text = "Auto Silver: " .. SILVER.activeName
    end
    if UI.silverTargetLabel then
        local targetName = SILVER.currentTarget and SILVER.currentTarget.Name or "none"
        local realmText = SILVER.currentTargetRealm and (" | Qi Realm " .. tostring(SILVER.currentTargetRealm)) or ""
        UI.silverTargetLabel.Text = "Target: " .. targetName .. realmText .. " | Kills: " .. tostring(SILVER.kills) .. " | Earned: " .. ECONOMY.formatNumber(SILVER.earned)
    end
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
    if UI.chestInfoLabel then
        UI.chestInfoLabel.Text = string.format(
            "Chests: %d opened | %s",
            CHEST.openedCount,
            CHEST.activeName
        )
    end
end

local function stop(reason)
    if not running then
        return
    end
    running = false
    autoHerbsEnabled = false
    autoBrewEnabled = false
    autoBrewBusy = false
    CHEST.autoEnabled = false
    SILVER.autoEnabled = false
    SILVER.busy = false
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
            autoHerbsEnabled = autoHerbsEnabled,
            autoBrewEnabled = autoBrewEnabled,
            autoBrewBusy = autoBrewBusy,
            autoChestEnabled = CHEST.autoEnabled,
            autoSilverEnabled = SILVER.autoEnabled,
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

local function processTrial()
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
    if autoBrewBusy or cauldronPanelIsOpen() then
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
        print("[CU AutoCultivation] " .. mode .. " 100% -> Breakthrough click, " .. tostring(realmText) .. " via " .. backend)
    else
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
    setStatus("Travelling to " .. zone.name .. "...", COLORS.warning)

    task.spawn(function()
        -- Cancel a pending travel if the user switches Auto Cultivation OFF
        -- or changes to the other mode before the teleport task runs.
        if not running or paused or selectedAutoMode ~= mode then
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
            setStatus("Teleport failed: " .. tostring(err), COLORS.danger)
            teleporting = false
            return
        end

        task.wait(2.5)
        local verifyRoot = getCharacterParts()
        local arrived = verifyRoot and isInsideZone(verifyRoot, target, size)
        if selectedAutoMode == mode and running then
            if arrived then
                setStatus("Arrived at " .. zone.name .. "; checking the server zone bonus.", COLORS.success)
            else
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
        setStatus("Starting " .. (mode == "Qi" and "Qi meditation" or "Body push-ups") .. " via " .. tostring(backend) .. ".", COLORS.success)
    else
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
    return true, true, backend
end

local function processAutoCultivation()
    if herbCollectorBusy or CHEST.busy or SILVER.busy or autoBrewBusy or cauldronPanelIsOpen() or not selectedAutoMode or paused or not running then
        return
    end
    -- Never relocate or restart training while a breakthrough/tribulation is
    -- loading, active, or waiting for its progression update.
    if activeTrialGui or getActiveTrialGui() or breakthroughTrialSeen then
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
        setStatus(mode .. " training active at " .. zone.name .. " (" .. string.format("%.2fx", zone.multiplier) .. ").", COLORS.success)
        return
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
                    if isHerbSpeciesAllowed(species) then
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
        if not running or not autoHerbsEnabled or paused then
            return false
        end
        task.wait(0.05)
    end
    return true
end

local function holdHerbPrompt(prompt)
    local holdDuration = math.clamp(tonumber(prompt.HoldDuration) or 2.5, 0.1, 5)

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
    if not selectedAutoMode and herbReturnCFrame then
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

    if not selectedAutoMode and resumeMode and running and not paused then
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
    local sent, backend = holdHerbPrompt(prompt)
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
        print("[CU AutoCultivation] Collected " .. herbName .. " (" .. ageText .. ") via " .. tostring(backend))
        return true, "collected"
    end

    herbFailedCount = herbFailedCount + 1
    return false, "no inventory/prompt confirmation; will retry later"
end

local function isBreakthroughPending()
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

-- Auto Silver uses visible CultivatorCamps NPCs and normal weapon input only.
-- It never fires NpcKillSilver or any reward/update RemoteEvent.
SILVER.getNpcRoot = function(model)
    if not model then return nil end
    return model:FindFirstChild("HumanoidRootPart")
        or model:FindFirstChild("UpperTorso")
        or model:FindFirstChild("Torso")
        or model.PrimaryPart
end

SILVER.findTarget = function()
    local playerRoot = getCharacterParts()
    local playerRealm = getRealmNumber("Qi")
    if not playerRoot or not playerRealm then return nil, nil, nil, nil end
    local camps = Workspace:FindFirstChild("CultivatorCamps")
    if not camps then return nil, nil, nil, nil end

    local bestModel, bestHumanoid, bestRoot, bestRealm = nil, nil, nil, nil
    local bestDistance = math.huge
    for _, model in ipairs(camps:GetChildren()) do
        if model:IsA("Model") and model:GetAttribute("IsCultivator") == true
            and model:GetAttribute("IsBoss") ~= true then
            local realm = tonumber(model:GetAttribute("QiRealm"))
            local humanoid = model:FindFirstChildOfClass("Humanoid")
            local npcRoot = SILVER.getNpcRoot(model)
            local blockedUntil = SILVER.blacklist[model]
            local blocked = blockedUntil and os.clock() < blockedUntil
            if realm and realm <= playerRealm and humanoid and humanoid.Health > 0 and npcRoot and not blocked then
                local distance = (playerRoot.Position - npcRoot.Position).Magnitude
                -- Prefer the strongest non-boss cultivator the player's Qi realm can face.
                if not bestModel or realm > bestRealm or (realm == bestRealm and distance < bestDistance) then
                    bestModel, bestHumanoid, bestRoot, bestRealm, bestDistance = model, humanoid, npcRoot, realm, distance
                end
            end
        end
    end
    return bestModel, bestHumanoid, bestRoot, bestRealm
end

SILVER.wait = function(seconds)
    local untilTime = os.clock() + seconds
    while os.clock() < untilTime do
        if not running or not SILVER.autoEnabled or paused then return false end
        task.wait(0.05)
    end
    return true
end

SILVER.basicAttack = function(targetRoot)
    local character = LocalPlayer.Character
    if not character or not targetRoot then return false, "character or target unavailable" end
    local drawnSword = character:FindFirstChild("DrawnSword")
    local weaponValue = character:FindFirstChild("EquippedWeapon")
    if not drawnSword and not (weaponValue and tostring(weaponValue.Value or "") ~= "") then
        return false, "draw your weapon before enabling Auto Silver"
    end

    local camera = Workspace.CurrentCamera
    local vinput = nil
    local okService, service = pcall(function() return game:GetService("VirtualInputManager") end)
    if okService then vinput = service end
    if not vinput then return false, "VirtualInputManager unavailable for normal M1 input" end

    local screenPoint, onScreen
    local oldCamera = nil
    local cameraChanged = false
    if camera then
        screenPoint, onScreen = camera:WorldToViewportPoint(targetRoot.Position)
        if not onScreen then
            oldCamera = camera.CFrame
            cameraChanged = true
            pcall(function() camera.CFrame = CFrame.lookAt(camera.CFrame.Position, targetRoot.Position) end)
            task.wait(0.08)
            screenPoint, onScreen = camera:WorldToViewportPoint(targetRoot.Position)
            if not onScreen then
                pcall(function() camera.CFrame = oldCamera end)
                return false, "target is not on screen; move camera toward the NPC"
            end
        end
    else
        return false, "camera unavailable"
    end

    local x, y = math.floor(screenPoint.X), math.floor(screenPoint.Y)
    -- Do not click through an active UI overlay.
    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if playerGui then
        local okGui, objects = pcall(function() return playerGui:GetGuiObjectsAtPosition(x, y) end)
        if okGui and type(objects) == "table" then
            for _, object in ipairs(objects) do
                if object:IsA("GuiButton") or object:IsA("TextBox") then
                    if cameraChanged and oldCamera then pcall(function() camera.CFrame = oldCamera end) end
                    return false, "an interactive GUI covers the target; close menus before farming"
                end
            end
        end
    end
    local downOk = pcall(function() vinput:SendMouseButtonEvent(x, y, 0, true, game, 0) end)
    task.wait(0.06)
    local upOk = pcall(function() vinput:SendMouseButtonEvent(x, y, 0, false, game, 0) end)
    if cameraChanged and oldCamera then
        pcall(function() camera.CFrame = oldCamera end)
    end
    local ok = downOk and upOk
    return ok, ok and "normal left-click" or "M1 input failed"
end

SILVER.run = function()
    if SILVER.taskRunning then return end
    SILVER.taskRunning = true
    task.spawn(function()
        while running and SILVER.autoEnabled do
            if paused then
                SILVER.setStatus("paused")
                task.wait(0.25)
            elseif herbCollectorBusy or CHEST.busy or autoBrewBusy or cauldronPanelIsOpen()
                or activeTrialGui or getActiveTrialGui() or breakthroughTrialSeen or isBreakthroughPending() then
                SILVER.setStatus("waiting for herb/chest/brew/breakthrough")
                task.wait(0.3)
            else
                local playerRoot, playerHumanoid = getCharacterParts()
                local playerRealm = getRealmNumber("Qi")
                if not playerRoot or not playerHumanoid then
                    SILVER.setStatus("waiting for character")
                    task.wait(0.5)
                elseif not playerRealm then
                    SILVER.setStatus("waiting for Qi realm data")
                    task.wait(0.5)
                else
                    local target, targetHumanoid, targetRoot, targetRealm = SILVER.findTarget()
                    if not target then
                        SILVER.currentTarget = nil
                        SILVER.currentTargetRealm = nil
                        SILVER.setStatus("no eligible non-boss CultivatorCamps NPC for Qi Realm " .. tostring(playerRealm))
                        task.wait(2.0)
                    else
                        SILVER.busy = true
                        SILVER.currentTarget = target
                        SILVER.currentTargetRealm = targetRealm
                        SILVER.setStatus("targeting " .. target.Name .. " (Qi " .. tostring(targetRealm) .. ")")

                        if selectedAutoMode then
                            stopAutomationOwnedTraining(selectedAutoMode)
                        end

                        local distance = (playerRoot.Position - targetRoot.Position).Magnitude
                        if distance > 11 then
                            local destination = targetRoot.Position + Vector3.new(0, 0, 7)
                            local look = targetRoot.Position
                            local moved = pcall(function()
                                playerRoot.AssemblyLinearVelocity = Vector3.zero
                                playerRoot.AssemblyAngularVelocity = Vector3.zero
                                playerRoot.CFrame = CFrame.lookAt(destination, look)
                            end)
                            if not moved or not SILVER.wait(1.25) then
                                SILVER.busy = false
                                break
                            end
                            playerRoot = getCharacterParts()
                            if not playerRoot or (playerRoot.Position - targetRoot.Position).Magnitude > 20 then
                                SILVER.blacklist[target] = os.clock() + 12
                                SILVER.failed = SILVER.failed + 1
                                SILVER.setStatus("could not reach " .. target.Name .. "; skipping for 12s")
                                SILVER.busy = false
                                task.wait(0.25)
                            end
                        end

                        if SILVER.busy and running and SILVER.autoEnabled and target.Parent and targetHumanoid.Health > 0 then
                            local lastHealth = targetHumanoid.Health
                            local lastDamageAt = os.clock()
                            local startRewardCount = ECONOMY.npcKillCount
                            local attackDeadline = os.clock() + 35
                            while running and SILVER.autoEnabled and not paused and target.Parent and targetHumanoid.Health > 0 and os.clock() < attackDeadline do
                                if activeTrialGui or getActiveTrialGui() or CHEST.busy or herbCollectorBusy or autoBrewBusy then break end
                                local okAttack, backend = SILVER.basicAttack(targetRoot)
                                if not okAttack then
                                    SILVER.setStatus("attack stopped: " .. tostring(backend))
                                    if string.find(string.lower(tostring(backend)), "draw your weapon", 1, true) then
                                        SILVER.setStatus("waiting: draw/equip your sword; Auto Silver remains ON")
                                        task.wait(1.0)
                                        break
                                    elseif string.find(string.lower(tostring(backend)), "virtualinputmanager unavailable", 1, true) then
                                        SILVER.setStatus("waiting: executor has no supported M1 input; Auto Silver remains ON")
                                        task.wait(1.5)
                                        break
                                    end
                                    SILVER.blacklist[target] = os.clock() + 20
                                    break
                                end
                                task.wait(0.28)
                                local healthNow = targetHumanoid.Health
                                if healthNow < lastHealth - 0.1 then
                                    lastHealth = healthNow
                                    lastDamageAt = os.clock()
                                    SILVER.setStatus("attacking " .. target.Name .. " | HP " .. ECONOMY.formatNumber(healthNow) .. "/" .. ECONOMY.formatNumber(targetHumanoid.MaxHealth))
                                elseif os.clock() - lastDamageAt > 4.5 then
                                    SILVER.setStatus("no damage registered on " .. target.Name .. "; skipping")
                                    SILVER.blacklist[target] = os.clock() + 20
                                    break
                                end
                            end

                            if targetHumanoid.Health <= 0 then
                                local rewardDeadline = os.clock() + 4
                                while running and os.clock() < rewardDeadline and ECONOMY.npcKillCount <= startRewardCount do
                                    task.wait(0.1)
                                end
                                if ECONOMY.npcKillCount > startRewardCount then
                                    SILVER.kills = SILVER.kills + 1
                                    SILVER.setStatus("defeated " .. target.Name .. " | +" .. ECONOMY.formatNumber(SILVER.lastReward) .. " Silver")
                                else
                                    SILVER.setStatus("defeated " .. target.Name .. "; waiting for Silver reward confirmation")
                                end
                            end
                        end
                        SILVER.busy = false
                        SILVER.currentTarget = nil
                        SILVER.currentTargetRealm = nil
                        if SILVER.autoEnabled then task.wait(0.35) end
                    end
                end
            end
        end
        SILVER.busy = false
        SILVER.currentTarget = nil
        SILVER.currentTargetRealm = nil
        SILVER.taskRunning = false
        SILVER.setStatus(SILVER.autoEnabled and "waiting" or "OFF")
        updateModeButtons()
    end)
end

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
            elseif CHEST.busy or SILVER.busy or autoBrewBusy or cauldronPanelIsOpen() or activeTrialGui or getActiveTrialGui() or breakthroughTrialSeen or isBreakthroughPending() then
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
                        end
                        task.wait(3.0)
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

-- Auto Chest -----------------------------------------------------------------
-- Uses live Workspace.ChestSpots markers and their OpenChestPrompt objects.
-- Tier and HoldDuration are read from the live objects; no tier duration is
-- hardcoded. Opening is performed through the actual ProximityPrompt lifecycle.

CHEST.normalizeTier = function(value)
    local text = string.lower(tostring(value or ""))
    for _, tier in ipairs(CHEST_TIER_ORDER) do
        if string.find(text, string.lower(tier), 1, true) then
            return tier
        end
    end
    return nil
end

CHEST.getSpotFromPrompt = function(prompt, folder)
    local node = prompt
    while node and node.Parent and node.Parent ~= folder do
        node = node.Parent
    end
    if node and node.Parent == folder then
        return node
    end
    return prompt and prompt.Parent or nil
end

CHEST.getTier = function(spot, prompt)
    local node = spot
    local depth = 0
    while node and depth < 5 do
        local ok, value = pcall(function()
            return node:GetAttribute("Tier")
        end)
        if ok and value ~= nil then
            local tier = CHEST.normalizeTier(value)
            if tier then
                return tier
            end
        end
        node = node.Parent
        depth = depth + 1
    end
    return CHEST.normalizeTier(prompt and prompt.ObjectText)
end

CHEST.isOpened = function(spot)
    local node = spot
    local depth = 0
    while node and depth < 5 do
        local ok, opened = pcall(function()
            return node:GetAttribute("Opened")
        end)
        if ok and opened == true then
            return true
        end
        node = node.Parent
        depth = depth + 1
    end
    return false
end

CHEST.getPosition = function(spot, prompt)
    if spot and spot:IsA("BasePart") then
        return spot.Position
    end
    if spot and spot:IsA("Model") then
        local ok, pivot = pcall(function()
            return spot:GetPivot()
        end)
        if ok and pivot then
            return pivot.Position
        end
    end
    local parent = prompt and prompt.Parent
    if parent and parent:IsA("BasePart") then
        return parent.Position
    end
    if parent and parent:IsA("Model") then
        local ok, pivot = pcall(function()
            return parent:GetPivot()
        end)
        if ok and pivot then
            return pivot.Position
        end
    end
    return nil
end

CHEST.getPromptEntries = function()
    local entries = {}
    local folder = Workspace:FindFirstChild("ChestSpots")
    if not folder then
        return entries
    end
    for _, node in ipairs(folder:GetDescendants()) do
        if node:IsA("ProximityPrompt") and node.Name == "OpenChestPrompt" then
            local spot = CHEST.getSpotFromPrompt(node, folder)
            local tier = CHEST.getTier(spot, node)
            local position = CHEST.getPosition(spot, node)
            if spot and tier and position then
                table.insert(entries, {spot = spot, prompt = node, tier = tier, position = position})
            end
        end
    end
    return entries
end

CHEST.getMonitorCounts = function()
    local counts = {open = {Celestial = 0, Jade = 0, Bronze = 0, Wooden = 0}, opened = 0, unknown = 0}
    local now = os.clock()
    for _, entry in ipairs(CHEST.getPromptEntries()) do
        local openedUntil = CHEST.openedByScript[entry.spot]
        if openedUntil and now >= openedUntil then
            CHEST.openedByScript[entry.spot] = nil
            openedUntil = nil
        end
        if CHEST.isOpened(entry.spot) or openedUntil then
            counts.opened = counts.opened + 1
        elseif entry.prompt.Enabled then
            counts.open[entry.tier] = counts.open[entry.tier] + 1
        else
            counts.opened = counts.opened + 1
        end
    end
    return counts
end

CHEST.updateMonitor = function()
    if not UI.chestInfoLabel then
        return
    end
    local ok, counts = pcall(CHEST.getMonitorCounts)
    if not ok then
        UI.chestInfoLabel.Text = "Chests: scan error"
        return
    end
    UI.chestInfoLabel.Text = string.format(
        "Chests: %d opened | ready C/J/B/W %d/%d/%d/%d | %s",
        CHEST.openedCount,
        counts.open.Celestial, counts.open.Jade, counts.open.Bronze, counts.open.Wooden,
        CHEST.activeName
    )
end

CHEST.findBestPrompt = function()
    local root = getCharacterParts()
    if not root then
        return nil, nil, nil, nil, nil
    end
    local best = nil
    local bestRank = -1
    local bestDistance = math.huge
    local now = os.clock()
    for _, entry in ipairs(CHEST.getPromptEntries()) do
        local spot, prompt, tier = entry.spot, entry.prompt, entry.tier
        local opened = CHEST.isOpened(spot)
        local openedUntil = CHEST.openedByScript[spot]
        if openedUntil and now >= openedUntil then
            CHEST.openedByScript[spot] = nil
            openedUntil = nil
        end
        local lastAttempt = CHEST.attemptTimes[spot]
        local coolingDown = lastAttempt and (now - lastAttempt < 12)
        if not opened and not openedUntil and prompt.Enabled and CHEST.tierSelection[tier] and not coolingDown then
            local distance = (root.Position - entry.position).Magnitude
            local rank = CHEST.tierOrder[tier] or 0
            if rank > bestRank or (rank == bestRank and distance < bestDistance) then
                best = entry
                bestRank = rank
                bestDistance = distance
            end
        end
    end
    if not best then
        return nil, nil, nil, nil, nil
    end
    return best.spot, best.prompt, best.position, best.tier, bestDistance
end

CHEST.wait = function(seconds)
    local deadline = os.clock() + seconds
    while os.clock() < deadline do
        if not running or not CHEST.autoEnabled or paused then
            return false
        end
        if activeTrialGui or getActiveTrialGui() or breakthroughTrialSeen or isBreakthroughPending() or cauldronPanelIsOpen() then
            return false
        end
        task.wait(0.05)
    end
    return true
end

CHEST.holdPrompt = function(prompt, spot, tier, revisionBefore)
    local holdDuration = math.clamp(tonumber(prompt.HoldDuration) or 1.0, 0.1, 8)

    local function stateChanged()
        if not prompt or not prompt.Parent then return true end
        if spot and CHEST.isOpened(spot) then return true end
        if not prompt.Enabled then return true end
        if spot and tier and revisionBefore ~= nil
            and CHEST.getLocalOpenEvent(spot, tier, revisionBefore) then
            return true
        end
        return false
    end

    local function waitForState(seconds)
        local deadline = os.clock() + seconds
        while os.clock() < deadline do
            if not CHEST.wait(0.05) then return false, "cancelled" end
            if stateChanged() then return true, "prompt state changed" end
        end
        return stateChanged(), stateChanged() and "prompt state changed" or "no trigger/state change"
    end

    -- First try Roblox's real prompt hold lifecycle. A successful pcall only
    -- means the method did not throw; it is NOT treated as proof of opening.
    local began = pcall(function()
        prompt:InputHoldBegin()
    end)
    if began then
        local completed = CHEST.wait(holdDuration + 0.15)
        pcall(function() prompt:InputHoldEnd() end)
        if not completed then return false, "cancelled during ProximityPrompt hold" end
        local confirmed, reason = waitForState(0.35)
        if confirmed then return true, "ProximityPrompt hold" end
    end

    -- Executor prompt helper fallback. Wait for an actual chest/prompt state
    -- change before considering this attempt successful.
    if type(fireproximityprompt) == "function" then
        local ok, err = pcall(fireproximityprompt, prompt, holdDuration)
        if ok then
            local confirmed = waitForState(0.65)
            if confirmed then return true, "fireproximityprompt (verified)" end
        else
            lastError = tostring(err)
        end
    end

    -- Final fallback: simulate the prompt's configured keyboard key for its
    -- configured hold duration, then verify the prompt actually changed.
    local virtualInput
    local okService, service = pcall(function()
        return game:GetService("VirtualInputManager")
    end)
    if okService then virtualInput = service end
    if not virtualInput then
        return false, "no supported chest prompt input method"
    end

    local key = prompt.KeyboardKeyCode
    local keyDown = pcall(function()
        virtualInput:SendKeyEvent(true, key, false, game)
    end)
    if not keyDown then return false, "could not press chest prompt key" end

    local completed = CHEST.wait(holdDuration + 0.15)
    pcall(function() virtualInput:SendKeyEvent(false, key, false, game) end)
    if not completed then return false, "cancelled during VirtualInputManager hold" end

    local confirmed = waitForState(0.65)
    if confirmed then return true, "VirtualInputManager hold (verified)" end
    return false, "input methods ran but chest prompt never triggered; check prompt range/ownership"
end

CHEST.getLocalOpenEvent = function(spot, tier, revisionBefore)
    if CHEST.worldOpenedRevision <= revisionBefore or type(CHEST.lastWorldOpened) ~= "table" then
        return nil
    end
    local event = CHEST.lastWorldOpened
    if event.playerName ~= LocalPlayer.Name then
        return nil
    end
    if CHEST.normalizeTier(event.tier) ~= tier then
        return nil
    end
    if event.chest == nil or event.chest == spot or event.chestName == spot.Name then
        return event
    end
    return nil
end

CHEST.beginSweep = function()
    if CHEST.busy or herbCollectorBusy or autoBrewBusy then
        return false, "another collection/brewing task is active"
    end
    local root = getCharacterParts()
    if not root then
        return false, "waiting for character"
    end
    CHEST.returnCFrame = root.CFrame
    CHEST.resumeMode = getHerbResumeMode()
    CHEST.busy = true
    if CHEST.resumeMode and isTrainingActive(CHEST.resumeMode) then
        local key = CHEST.resumeMode == "Qi" and Enum.KeyCode.M or Enum.KeyCode.P
        local sent, backend = sendKey(key)
        if not sent then
            CHEST.busy = false
            CHEST.returnCFrame = nil
            CHEST.resumeMode = nil
            return false, "could not pause current cultivation: " .. tostring(backend)
        end
        task.wait(0.35)
    end
    return true, "collection sweep started"
end

CHEST.finishSweep = function(reason)
    if not CHEST.busy and not CHEST.returnCFrame then
        return
    end
    CHEST.busy = false
    if not selectedAutoMode and CHEST.returnCFrame then
        local root = getCharacterParts()
        if root then
            pcall(function()
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
                root.CFrame = CHEST.returnCFrame
            end)
            task.wait(0.5)
        end
    end
    local resumeMode = CHEST.resumeMode
    CHEST.returnCFrame = nil
    CHEST.resumeMode = nil
    if not selectedAutoMode and resumeMode and running then
        if paused then
            CHEST.pendingManualResume = resumeMode
        elseif not isTrainingActive(resumeMode) then
            activateTraining(resumeMode)
        end
    end
    CHEST.setStatus(reason or "waiting for chests")
end

CHEST.describeReward = function(event)
    if type(event) ~= "table" or type(event.rewards) ~= "table" then
        return "opened; reward details unavailable"
    end
    local rewards = event.rewards
    local parts = {}
    if type(rewards.rareLine) == "string" and rewards.rareLine ~= "" then
        table.insert(parts, rewards.rareLine)
    elseif rewards.rare == true then
        table.insert(parts, "rare reward")
    end
    if rewards.bonus == true then
        table.insert(parts, "bonus reward")
    end
    if #parts == 0 then
        return "opened; no rare/bonus flag"
    end
    return table.concat(parts, " | ")
end

CHEST.collect = function(spot, prompt, position, tier)
    if not spot or not spot.Parent or not prompt or not prompt.Parent or not prompt.Enabled then
        return false, "chest is no longer available"
    end
    if CHEST.isOpened(spot) then
        return false, "chest was already opened"
    end
    local root = getCharacterParts()
    if not root then
        return false, "waiting for character"
    end
    local maxDistance = tonumber(prompt.MaxActivationDistance) or 12
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
        if not CHEST.wait(0.85) then
            return false, "cancelled while travelling"
        end
        root = getCharacterParts()
        if not root then
            return false, "character unavailable after travel"
        end
        distance = (root.Position - (CHEST.getPosition(spot, prompt) or position)).Magnitude
    end
    if not prompt.Parent or not prompt.Enabled or CHEST.isOpened(spot) then
        return false, "chest became unavailable before opening"
    end
    if distance > maxDistance then
        return false, string.format("outside prompt range (%.1f/%.1f)", distance, maxDistance)
    end

    local revisionBefore = CHEST.worldOpenedRevision
    local sent, backend = CHEST.holdPrompt(prompt, spot, tier, revisionBefore)
    if not sent then
        return false, "chest interaction did not register: " .. tostring(backend)
    end

    local deadline = os.clock() + 4.5
    local stateChanged = false
    while running and CHEST.autoEnabled and os.clock() < deadline do
        if paused or activeTrialGui or getActiveTrialGui() or breakthroughTrialSeen or isBreakthroughPending() or cauldronPanelIsOpen() then
            return false, "cancelled by pause, breakthrough, tribulation, or cauldron"
        end
        local event = CHEST.getLocalOpenEvent(spot, tier, revisionBefore)
        if event then
            CHEST.openedByScript[spot] = os.clock() + 30
            CHEST.openedCount = CHEST.openedCount + 1
            return true, "opened " .. tier .. " chest | " .. CHEST.describeReward(event)
        end
        if CHEST.isOpened(spot) or not prompt.Enabled or not prompt.Parent then
            stateChanged = true
        end
        task.wait(0.05)
    end

    if stateChanged then
        CHEST.openedByScript[spot] = os.clock() + 30
        return false, "chest state changed, but no local ChestWorldOpened reward confirmation was received"
    end
    return false, "no ChestWorldOpened or opened-state confirmation"
end

CHEST.run = function()
    if CHEST.taskRunning then
        return
    end
    CHEST.taskRunning = true
    task.spawn(function()
        while running and CHEST.autoEnabled do
            if paused then
                CHEST.setStatus("paused")
                task.wait(0.2)
            elseif herbCollectorBusy or SILVER.busy or autoBrewBusy or cauldronPanelIsOpen() or activeTrialGui or getActiveTrialGui() or breakthroughTrialSeen or isBreakthroughPending() then
                if CHEST.busy then
                    CHEST.finishSweep("pausing chest sweep for another activity")
                end
                CHEST.setStatus("waiting for herb/brew/breakthrough")
                task.wait(0.25)
            else
                local spot, prompt, position, tier = CHEST.findBestPrompt()
                if spot then
                    if not CHEST.busy then
                        local started, reason = CHEST.beginSweep()
                        if not started then
                            CHEST.setStatus(reason)
                            task.wait(0.35)
                        else
                            CHEST.setStatus("travelling to " .. tier .. " chest")
                        end
                    end
                    if CHEST.busy and running and CHEST.autoEnabled then
                        CHEST.attemptTimes[spot] = os.clock()
                        CHEST.setStatus("opening " .. tier .. " chest")
                        local ok, result = CHEST.collect(spot, prompt, position, tier)
                        if ok then
                            CHEST.setStatus(result)
                            CHEST.updateMonitor()
                            task.wait(0.25)
                        else
                            CHEST.failedCount = CHEST.failedCount + 1
                            CHEST.setStatus(tier .. " chest: " .. tostring(result))
                            task.wait(0.35)
                        end
                    end
                else
                    if CHEST.busy then
                        CHEST.finishSweep("sweep complete; checking respawns")
                    else
                        CHEST.setStatus("no eligible unopened chests")
                    end
                    task.wait(3.0)
                end
            end
        end
        if CHEST.busy then
            CHEST.finishSweep("Auto Chest stopped")
        end
        CHEST.taskRunning = false
        updateModeButtons()
    end)
end

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
            return
        end
    end
end

local function brewWaitFor(predicate, timeout)
    local deadline = os.clock() + (timeout or 2)
    while running and autoBrewEnabled do
        if paused then
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

    local reserved = {}
    local plan = {}
    for _, ingredient in ipairs(recipe.ingredients) do
        for _ = 1, ingredient.count do
            local chosen = nil
            for _, age in ipairs(BREW_AGE_ORDER) do
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
            end
            if not chosen then
                return nil, "Not enough " .. ingredient.name .. " to make " .. recipe.name .. "."
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

    while running and autoBrewEnabled
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
            elseif CHEST.busy or SILVER.busy then
                setStatus("Auto Brew waiting for chest or Silver farming to finish.", COLORS.warning)
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
                                        setStatus("Started " .. recipe.name .. " using the oldest available herbs. Waiting for game validation.", COLORS.success)
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

local function getHerbFilterSummary()
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

CHEST.getFilterSummary = function()
    local count = 0
    for _, tier in ipairs(CHEST_TIER_ORDER) do
        if CHEST.tierSelection[tier] then
            count = count + 1
        end
    end
    if count == #CHEST_TIER_ORDER then
        return "CHEST FILTER: ALL"
    elseif count == 0 then
        return "CHEST FILTER: NONE"
    end
    return "CHEST FILTER: " .. tostring(count) .. "/" .. tostring(#CHEST_TIER_ORDER)
end

CHEST.updateFilterPicker = function()
    for tier, button in pairs(UI.chestFilterToggleButtons) do
        if button then
            local selected = CHEST.tierSelection[tier] == true
            button.Text = (selected and "[ON] " or "[  ] ") .. tier
            button.BackgroundColor3 = selected and COLORS.success or COLORS.panel2
        end
    end
    if UI.chestFilterButton then
        UI.chestFilterButton.Text = CHEST.getFilterSummary()
        local count = 0
        for _, tier in ipairs(CHEST_TIER_ORDER) do
            if CHEST.tierSelection[tier] then count = count + 1 end
        end
        UI.chestFilterButton.BackgroundColor3 = count == #CHEST_TIER_ORDER and COLORS.panel2 or (count == 0 and COLORS.danger or COLORS.accent)
    end
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
        herbFilterButton.Text = getHerbFilterSummary()
        local count = 0
        for _, species in ipairs(HERB_SPECIES) do
            if herbSpeciesSelection[species] then count = count + 1 end
        end
        herbFilterButton.BackgroundColor3 = count == #HERB_SPECIES and COLORS.panel2 or (count == 0 and COLORS.danger or COLORS.accent)
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
    if UI.chestButton then
        UI.chestButton.Text = CHEST.autoEnabled and "CHESTS: ON" or "CHESTS: OFF"
        UI.chestButton.BackgroundColor3 = CHEST.autoEnabled and COLORS.success or COLORS.panel2
    end
    if UI.silverButton then
        UI.silverButton.Text = SILVER.autoEnabled and "AUTO SILVER: ON" or "AUTO SILVER: OFF"
        UI.silverButton.BackgroundColor3 = SILVER.autoEnabled and COLORS.success or COLORS.panel2
    end
    if brewRecipeButton then
        local selectedCount = 0
        for _, key in ipairs(BREW_RECIPE_ORDER) do
            if brewRecipeSelection[key] then
                selectedCount = selectedCount + 1
            end
        end
        brewRecipeButton.Text = getBrewRecipeSummary()
        brewRecipeButton.BackgroundColor3 = selectedCount > 0 and COLORS.panel2 or COLORS.danger
    end
    updateBrewRecipePicker()
    updateHerbFilterPicker()
    CHEST.updateFilterPicker()
    if herbInfoLabel then
        herbInfoLabel.Text = string.format("Herbs: %d collected | %s", herbCollectedCount, herbActiveName)
    end
    if UI.chestInfoLabel then
        UI.chestInfoLabel.Text = string.format("Chests: %d opened | %s", CHEST.openedCount, CHEST.activeName)
    end
    HERB_MONITOR.update(false)
    ECONOMY.updateUI()
    if SILVER.setStatus then SILVER.setStatus(SILVER.activeName) end
end

local function createGui()
    local parent = getGuiParent()
    local old = parent:FindFirstChild("CUAutoCultivation_v08")
        or parent:FindFirstChild("CUAutoCultivation_v09")
        or parent:FindFirstChild("CUAutoCultivation_v091")
    if old then pcall(function() old:Destroy() end) end

    gui = make("ScreenGui", {
        Name = "CUAutoCultivation_v091",
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
        Text = "CULTIVATION UNBOUND  |  AUTO SUITE v0.9.1",
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

    local pageNames = {"Overview", "Cultivation", "Farming", "Alchemy", "Economy", "Settings"}
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

    local tabWidth = 98
    for index, name in ipairs(pageNames) do
        local tab = make("TextButton", {
            Name = name .. "Tab",
            Position = UDim2.fromOffset(12 + (index - 1) * 105, 46),
            Size = UDim2.fromOffset(tabWidth, 28),
            BackgroundColor3 = name == "Overview" and COLORS.accent or COLORS.panel2,
            BorderSizePixel = 0,
            AutoButtonColor = true,
            Font = Enum.Font.GothamBold,
            Text = string.upper(name),
            TextColor3 = COLORS.text,
            TextSize = 9,
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
            if brewRecipePicker then brewRecipePicker.Visible = false end
            if UI.chestFilterPicker then UI.chestFilterPicker.Visible = false end
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
    makeLabel(overviewHint, "Cultivation, herbs, chests, brewing and Silver farming each have independent controls in their tabs.", 12, 30, 568, 34, 11, COLORS.text)
    makeLabel(overviewHint, "Reroll odds are displayed in Economy. Primordial Stone farming remains unassigned until a repeatable reward source is verified.", 12, 70, 568, 42, 10, COLORS.muted)
    makeLabel(overviewHint, "No client-forged currency or reward events are sent by this script.", 12, 116, 568, 20, 9, COLORS.warning)

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

    -- FARMING PAGE
    local farmingPage = pageFrames.Farming
    makeLabel(farmingPage, "WORLD COLLECTION AND NPC SILVER FARMING", 16, 10, 600, 20, 11, COLORS.success, Enum.Font.GothamBold)
    local herbCard = makeCard(farmingPage, 16, 38, 292, 152, "HERB COLLECTION", COLORS.success)
    herbButton = makeButton(herbCard, "HERBS: OFF", 12, 28, 128, COLORS.panel2, 28)
    herbFilterButton = makeButton(herbCard, "HERB FILTER: ALL", 148, 28, 132, COLORS.panel2, 28)
    herbInfoLabel = makeLabel(herbCard, "Herbs: 0 collected | idle", 12, 65, 268, 18, 9, COLORS.muted)
    UI.herbMonitorLabel = makeLabel(herbCard, "Normal/Spirit 1/10/100/1k: scanning...", 12, 91, 268, 45, 9, COLORS.muted, Enum.Font.Code)

    local chestCard = makeCard(farmingPage, 322, 38, 292, 152, "WORLD CHESTS", COLORS.warning)
    UI.chestButton = makeButton(chestCard, "CHESTS: OFF", 12, 28, 128, COLORS.panel2, 28)
    UI.chestFilterButton = makeButton(chestCard, "CHEST FILTER: ALL", 148, 28, 132, COLORS.panel2, 28)
    UI.chestInfoLabel = makeLabel(chestCard, "Chests: 0 opened | idle", 12, 65, 268, 18, 9, COLORS.muted)
    makeLabel(chestCard, "Priority: Celestial > Jade > Bronze > Wooden", 12, 91, 268, 35, 9, COLORS.muted)

    local silverCardFarm = makeCard(farmingPage, 16, 204, 598, 160, "AUTO SILVER - CULTIVATOR CAMPS", COLORS.warning)
    UI.silverButton = makeButton(silverCardFarm, "AUTO SILVER: OFF", 12, 29, 180, COLORS.panel2, 30)
    UI.silverInfoLabel = makeLabel(silverCardFarm, "Auto Silver: idle", 204, 29, 370, 28, 10, COLORS.muted)
    UI.silverTargetLabel = makeLabel(silverCardFarm, "Target: none | Kills: 0 | Earned: 0", 12, 70, 570, 20, 10, COLORS.text)
    makeLabel(silverCardFarm, "Targets non-boss CultivatorCamps NPCs at or below your Qi realm. Requires your sword drawn; uses normal M1 input.", 12, 99, 570, 44, 9, COLORS.muted)

    -- ALCHEMY PAGE
    local alchemyPage = pageFrames.Alchemy
    makeLabel(alchemyPage, "ALCHEMY QUEUE", 16, 12, 600, 20, 11, COLORS.warning, Enum.Font.GothamBold)
    local brewCard = makeCard(alchemyPage, 16, 44, 598, 220, "AUTO BREW", COLORS.warning)
    brewButton = makeButton(brewCard, "BREW: OFF", 12, 31, 170, COLORS.panel2, 32)
    brewRecipeButton = makeButton(brewCard, getBrewRecipeSummary(), 194, 31, 380, COLORS.panel2, 32)
    makeLabel(brewCard, "Select multiple recipes. The queue checks ingredients, uses the oldest available herbs, Stoke timing, and verifies Claim before moving to the next pill.", 12, 82, 570, 55, 10, COLORS.text)
    makeLabel(brewCard, "Auto Brew starts only while the Alchemy Cauldron is open. It will not spend the Robux Finish Now option.", 12, 146, 570, 42, 9, COLORS.muted)

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
        updateModeButtons()
        setStatus("All five normal herb species enabled. Oldest available herbs are prioritized.", COLORS.success)
    end)
    for index, species in ipairs(HERB_SPECIES) do
        local toggle = makeButton(herbFilterPicker, species, 8, 53 + (index - 1) * 27, 194, COLORS.success, 23)
        herbFilterToggleButtons[species] = toggle
        addConnection(toggle.MouseButton1Click, function()
            herbSpeciesSelection[species] = not herbSpeciesSelection[species]
            updateModeButtons()
            setStatus(species .. (herbSpeciesSelection[species] and " enabled for collection." or " excluded from collection."), COLORS.success)
        end)
    end
    local herbFilterDone = makeButton(herbFilterPicker, "DONE", 8, 190, 194, COLORS.accent, 22)
    addConnection(herbFilterDone.MouseButton1Click, function() herbFilterPicker.Visible = false end)

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
            updateModeButtons()
        end)
    end
    local recipeDone = makeButton(brewRecipePicker, "DONE", 8, 145, 194, COLORS.accent, 22)
    addConnection(recipeDone.MouseButton1Click, function() brewRecipePicker.Visible = false end)

    UI.chestFilterPicker = make("Frame", {
        Name = "ChestFilterPicker",
        Position = UDim2.fromOffset(390, 220),
        Size = UDim2.fromOffset(210, 174),
        BackgroundColor3 = COLORS.bg,
        BackgroundTransparency = 0.02,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 22,
    }, farmingPage)
    round(UI.chestFilterPicker, 8)
    make("UIStroke", {Color = Color3.fromRGB(80, 96, 124), Thickness = 1}, UI.chestFilterPicker)
    makeLabel(UI.chestFilterPicker, "SELECT CHEST TIERS", 9, 5, 190, 18, 10, COLORS.text, Enum.Font.GothamBold)
    local allChestButton = makeButton(UI.chestFilterPicker, "SELECT ALL", 8, 27, 194, COLORS.accent, 22)
    addConnection(allChestButton.MouseButton1Click, function()
        for _, tier in ipairs(CHEST_TIER_ORDER) do CHEST.tierSelection[tier] = true end
        updateModeButtons()
        CHEST.setStatus("all chest tiers enabled; highest tier first")
    end)
    for index, tier in ipairs(CHEST_TIER_ORDER) do
        local toggle = makeButton(UI.chestFilterPicker, tier, 8, 53 + (index - 1) * 25, 194, COLORS.success, 22)
        UI.chestFilterToggleButtons[tier] = toggle
        addConnection(toggle.MouseButton1Click, function()
            CHEST.tierSelection[tier] = not CHEST.tierSelection[tier]
            updateModeButtons()
            CHEST.setStatus(tier .. (CHEST.tierSelection[tier] and " enabled" or " excluded"))
        end)
    end
    local chestDone = makeButton(UI.chestFilterPicker, "DONE", 8, 157, 194, COLORS.accent, 22)
    addConnection(chestDone.MouseButton1Click, function() UI.chestFilterPicker.Visible = false end)

    for _, picker in ipairs({herbFilterPicker, brewRecipePicker, UI.chestFilterPicker}) do
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
            setStatus("Body Auto Cultivation ON. Selecting the best unlocked Body zone.", COLORS.success)
        end
        trainingToggleAttempts = 0
        trainingToggleAt = 0
        lastTeleportTarget = nil
        updateModeButtons()
    end)

    addConnection(herbButton.MouseButton1Click, function()
        autoHerbsEnabled = not autoHerbsEnabled
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
        brewRecipePicker.Visible = false
        UI.chestFilterPicker.Visible = false
        updateModeButtons()
        setStatus("Choose which herb species Auto Herbs may collect. Oldest HerbYear is prioritized.", COLORS.success)
    end)

    addConnection(UI.chestButton.MouseButton1Click, function()
        CHEST.autoEnabled = not CHEST.autoEnabled
        updateModeButtons()
        if CHEST.autoEnabled then
            CHEST.setStatus("scanning; Celestial > Jade > Bronze > Wooden")
            setStatus("Auto Chest enabled. It pauses other farming activities, opens the highest selected tier, and verifies ChestWorldOpened.", COLORS.success)
            CHEST.run()
        else
            CHEST.setStatus("turning off after current prompt hold")
            setStatus("Auto Chest disabled; releasing any active prompt hold and restoring activity.", COLORS.warning)
        end
    end)

    addConnection(UI.chestFilterButton.MouseButton1Click, function()
        UI.chestFilterPicker.Visible = not UI.chestFilterPicker.Visible
        herbFilterPicker.Visible = false
        brewRecipePicker.Visible = false
        updateModeButtons()
        CHEST.setStatus("select allowed tiers; highest enabled tier is opened first")
    end)

    addConnection(brewButton.MouseButton1Click, function()
        autoBrewEnabled = not autoBrewEnabled
        updateModeButtons()
        if autoBrewEnabled then
            setStatus("Auto Brew enabled. Open the Alchemy Cauldron; oldest available herbs will be selected.", COLORS.success)
            runAutoBrew()
        else
            setStatus("Auto Brew disabled. Current in-progress brew will be left untouched.", COLORS.warning)
        end
    end)

    addConnection(brewRecipeButton.MouseButton1Click, function()
        brewRecipePicker.Visible = not brewRecipePicker.Visible
        herbFilterPicker.Visible = false
        UI.chestFilterPicker.Visible = false
        updateModeButtons()
        setStatus("Select any combination of Qi, Body, Bloodfury, and Vitality pills. Auto Brew rotates through selected recipes.", COLORS.success)
    end)

    addConnection(UI.silverButton.MouseButton1Click, function()
        SILVER.autoEnabled = not SILVER.autoEnabled
        updateModeButtons()
        if SILVER.autoEnabled then
            SILVER.setStatus("scanning eligible non-boss cultivators")
            setStatus("Auto Silver enabled. It targets CultivatorCamps NPCs at or below your Qi realm using normal M1 input; no reward remotes are fired.", COLORS.success)
            SILVER.run()
        else
            SILVER.setStatus("stopping after current attack")
            setStatus("Auto Silver disabled; it will stop after the current input and resume selected cultivation.", COLORS.warning)
        end
    end)

    addConnection(breakthroughButton.MouseButton1Click, function()
        breakthroughEnabled = not breakthroughEnabled
        updateModeButtons()
        setStatus(breakthroughEnabled and "Auto Breakthrough enabled." or "Auto Breakthrough disabled.", breakthroughEnabled and COLORS.success or COLORS.warning)
    end)

    addConnection(antiAfkButton.MouseButton1Click, function()
        antiAfkEnabled = not antiAfkEnabled
        updateModeButtons()
        setStatus(antiAfkEnabled and "Anti-AFK enabled." or "Anti-AFK disabled.", antiAfkEnabled and COLORS.success or COLORS.warning)
    end)

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
    ECONOMY.updateUI()
    SILVER.setStatus("idle")
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
                    if SILVER.busy and SILVER.currentTarget then
                        SILVER.earned = SILVER.earned + amount
                    end
                    ECONOMY.updateUI()
                    if SILVER.busy then SILVER.setStatus("Silver reward +" .. ECONOMY.formatNumber(amount) .. " received") end
                end
            end)
        end

        local qiRemote = eventsFolder:FindFirstChild("UpdateClient")
        if qiRemote and qiRemote:IsA("RemoteEvent") then
            addConnection(qiRemote.OnClientEvent, function(data)
                if type(data) == "table" then
                    qiState = data
                end
            end)
        end

        local bodyRemote = eventsFolder:FindFirstChild("UpdateBodyClient")
        if bodyRemote and bodyRemote:IsA("RemoteEvent") then
            addConnection(bodyRemote.OnClientEvent, function(data)
                if type(data) == "table" then
                    bodyState = data
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
            end)
        end

        local chestWorldOpenedRemote = eventsFolder:FindFirstChild("ChestWorldOpened")
        if chestWorldOpenedRemote and chestWorldOpenedRemote:IsA("RemoteEvent") then
            addConnection(chestWorldOpenedRemote.OnClientEvent, function(chest, tier, opener, rewards)
                CHEST.worldOpenedRevision = CHEST.worldOpenedRevision + 1
                local chestName = typeof(chest) == "Instance" and chest.Name or nil
                local playerName = typeof(opener) == "Instance" and opener.Name or tostring(opener or "")
                CHEST.lastWorldOpened = {
                    revision = CHEST.worldOpenedRevision,
                    chest = typeof(chest) == "Instance" and chest or nil,
                    chestName = chestName,
                    tier = tostring(tier or ""),
                    playerName = playerName,
                    rewards = type(rewards) == "table" and rewards or nil,
                }
                if playerName == LocalPlayer.Name then
                    CHEST.activeName = "reward event received: " .. tostring(tier or "chest")
                end
            end)
        end

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
        print("[CU AutoCultivation] Anti-AFK input sent.")
    else
        lastError = tostring(err)
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
CHEST.updateMonitor()

task.spawn(function()
    while running do
        task.wait(2)
        if running then
            HERB_MONITOR.update(true)
            CHEST.updateMonitor()
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

    if CHEST.pendingManualResume and not paused and not CHEST.busy and not SILVER.busy and not herbCollectorBusy and not autoBrewBusy then
        local resumeMode = CHEST.pendingManualResume
        CHEST.pendingManualResume = nil
        if running and not isTrainingActive(resumeMode) then
            activateTraining(resumeMode)
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

print("[CU AutoCultivation] Qi and Body auto modes are OFF until selected.")
print("[CU AutoCultivation] v0.9.1 loaded. Fixed UI initialization, Auto Silver toggle, chest prompt verification, and floating restore icon.")
print("[CU AutoCultivation] Auto Chest prioritizes Celestial > Jade > Bronze > Wooden and verifies ChestWorldOpened for the local player.")
print("[CU AutoCultivation] Auto Silver uses normal M1 input against non-boss CultivatorCamps NPCs at or below the current Qi realm; no reward remotes are fired.")
print("[CU AutoCultivation] Herb monitor shows live Normal/Spirit age counts; Auto Herbs still prioritizes oldest HerbYear.")
setStatus("Loaded. Use the tabs to manage cultivation, farming, alchemy, economy and settings. Auto Silver is OFF.", COLORS.success)
