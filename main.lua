--[[
    CULTIVATION UNBOUND - AUTO CULTIVATION
    Version: 0.3

    Built on the user's working Auto Breakthrough v0.2.

    FEATURES
      - Qi Auto Cultivation: select best eligible Qi zone, teleport, meditate.
      - Body Auto Cultivation: select best eligible Body zone, teleport, push-ups.
      - Re-evaluate the best zone after realm breakthroughs.
      - Preserve the working BreakthroughBanner and tribulation Tap logic.
      - Tribulation processing does not require a readable hit counter.
      - Anti-AFK toggle using LocalPlayer.Idled / VirtualUser.

    IMPORTANT
      - No RemoteEvent:FireServer calls.
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
    pcall(Env.__CUAutoBreakthroughStop, "replaced by v0.3")
end

local running = true
local paused = false
local breakthroughEnabled = true
local antiAfkEnabled = true
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
local pauseButton = nil

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
end

local function stop(reason)
    if not running then
        return
    end
    running = false
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
        if arrived then
            setStatus("Arrived at " .. zone.name .. "; checking the server zone bonus.", COLORS.success)
        else
            setStatus("Teleport was not retained by the game. Server may be correcting CFrame movement.", COLORS.danger)
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
        if type(qiState) == "table" and type(qiState.isMeditating) == "boolean" then
            return qiState.isMeditating
        end
        return readCharacterBool("IsMeditating") == true
    end

    if type(bodyState) == "table" and type(bodyState.isPushingUp) == "boolean" then
        return bodyState.isPushingUp
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
        setStatus("Starting " .. (mode == "Qi" and "Qi meditation" or "Body push-ups") .. " via " .. tostring(backend) .. ".", COLORS.success)
    else
        setStatus("Could not send the " .. (mode == "Qi" and "M" or "P") .. " training input: " .. tostring(backend), COLORS.danger)
    end
end

local function processAutoCultivation()
    if not selectedAutoMode or paused or not running then
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

local function updateModeButtons()
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
end

local function createGui()
    local parent = getGuiParent()
    local old = parent:FindFirstChild("CUAutoCultivation_v03")
    if old then
        pcall(function()
            old:Destroy()
        end)
    end

    gui = make("ScreenGui", {
        Name = "CUAutoCultivation_v03",
        ResetOnSpawn = false,
        IgnoreGuiInset = false,
        DisplayOrder = 999900,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    }, parent)

    panel = make("Frame", {
        Name = "Panel",
        Position = UDim2.new(0, 14, 0, 82),
        Size = UDim2.fromOffset(330, 190),
        BackgroundColor3 = COLORS.bg,
        BackgroundTransparency = 0.06,
        BorderSizePixel = 0,
        Active = true,
        Draggable = true,
    }, gui)
    round(panel, 10)
    make("UIStroke", {Color = Color3.fromRGB(62, 76, 98), Thickness = 1}, panel)

    make("TextLabel", {
        Position = UDim2.fromOffset(11, 7),
        Size = UDim2.new(1, -22, 0, 19),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        Text = "CU AUTO CULTIVATION  v0.3",
        TextColor3 = COLORS.text,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, panel)

    modeLabel = make("TextLabel", {
        Position = UDim2.fromOffset(11, 29),
        Size = UDim2.new(1, -22, 0, 15),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        Text = "Mode: manual monitor",
        TextColor3 = COLORS.qi,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, panel)

    progressLabel = make("TextLabel", {
        Position = UDim2.fromOffset(11, 46),
        Size = UDim2.new(1, -22, 0, 14),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        Text = "Progress: --",
        TextColor3 = COLORS.text,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, panel)

    zoneLabel = make("TextLabel", {
        Position = UDim2.fromOffset(11, 62),
        Size = UDim2.new(1, -22, 0, 14),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        Text = "Best zone: --",
        TextColor3 = COLORS.muted,
        TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, panel)

    statusLabel = make("TextLabel", {
        Position = UDim2.fromOffset(11, 78),
        Size = UDim2.new(1, -22, 0, 28),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        Text = "Waiting...",
        TextColor3 = COLORS.muted,
        TextSize = 9,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
    }, panel)

    trialLabel = make("TextLabel", {
        Position = UDim2.fromOffset(11, 107),
        Size = UDim2.new(1, -22, 0, 13),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        Text = "Trial: idle",
        TextColor3 = COLORS.warning,
        TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, panel)

    local function makeButton(text, x, y, width, color)
        local button = make("TextButton", {
            Position = UDim2.fromOffset(x, y),
            Size = UDim2.fromOffset(width, 22),
            BackgroundColor3 = color or COLORS.panel2,
            BorderSizePixel = 0,
            AutoButtonColor = true,
            Font = Enum.Font.GothamBold,
            Text = text,
            TextColor3 = COLORS.text,
            TextSize = 9,
            Active = true,
            Selectable = true,
        }, panel)
        round(button, 5)
        return button
    end

    qiButton = makeButton("QI AUTO: OFF", 10, 126, 94, COLORS.panel2)
    bodyButton = makeButton("BODY AUTO: OFF", 110, 126, 100, COLORS.panel2)
    breakthroughButton = makeButton("BREAKTHROUGH: ON", 216, 126, 104, COLORS.success)
    antiAfkButton = makeButton("ANTI-AFK: ON", 10, 153, 94, COLORS.success)
    pauseButton = makeButton("PAUSE", 110, 153, 65, COLORS.panel2)
    local hideButton = makeButton("HIDE", 181, 153, 55, COLORS.panel2)
    local stopButton = makeButton("STOP", 242, 153, 78, COLORS.danger)

    addConnection(qiButton.MouseButton1Click, function()
        selectedAutoMode = selectedAutoMode == "Qi" and nil or "Qi"
        trainingToggleAttempts = 0
        lastTeleportTarget = nil
        updateModeButtons()
        setStatus(selectedAutoMode == "Qi" and "Qi Auto Cultivation enabled." or "Auto Cultivation disabled.", selectedAutoMode and COLORS.success or COLORS.warning)
    end)

    addConnection(bodyButton.MouseButton1Click, function()
        selectedAutoMode = selectedAutoMode == "Body" and nil or "Body"
        trainingToggleAttempts = 0
        lastTeleportTarget = nil
        updateModeButtons()
        setStatus(selectedAutoMode == "Body" and "Body Auto Cultivation enabled." or "Auto Cultivation disabled.", selectedAutoMode and COLORS.success or COLORS.warning)
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
        setStatus(paused and "Paused; cultivation and breakthrough actions suspended." or "Resumed.", paused and COLORS.warning or COLORS.success)
    end)

    addConnection(hideButton.MouseButton1Click, function()
        if panel then
            panel.Visible = false
        end
    end)

    addConnection(stopButton.MouseButton1Click, function()
        stop("stop button")
    end)

    updateModeButtons()
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

createGui()

-- Keyboard controls:
-- RightCtrl + Home: show/hide panel
-- RightCtrl + P: pause/resume
-- RightCtrl + End: stop script
addConnection(UserInputService.InputBegan, function(input, gameProcessed)
    if gameProcessed or not running then
        return
    end
    if not UserInputService:IsKeyDown(Enum.KeyCode.RightControl) then
        return
    end

    if input.KeyCode == Enum.KeyCode.Home then
        if panel then
            panel.Visible = not panel.Visible
        end
    elseif input.KeyCode == Enum.KeyCode.P then
        paused = not paused
        if pauseButton then
            pauseButton.Text = paused and "RESUME" or "PAUSE"
            pauseButton.BackgroundColor3 = paused and COLORS.warning or COLORS.panel2
        end
        setStatus(paused and "Paused; cultivation and breakthrough actions suspended." or "Resumed.", paused and COLORS.warning or COLORS.success)
    elseif input.KeyCode == Enum.KeyCode.End then
        stop("RightCtrl+End")
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

    if not trialActiveOrError and frameCounter % 6 == 0 then
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

print("[CU AutoCultivation] v0.3 loaded.")
print("[CU AutoCultivation] Qi and Body auto modes are OFF until selected.")
print("[CU AutoCultivation] Auto Breakthrough and Anti-AFK are ON.")
setStatus("Loaded. Select Qi Auto or Body Auto to begin.", COLORS.success)
