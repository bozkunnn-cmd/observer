--[[
    CULTIVATION UNBOUND - AUTO BREAKTHROUGH
    Version: 0.1

    Shared Qi + Body breakthrough automation.

    What it does:
      1. Reads the currently selected cultivation bar (Qi or Body).
      2. Waits for that bar to reach 100%.
      3. Clicks the game's Breakthrough button once.
      4. If a tribulation UI appears, reads its live hit count.
      5. Clicks the current prompt's transparent Tap button when the
         contracting ring is gold and nearly matches the target seal.
      6. Verifies progress through the game's score UI.

    It does NOT:
      - Start meditation or Body training.
      - Fire game remotes.
      - Change stats or inventory.
      - Press the displayed letter keys.

    Input is a simulated left mouse click on the actual GUI button.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    warn("[CU AutoBreakthrough] LocalPlayer unavailable.")
    return
end

local Env = _G
if type(getgenv) == "function" then
    local ok, result = pcall(getgenv)
    if ok and type(result) == "table" then
        Env = result
    end
end

if type(Env.__CUAutoBreakthroughStop) == "function" then
    pcall(Env.__CUAutoBreakthroughStop, "replaced")
end

local running = true
local paused = false
local autoEnabled = true
local connections = {}
local qiState = nil
local bodyState = nil
local activeTrialGui = nil
local attemptedPrompts = {}
local previousRingSizes = {}
local lastTrialScore = nil
local lastTrialRequired = nil
local lastPrompt1Ref = nil
local lastBreakthroughKey = nil
local lastBreakthroughAt = 0
local breakthroughAttempts = 0
local lastAction = "Starting..."
local lastError = ""
local lastMode = "Unknown"
local lastPercent = nil
local lastTrialText = "Trial: idle"
local gui = nil
local panel = nil
local modeLabel = nil
local progressLabel = nil
local statusLabel = nil
local trialLabel = nil
local pauseButton = nil
local autoButton = nil

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
    Env.__CUAutoBreakthroughStop = nil
    Env.__CUAutoBreakthroughState = nil
    print("[CU AutoBreakthrough] Stopped: " .. tostring(reason or "manual"))
end

Env.__CUAutoBreakthroughStop = stop
Env.__CUAutoBreakthroughState = {
    getStatus = function()
        return {
            running = running,
            paused = paused,
            autoEnabled = autoEnabled,
            mode = lastMode,
            percent = lastPercent,
            action = lastAction,
            trial = lastTrialText,
            error = lastError,
        }
    end,
    stop = stop,
}

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

local function createGui()
    local parent = getGuiParent()
    local old = parent:FindFirstChild("CUAutoBreakthrough_v01")
    if old then
        pcall(function()
            old:Destroy()
        end)
    end

    gui = make("ScreenGui", {
        Name = "CUAutoBreakthrough_v01",
        ResetOnSpawn = false,
        IgnoreGuiInset = false,
        DisplayOrder = 999900,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    }, parent)

    panel = make("Frame", {
        Name = "Panel",
        AnchorPoint = Vector2.new(0, 0),
        Position = UDim2.new(0, 14, 0, 82),
        Size = UDim2.fromOffset(270, 116),
        BackgroundColor3 = COLORS.bg,
        BackgroundTransparency = 0.08,
        BorderSizePixel = 0,
        Active = false,
        Selectable = false,
    }, gui)
    round(panel, 10)

    make("TextLabel", {
        Position = UDim2.fromOffset(11, 7),
        Size = UDim2.new(1, -22, 0, 19),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        Text = "CU AUTO BREAKTHROUGH  v0.1",
        TextColor3 = COLORS.text,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Active = false,
    }, panel)

    modeLabel = make("TextLabel", {
        Position = UDim2.fromOffset(11, 29),
        Size = UDim2.new(1, -22, 0, 16),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        Text = "Mode: waiting for cultivation UI",
        TextColor3 = COLORS.qi,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        Active = false,
    }, panel)

    progressLabel = make("TextLabel", {
        Position = UDim2.fromOffset(11, 47),
        Size = UDim2.new(1, -22, 0, 15),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        Text = "Progress: --",
        TextColor3 = COLORS.text,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        Active = false,
    }, panel)

    statusLabel = make("TextLabel", {
        Position = UDim2.fromOffset(11, 64),
        Size = UDim2.new(1, -22, 0, 15),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        Text = "Waiting...",
        TextColor3 = COLORS.muted,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        Active = false,
    }, panel)

    trialLabel = make("TextLabel", {
        Position = UDim2.fromOffset(11, 80),
        Size = UDim2.new(1, -22, 0, 14),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        Text = "Trial: idle",
        TextColor3 = COLORS.warning,
        TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left,
        Active = false,
    }, panel)

    local function makeButton(text, x, width, color)
        local button = make("TextButton", {
            Position = UDim2.fromOffset(x, 96),
            Size = UDim2.fromOffset(width, 16),
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

    autoButton = makeButton("AUTO: ON", 10, 75, COLORS.success)
    pauseButton = makeButton("PAUSE", 91, 75, COLORS.panel2)
    local hideButton = makeButton("HIDE", 172, 42, COLORS.panel2)
    local stopButton = makeButton("STOP", 218, 42, COLORS.danger)

    addConnection(autoButton.MouseButton1Click, function()
        autoEnabled = not autoEnabled
        autoButton.Text = autoEnabled and "AUTO: ON" or "AUTO: OFF"
        autoButton.BackgroundColor3 = autoEnabled and COLORS.success or COLORS.panel2
        setStatus(autoEnabled and "Automation enabled." or "Automation disabled.", autoEnabled and COLORS.success or COLORS.warning)
    end)

    addConnection(pauseButton.MouseButton1Click, function()
        paused = not paused
        pauseButton.Text = paused and "RESUME" or "PAUSE"
        pauseButton.BackgroundColor3 = paused and COLORS.warning or COLORS.panel2
        setStatus(paused and "Paused; no clicks will be sent." or "Resumed.", paused and COLORS.warning or COLORS.success)
    end)

    addConnection(hideButton.MouseButton1Click, function()
        if panel then
            panel.Visible = false
        end
    end)

    addConnection(stopButton.MouseButton1Click, function()
        stop("stop button")
    end)
end

local function parsePercent(text)
    if type(text) ~= "string" then
        return nil
    end
    local number = string.match(text, "([%d%.]+)%s*%%")
    return tonumber(number)
end

local function ratioPercent(current, maximum)
    current = tonumber(current)
    maximum = tonumber(maximum)
    if not current or not maximum or maximum <= 0 then
        return nil
    end
    return math.clamp((current / maximum) * 100, 0, 100)
end

local function getActiveMode()
    local cultivationGui = PlayerGui:FindFirstChild("CultivationGui")
    local statusPanel = cultivationGui and cultivationGui:FindFirstChild("StatusPanel")
    if not statusPanel then
        return nil
    end

    local mainFrame = statusPanel:FindFirstChild("MainFrame")
    local bodyFrame = statusPanel:FindFirstChild("BodyFrame")
    local mainVisible = mainFrame and mainFrame.Visible
    local bodyVisible = bodyFrame and bodyFrame.Visible

    if mainVisible and not bodyVisible then
        return "Qi", mainFrame, statusPanel
    end
    if bodyVisible and not mainVisible then
        return "Body", bodyFrame, statusPanel
    end

    if mainVisible and bodyVisible then
        if bodyState and bodyState.isPushingUp and not (qiState and qiState.isMeditating) then
            return "Body", bodyFrame, statusPanel
        end
        if qiState and qiState.isMeditating then
            return "Qi", mainFrame, statusPanel
        end
    end

    return nil
end

local function getModeProgress(mode, frame)
    local label
    local fill
    local state

    if mode == "Qi" then
        label = frame:FindFirstChild("ProgressLabel")
        local block = frame:FindFirstChild("Block")
        local bar = block and block:FindFirstChild("QiBarFrame")
        fill = bar and bar:FindFirstChild("QiBarFill")
        state = qiState
    else
        label = frame:FindFirstChild("BodyProgressLabel")
        local block = frame:FindFirstChild("Block")
        local bar = block and block:FindFirstChild("BodyBarFrame")
        fill = bar and bar:FindFirstChild("BodyBarFill")
        state = bodyState
    end

    -- Use the most conservative live reading if multiple sources exist.
    -- This avoids a stale 100% label causing a second click after a reset.
    local percent = nil
    local function includePercent(value)
        if type(value) == "number" then
            value = math.clamp(value, 0, 100)
            if percent == nil or value < percent then
                percent = value
            end
        end
    end

    if label then
        includePercent(parsePercent(label.Text))
    end

    if fill then
        local ok, scale = pcall(function()
            return fill.Size.X.Scale
        end)
        if ok and type(scale) == "number" then
            includePercent(scale * 100)
        end
    end

    if state then
        if mode == "Qi" then
            includePercent(ratioPercent(state.qi, state.maxQi))
        else
            includePercent(ratioPercent(state.bodyExp, state.maxBodyExp))
        end
    end

    local realmName
    local layer
    if mode == "Qi" then
        realmName = state and (state.realmName or tostring(state.realm or "Qi")) or "Qi"
        layer = state and state.layer or nil
    else
        realmName = state and (state.bodyRealmName or tostring(state.bodyRealm or "Body")) or "Body"
        layer = state and state.bodyLayer or nil
    end

    if not layer then
        local layerLabel = frame:FindFirstChild("LayerLabel") or frame:FindFirstChild("BodyLayerLabel")
        if layerLabel and type(layerLabel.Text) == "string" then
            layer = string.match(layerLabel.Text, "Layer%s+(%d+)")
        end
    end

    local signature = mode .. ":" .. tostring(realmName) .. ":" .. tostring(layer or "?")
    return percent, signature
end

local function isGold(color)
    if not color then
        return false
    end
    return color.R >= 0.90 and color.G >= 0.75 and color.B <= 0.65
end

local function getScoreInfo(trialGui)
    local header = trialGui:FindFirstChild("TrialHeader", true)
    local scorePill = header and header:FindFirstChild("ScorePill", true)
    local scoreObject = scorePill and scorePill:FindFirstChild("Score", true)
    local scoreText = scoreObject and scoreObject.Text or nil

    if not scoreText then
        for _, descendant in ipairs(trialGui:GetDescendants()) do
            if descendant:IsA("TextLabel") then
                local text = descendant.Text
                if type(text) == "string" and string.match(text, "%d+%s*/%s*%d+%s*hits") then
                    scoreText = text
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
    local mode = lastMode
    local names
    if mode == "Body" then
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
            table.insert(prompts, {
                number = tonumber(number),
                object = object,
            })
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

    -- Fallback for the Body trial variant if its prompt container is named
    -- differently but still contains the same Ring / Seal / Tap controls.
    if #prompts == 0 then
        for _, descendant in ipairs(trialGui:GetDescendants()) do
            local ring = descendant:FindFirstChild("Ring")
            local seal = descendant:FindFirstChild("Seal")
            local isPromptContainer = descendant:IsA("CanvasGroup") or descendant:IsA("Frame")
            if isPromptContainer and ring and seal then
                local number = tonumber(string.match(descendant.Name, "%d+")) or (#prompts + 1)
                table.insert(prompts, {
                    number = number,
                    object = descendant,
                })
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

local function clickGuiButton(button)
    if not button or not button:IsA("GuiButton") then
        return false, "not a GuiButton"
    end
    if not button.Visible or not button.Active then
        return false, "button not visible/active"
    end

    local position = button.AbsolutePosition
    local size = button.AbsoluteSize
    local x = math.floor(position.X + size.X / 2 + 0.5)
    local y = math.floor(position.Y + size.Y / 2 + 0.5)

    -- Preferred: actual simulated left mouse click at the button center.
    local okVim, vimError = pcall(function()
        local virtualInput = game:GetService("VirtualInputManager")
        virtualInput:SendMouseButtonEvent(x, y, 0, true, game, 0)
        task.delay(0.025, function()
            pcall(function()
                virtualInput:SendMouseButtonEvent(x, y, 0, false, game, 0)
            end)
        end)
    end)
    if okVim then
        return true, "VirtualInputManager"
    end

    -- Executor mouse API fallback.
    if type(mousemoveabs) == "function" and type(mouse1click) == "function" then
        local okMouse = pcall(function()
            mousemoveabs(x, y)
            mouse1click()
        end)
        if okMouse then
            return true, "executor mouse1click"
        end
    end

    -- Roblox GuiButton activation fallback.
    local okActivate = pcall(function()
        button:Activate()
    end)
    if okActivate then
        return true, "GuiButton:Activate"
    end

    -- Signal fallback for executors that expose firesignal.
    if type(firesignal) == "function" then
        local okSignal = pcall(function()
            firesignal(button.Activated)
        end)
        if okSignal then
            return true, "firesignal(Activated)"
        end
    end

    return false, tostring(vimError or "no supported click backend")
end

local function processTrial()
    local trialGui = getActiveTrialGui()
    if not trialGui then
        if activeTrialGui then
            activeTrialGui = nil
            attemptedPrompts = {}
            previousRingSizes = {}
            lastTrialScore = nil
            lastTrialRequired = nil
            lastPrompt1Ref = nil
            lastTrialText = "Trial: idle"
        end
        return false
    end

    if activeTrialGui ~= trialGui then
        activeTrialGui = trialGui
        attemptedPrompts = {}
        previousRingSizes = {}
        lastTrialScore = nil
        lastTrialRequired = nil
        lastPrompt1Ref = nil
        lastTrialText = "Trial detected: " .. trialGui.Name
        setStatus("Tribulation detected; tracking timing ring.", COLORS.warning)
    end

    local current, required, scoreText = getScoreInfo(trialGui)
    if current == nil or required == nil then
        lastTrialText = "Trial active; waiting for score UI"
        return true
    end

    if lastTrialRequired ~= nil and (required ~= lastTrialRequired or (lastTrialScore ~= nil and current < lastTrialScore)) then
        attemptedPrompts = {}
        previousRingSizes = {}
    end
    local prompt1Ref = trialGui:FindFirstChild("Prompt1") or trialGui:FindFirstChild("Prompt1", true)
    if lastPrompt1Ref ~= nil and prompt1Ref ~= nil and prompt1Ref ~= lastPrompt1Ref then
        attemptedPrompts = {}
        previousRingSizes = {}
    end
    if prompt1Ref ~= nil then
        lastPrompt1Ref = prompt1Ref
    end

    lastTrialRequired = required
    lastTrialScore = current

    lastTrialText = "Trial: " .. tostring(current) .. "/" .. tostring(required) .. " hits"
    if current >= required then
        setStatus("Required hits reached; waiting for breakthrough result.", COLORS.success)
        return true
    end

    local promptNumber, prompt = getLatestPrompt(trialGui)
    if not promptNumber or not prompt then
        setStatus("Trial active; waiting for next prompt.", COLORS.warning)
        return true
    end

    local promptKey = trialGui.Name .. ":Prompt" .. tostring(promptNumber)
    if attemptedPrompts[promptKey] then
        setStatus("Prompt " .. tostring(promptNumber) .. " already clicked; waiting for next.", COLORS.muted)
        return true
    end

    local ring = prompt:FindFirstChild("Ring")
    local seal = prompt:FindFirstChild("Seal")
    local tap = seal and seal:FindFirstChild("Tap")

    if not ring or not seal or not tap or not tap:IsA("GuiButton") then
        setStatus("Prompt " .. tostring(promptNumber) .. ": expected Ring/Seal/Tap not found.", COLORS.warning)
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

    -- The recorded successful clicks landed when the ring was about the same
    -- size as the 90px target seal (roughly 1.00-1.03x). The gold stroke is an
    -- approach indicator; size alignment prevents clicking too early.
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
            print("[CU AutoBreakthrough] Trial click: " .. promptKey .. " ratio=" .. string.format("%.3f", ratio))
        else
            setStatus("Click failed: " .. tostring(backend), COLORS.danger)
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

local function processBreakthrough()
    local mode, frame, statusPanel = getActiveMode()
    if not mode or not frame then
        lastMode = "Unknown"
        lastPercent = nil
        return
    end

    lastMode = mode
    local percent, signature = getModeProgress(mode, frame)
    lastPercent = percent

    if modeLabel then
        modeLabel.Text = "Mode: " .. mode
        modeLabel.TextColor3 = mode == "Qi" and COLORS.qi or COLORS.body
    end
    if progressLabel then
        progressLabel.Text = "Progress: " .. (percent and string.format("%.2f%%", percent) or "--")
    end

    if not autoEnabled then
        setStatus("Auto is OFF; monitoring only.", COLORS.muted)
        return
    end

    if percent == nil or percent < 99.95 then
        if percent then
            setStatus("Cultivating; waiting for 100%.", COLORS.muted)
        else
            setStatus("Waiting for " .. mode .. " progress data.", COLORS.muted)
        end
        return
    end

    local row = statusPanel:FindFirstChild("BreakthroughRow")
    local button = row and row:FindFirstChild("BreakthroughBanner")
    if not button or not button:IsA("GuiButton") then
        setStatus("100% reached; Breakthrough button not found.", COLORS.warning)
        return
    end
    if not row.Visible or not button.Visible or not button.Active then
        setStatus("100% reached; waiting for Breakthrough button to activate.", COLORS.warning)
        return
    end

    local now = os.clock()
    if lastBreakthroughKey ~= signature then
        lastBreakthroughKey = signature
        lastBreakthroughAt = 0
        breakthroughAttempts = 0
    end

    if breakthroughAttempts == 0 or (breakthroughAttempts == 1 and now - lastBreakthroughAt >= 2.5) then
        local sent, backend = clickGuiButton(button)
        breakthroughAttempts = breakthroughAttempts + 1
        lastBreakthroughAt = now
        if sent then
            setStatus(
                mode .. " at 100%; clicked Breakthrough (attempt " .. tostring(breakthroughAttempts) .. ").",
                COLORS.success
            )
            print("[CU AutoBreakthrough] " .. mode .. " 100% -> Breakthrough click, " .. signature .. " via " .. backend)
        else
            setStatus("Breakthrough click failed (attempt " .. tostring(breakthroughAttempts) .. "): " .. tostring(backend), COLORS.danger)
        end
    else
        setStatus("Breakthrough click sent; waiting for layer/realm update or tribulation.", COLORS.warning)
    end
end

-- Read replicated cultivation state without modifying or intercepting remotes.
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
    end
end

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
        setStatus(paused and "Paused; no clicks will be sent." or "Resumed.", paused and COLORS.warning or COLORS.success)
    elseif input.KeyCode == Enum.KeyCode.End then
        stop("RightCtrl+End")
    end
end)

-- High-frequency trial timing + low-cost cultivation checks.
local frameCounter = 0
addConnection(RunService.RenderStepped, function()
    if not running or paused then
        return
    end

    frameCounter = frameCounter + 1
    local ok, trialActiveOrError = pcall(processTrial)
    if not ok then
        lastError = tostring(trialActiveOrError)
        setStatus("Trial monitor error: " .. lastError, COLORS.danger)
        return
    end

    if not trialActiveOrError then
        if frameCounter % 6 == 0 then
            local okBreak, breakError = pcall(processBreakthrough)
            if not okBreak then
                lastError = tostring(breakError)
                setStatus("Breakthrough monitor error: " .. lastError, COLORS.danger)
            end
        end
    end

    if trialLabel then
        trialLabel.Text = lastTrialText
    end
end)

print("[CU AutoBreakthrough] Loaded. Shared Qi + Body breakthrough automation is ON.")
print("[CU AutoBreakthrough] It only clicks at 100% and during gold-ring alignment; it does not start cultivation.")
setStatus("Loaded; waiting for Qi or Body to reach 100%.", COLORS.success)
