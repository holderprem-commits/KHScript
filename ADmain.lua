local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

--// CONFIGURATION
local CONFIG = {
    RollDelay = 2.5,
    TowerRetryDelay = 1.5,
    DefaultSellThreshold = 0,
    LandscapeWidth = 820,
    LandscapeHeight = 590,
    PortraitWidth = 380,
    PortraitHeight = 650,
}

--// GAME MODULES / REFERENCES
local NetworkFolder = ReplicatedStorage:WaitForChild("Network")
local RollRemote = NetworkFolder
    :WaitForChild("RollService")
    :WaitForChild("RF")
    :WaitForChild("RollDice")

local Framework = ReplicatedStorage:WaitForChild("Framework")
local Features = Framework:WaitForChild("Features")

local TowerController = require(Features:WaitForChild("Towers"):WaitForChild("TowerController"))
local DataController = require(Features:WaitForChild("Data"):WaitForChild("DataController"))
local SettingsConfig = require(Features:WaitForChild("Settings"):WaitForChild("SettingsConfig"))

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Network = require(Packages:WaitForChild("Network"))
local NumberFormatter = require(Packages:WaitForChild("NumberFormatter"))
local QuestConfig = require(Features:WaitForChild("Quests"):WaitForChild("QuestConfig"))

--// QUEST NETWORK
local QuestComm = Network.ClientComm.new(NetworkFolder, false, "QuestService")
local ClaimQuestReward = QuestComm:GetSignal("Claim")
local BuyQuestShopItem = QuestComm:GetSignal("Buy")

--// TOWER NETWORK
local TowerComm = Network.ClientComm.new(NetworkFolder, false, "Towers")
local CancelTower = TowerComm:GetFunction("CancelTower")
local SetAutoTower = TowerComm:GetSignal("SetAutoTower")

--// AUTO SELL NETWORK
local SellComm = Network.ClientComm.new(NetworkFolder, false, "SellService")
local UpdateAutoSell = SellComm:GetSignal("UpdateAutoSell")

--// STATE
local AutoRoll = false
local SkipAnimation = false
local IsRolling = false

local AutoTower = false
local TowerRunning = false
local TowerStartBusy = false
local SelectedTower = "Infinity Tower"

local AutoSellEnabled = false
local SellThreshold = CONFIG.DefaultSellThreshold

local Destroyed = false

local AutoClaimDaily = false
local AutoClaimWeekly = false
local AutoHideTowerUI = false

local QuestShopSelection = {}
for _, shopItem in ipairs(QuestConfig.Shop or {}) do
    QuestShopSelection[shopItem.name] = false
end

-- Named profile support. Auto Roll and Auto Tower Retry are included in
-- profiles and are restored by manual LOAD or AUTO LOAD.
local CONFIG_FOLDER = "KYOSH_AnimeDice_Configs"
local AUTOLOAD_FILE = "KYOSH_AnimeDice_AutoLoad.txt"
local CurrentProfileName = "Default"
local FileSavingAvailable = type(readfile) == "function"
    and type(writefile) == "function"
    and type(isfile) == "function"

local function sanitizeProfileName(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("[^%w%-%_ ]", ""):gsub("%s+", "_")
    if #name > 32 then name = name:sub(1, 32) end
    return name
end

local function ensureConfigFolder()
    -- Profiles are stored as separate files in the executor's root directory
    -- to remain compatible with environments that do not support folders.
end

local function profilePath(name)
    return "KYOSH_AnimeDice_" .. sanitizeProfileName(name) .. ".json"
end

local function getProfileData()
    return {
        AutoRoll = AutoRoll,
        AutoTower = AutoTower,
        AutoTowerRetry = AutoTower,
        SkipAnimation = SkipAnimation,
        SelectedTower = SelectedTower,
        AutoSellEnabled = AutoSellEnabled,
        SellThreshold = SellThreshold,
        AutoClaimDaily = AutoClaimDaily,
        AutoClaimWeekly = AutoClaimWeekly,
        AutoHideTowerUI = AutoHideTowerUI,
        QuestShopSelection = QuestShopSelection,
    }
end

local function applyProfileData(data)
    if type(data) ~= "table" then return false end
    AutoRoll = data.AutoRoll == true

    -- New profiles use AutoTowerRetry; older profiles used AutoTower.
    local savedTowerRetry = data.AutoTowerRetry
    if type(savedTowerRetry) ~= "boolean" then
        savedTowerRetry = data.AutoTower
    end
    AutoTower = savedTowerRetry == true

    SkipAnimation = data.SkipAnimation == true
    AutoSellEnabled = data.AutoSellEnabled == true
    AutoClaimDaily = data.AutoClaimDaily == true
    AutoClaimWeekly = data.AutoClaimWeekly == true
    AutoHideTowerUI = data.AutoHideTowerUI == true

    if type(data.QuestShopSelection) == "table" then
        for _, shopItem in ipairs(QuestConfig.Shop or {}) do
            QuestShopSelection[shopItem.name] = data.QuestShopSelection[shopItem.name] == true
        end
    end

    if type(data.SelectedTower) == "string" then
        SelectedTower = data.SelectedTower
    end
    if typeof(data.SellThreshold) == "number" and data.SellThreshold >= 0 then
        SellThreshold = data.SellThreshold
    end
    return true
end

local function saveConfig(name)
    if not FileSavingAvailable then return false end
    local cleanName = sanitizeProfileName(name or CurrentProfileName)
    if cleanName == "" then return false end
    CurrentProfileName = cleanName
    local success, err = pcall(function()
        ensureConfigFolder()
        writefile(profilePath(cleanName), HttpService:JSONEncode(getProfileData()))
    end)
    if not success then warn("[KYOSH] Profile save failed:", err) end
    return success
end

local function loadConfig(name)
    if not FileSavingAvailable then return false end
    local cleanName = sanitizeProfileName(name or CurrentProfileName)
    if cleanName == "" then return false end
    local success, result = pcall(function()
        local path = profilePath(cleanName)
        if not isfile(path) then return nil end
        return HttpService:JSONDecode(readfile(path))
    end)
    if success and type(result) == "table" then
        CurrentProfileName = cleanName
        return applyProfileData(result)
    end
    if not success then warn("[KYOSH] Profile load failed:", result) end
    return false
end

local function setAutoLoad(name, enabled)
    if not FileSavingAvailable then return false end
    local cleanName = sanitizeProfileName(name or CurrentProfileName)
    if cleanName == "" then return false end
    local success = pcall(function()
        if enabled then
            writefile(AUTOLOAD_FILE, cleanName)
        elseif isfile(AUTOLOAD_FILE) then
            delfile(AUTOLOAD_FILE)
        end
    end)
    return success
end

local function loadAutoProfileName()
    if not FileSavingAvailable then return nil end
    local ok, name = pcall(function()
        if isfile(AUTOLOAD_FILE) then return readfile(AUTOLOAD_FILE) end
    end)
    if ok and type(name) == "string" then return sanitizeProfileName(name) end
    return nil
end

local StartupProfileLoaded = false
local autoProfileName = loadAutoProfileName()
if autoProfileName and autoProfileName ~= "" then
    CurrentProfileName = autoProfileName
    StartupProfileLoaded = loadConfig(autoProfileName)
end

local function saveConfigSoon()
    task.defer(function()
        saveConfig(CurrentProfileName)
    end)
end

local TowerNames = {
    "Infinity Tower",
    "Dragon Tower",
    "Cursed Tower",
    "Pirate Tower",
    "Hidden Leaf Tower",
    "Slayer Tower",
    "Shadow Tower",
    "Soul Tower",
}

if not table.find(TowerNames, SelectedTower) then
    SelectedTower = TowerNames[1]
end

--// COLORS
local COLORS = {
    Background = Color3.fromRGB(15, 13, 25),
    Panel = Color3.fromRGB(26, 22, 43),
    PanelLight = Color3.fromRGB(39, 33, 60),
    Purple = Color3.fromRGB(157, 105, 255),
    PurpleDark = Color3.fromRGB(103, 61, 190),
    White = Color3.fromRGB(247, 244, 255),
    Gray = Color3.fromRGB(166, 158, 188),
    Green = Color3.fromRGB(65, 215, 145),
    Red = Color3.fromRGB(240, 85, 105),
    Border = Color3.fromRGB(75, 61, 105),
}

--// CLEAN UP AN OLDER COPY
local OldGui = PlayerGui:FindFirstChild("KYOSHAnimeDice")
if OldGui then
    OldGui:Destroy()
end

--// GUI ROOT
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "KYOSHAnimeDice"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.DisplayOrder = 50
ScreenGui.Parent = PlayerGui

local Main = Instance.new("Frame")
Main.Name = "Main"
Main.AnchorPoint = Vector2.new(0.5, 0.5)
Main.Position = UDim2.fromScale(0.5, 0.5)
Main.BackgroundColor3 = COLORS.Background
Main.BorderSizePixel = 0
Main.ClipsDescendants = true
Main.Parent = ScreenGui

local MainCorner = Instance.new("UICorner")
MainCorner.CornerRadius = UDim.new(0, 16)
MainCorner.Parent = Main

local MainStroke = Instance.new("UIStroke")
MainStroke.Color = COLORS.Purple
MainStroke.Transparency = 0.25
MainStroke.Thickness = 1.5
MainStroke.Parent = Main

--// HEADER
local Header = Instance.new("Frame")
Header.Name = "Header"
Header.Size = UDim2.new(1, 0, 0, 58)
Header.BackgroundColor3 = COLORS.Panel
Header.BorderSizePixel = 0
Header.Parent = Main

local HeaderCorner = Instance.new("UICorner")
HeaderCorner.CornerRadius = UDim.new(0, 16)
HeaderCorner.Parent = Header

local HeaderTitle = Instance.new("TextLabel")
HeaderTitle.BackgroundTransparency = 1
HeaderTitle.Position = UDim2.fromOffset(16, 7)
HeaderTitle.Size = UDim2.new(1, -75, 0, 26)
HeaderTitle.Font = Enum.Font.GothamBold
HeaderTitle.Text = "KYOSH"
HeaderTitle.TextColor3 = COLORS.White
HeaderTitle.TextSize = 21
HeaderTitle.TextXAlignment = Enum.TextXAlignment.Left
HeaderTitle.Parent = Header

local HeaderSubtitle = Instance.new("TextLabel")
HeaderSubtitle.BackgroundTransparency = 1
HeaderSubtitle.Position = UDim2.fromOffset(17, 33)
HeaderSubtitle.Size = UDim2.new(1, -75, 0, 15)
HeaderSubtitle.Font = Enum.Font.GothamMedium
HeaderSubtitle.Text = "ANIME DICE  /  CONTROL PANEL"
HeaderSubtitle.TextColor3 = COLORS.Gray
HeaderSubtitle.TextSize = 9
HeaderSubtitle.TextXAlignment = Enum.TextXAlignment.Left
HeaderSubtitle.Parent = Header

local CloseButton = Instance.new("TextButton")
CloseButton.Name = "CloseButton"
CloseButton.Size = UDim2.fromOffset(34, 34)
CloseButton.Position = UDim2.new(1, -46, 0, 12)
CloseButton.BackgroundColor3 = Color3.fromRGB(75, 42, 83)
CloseButton.BorderSizePixel = 0
CloseButton.Font = Enum.Font.GothamBold
CloseButton.Text = "×"
CloseButton.TextColor3 = COLORS.White
CloseButton.TextSize = 23
CloseButton.AutoButtonColor = true
CloseButton.Parent = Header
Instance.new("UICorner", CloseButton).CornerRadius = UDim.new(0, 9)

--// DRAGGING (MOUSE + TOUCH)
do
    local dragging = false
    local dragInput
    local dragStart
    local startPosition

    Header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPosition = Main.Position
            dragInput = input
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            Main.Position = UDim2.new(
                startPosition.X.Scale,
                startPosition.X.Offset + delta.X,
                startPosition.Y.Scale,
                startPosition.Y.Offset + delta.Y
            )
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input == dragInput or input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
            dragInput = nil
        end
    end)
end

--// CONTENT SCROLLER
local Content = Instance.new("ScrollingFrame")
Content.Name = "Content"
Content.Position = UDim2.fromOffset(10, 66)
Content.Size = UDim2.new(1, -20, 1, -76)
Content.BackgroundTransparency = 1
Content.BorderSizePixel = 0
Content.ScrollBarThickness = 3
Content.ScrollBarImageColor3 = COLORS.Purple
Content.CanvasSize = UDim2.fromOffset(0, 0)
Content.ScrollingDirection = Enum.ScrollingDirection.Y
Content.Parent = Main

--// UI HELPERS
local function addCorner(object, radius)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius or 9)
    corner.Parent = object
    return corner
end

local function createSection(title, height)
    local section = Instance.new("Frame")
    section.Name = title:gsub("%W", "")
    section.BackgroundColor3 = COLORS.Panel
    section.BorderSizePixel = 0
    section.Size = UDim2.new(0, 350, 0, height)
    section.Parent = Content
    addCorner(section, 12)

    local stroke = Instance.new("UIStroke")
    stroke.Color = COLORS.Border
    stroke.Transparency = 0.65
    stroke.Thickness = 1
    stroke.Parent = section

    local heading = Instance.new("TextLabel")
    heading.BackgroundTransparency = 1
    heading.Position = UDim2.fromOffset(13, 8)
    heading.Size = UDim2.new(1, -26, 0, 21)
    heading.Font = Enum.Font.GothamBold
    heading.Text = title
    heading.TextColor3 = COLORS.Purple
    heading.TextSize = 12
    heading.TextXAlignment = Enum.TextXAlignment.Left
    heading.Parent = section

    return section
end

local function createButton(parent, text, position, size, color)
    local button = Instance.new("TextButton")
    button.Size = size
    button.Position = position
    button.BackgroundColor3 = color or COLORS.PanelLight
    button.BorderSizePixel = 0
    button.Font = Enum.Font.GothamBold
    button.Text = text
    button.TextColor3 = COLORS.White
    button.TextSize = 11
    button.AutoButtonColor = true
    button.Parent = parent
    addCorner(button, 8)
    return button
end

local function createLabel(parent, text, position, size)
    local label = Instance.new("TextLabel")
    label.Size = size
    label.Position = position
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamMedium
    label.Text = text
    label.TextColor3 = COLORS.White
    label.TextSize = 11
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = parent
    return label
end

local function updateToggle(button, enabled)
    button.Text = enabled and "ON" or "OFF"
    button.BackgroundColor3 = enabled and COLORS.PurpleDark or COLORS.PanelLight
end

--// STATUS SECTION
local StatusSection = createSection("SYSTEM STATUS", 66)
local StatusLabel = createLabel(
    StatusSection,
    "●  READY",
    UDim2.fromOffset(13, 34),
    UDim2.new(1, -26, 0, 18)
)
StatusLabel.TextColor3 = COLORS.Green

local function setStatus(message, color)
    if Destroyed then return end
    StatusLabel.Text = "●  " .. message
    StatusLabel.TextColor3 = color or COLORS.Green
end

--// AUTO ROLL SECTION
local RollSection = createSection("ROLL CONTROL", 155)
local SkipLabel = createLabel(
    RollSection,
    "Skip Animation (API not confirmed)",
    UDim2.fromOffset(13, 36),
    UDim2.new(1, -100, 0, 24)
)

local SkipButton = createButton(
    RollSection,
    "OFF",
    UDim2.new(1, -76, 0, 34),
    UDim2.fromOffset(62, 28)
)

local AutoRollLabel = createLabel(
    RollSection,
    "Auto Roll",
    UDim2.fromOffset(13, 72),
    UDim2.new(1, -100, 0, 24)
)

local RollToggle = createButton(
    RollSection,
    "OFF",
    UDim2.new(1, -76, 0, 70),
    UDim2.fromOffset(62, 28)
)

local ManualRoll = createButton(
    RollSection,
    "ROLL NOW",
    UDim2.fromOffset(13, 112),
    UDim2.new(1, -26, 0, 31),
    COLORS.PurpleDark
)

SkipButton.MouseButton1Click:Connect(function()
    SkipAnimation = not SkipAnimation
    updateToggle(SkipButton, SkipAnimation)
    saveConfigSoon()
    setStatus(SkipAnimation and "SKIP ANIMATION TOGGLE ON (VISUAL ONLY)" or "SKIP ANIMATION TOGGLE OFF", COLORS.Gray)
end)

RollToggle.MouseButton1Click:Connect(function()
    AutoRoll = not AutoRoll
    updateToggle(RollToggle, AutoRoll)
    saveConfig(CurrentProfileName)
    saveConfigSoon()
    setStatus(AutoRoll and "AUTO ROLL ENABLED" or "AUTO ROLL DISABLED")
end)

local function performRoll()
    if IsRolling or Destroyed then return end

    IsRolling = true
    setStatus("ROLLING...", COLORS.Purple)

    local success, result = pcall(function()
        return RollRemote:InvokeServer()
    end)

    if success then
        setStatus("ROLL REQUEST COMPLETED", COLORS.Green)
    else
        warn("[KYOSH] Roll failed:", result)
        setStatus("ROLL FAILED", COLORS.Red)
    end

    IsRolling = false
end

ManualRoll.MouseButton1Click:Connect(function()
    task.spawn(performRoll)
end)

task.spawn(function()
    while not Destroyed do
        if AutoRoll and not IsRolling then
            performRoll()
        end
        task.wait(CONFIG.RollDelay)
    end
end)

--// AUTO TOWER SECTION
local TowerSection = createSection("AUTO TOWER", 280)
local SelectedTowerLabel = createLabel(
    TowerSection,
    "SELECTED: " .. string.upper(SelectedTower),
    UDim2.fromOffset(13, 33),
    UDim2.new(1, -26, 0, 18)
)

local TowerGrid = Instance.new("Frame")
TowerGrid.Name = "TowerGrid"
TowerGrid.Position = UDim2.fromOffset(13, 57)
TowerGrid.Size = UDim2.new(1, -26, 0, 112)
TowerGrid.BackgroundTransparency = 1
TowerGrid.Parent = TowerSection

local GridLayout = Instance.new("UIGridLayout")
GridLayout.CellSize = UDim2.new(0.5, -5, 0, 25)
GridLayout.CellPadding = UDim2.fromOffset(8, 5)
GridLayout.SortOrder = Enum.SortOrder.LayoutOrder
GridLayout.Parent = TowerGrid

local TowerButtons = {}

local function selectTower(name)
    SelectedTower = name
    saveConfigSoon()
    SelectedTowerLabel.Text = "SELECTED: " .. string.upper(name)

    for towerName, button in pairs(TowerButtons) do
        local selected = towerName == name
        button.BackgroundColor3 = selected and COLORS.PurpleDark or COLORS.PanelLight

        local selectionStroke = button:FindFirstChild("SelectionStroke")
        if selectionStroke then
            selectionStroke.Transparency = selected and 0 or 1
        end
    end
end

for index, towerName in ipairs(TowerNames) do
    local button = createButton(
        TowerGrid,
        towerName,
        UDim2.new(),
        UDim2.new(),
        COLORS.PanelLight
    )
    button.LayoutOrder = index
    button.TextSize = 10

    local selectionStroke = Instance.new("UIStroke")
    selectionStroke.Name = "SelectionStroke"
    selectionStroke.Color = COLORS.Purple
    selectionStroke.Thickness = 1.5
    selectionStroke.Transparency = 1
    selectionStroke.Parent = button

    TowerButtons[towerName] = button
    button.MouseButton1Click:Connect(function()
        selectTower(towerName)
    end)
end

selectTower(SelectedTower)

local StartTower = createButton(
    TowerSection,
    "START SELECTED",
    UDim2.fromOffset(13, 180),
    UDim2.new(0.5, -18, 0, 32),
    COLORS.PurpleDark
)

local StopTower = createButton(
    TowerSection,
    "STOP",
    UDim2.new(0.5, 5, 0, 180),
    UDim2.new(0.5, -18, 0, 32),
    Color3.fromRGB(115, 40, 65)
)

local AutoTowerLabel = createLabel(
    TowerSection,
    "Auto Tower Retry",
    UDim2.fromOffset(13, 224),
    UDim2.new(1, -100, 0, 24)
)

local AutoTowerButton = createButton(
    TowerSection,
    "OFF",
    UDim2.new(1, -76, 0, 222),
    UDim2.fromOffset(62, 28)
)

local AutoHideLabel = createLabel(
    TowerSection,
    "Auto Hide Unit Selection UI",
    UDim2.fromOffset(13, 248),
    UDim2.new(1, -115, 0, 18)
)
AutoHideLabel.TextSize = 9

local AutoHideToggle = createButton(
    TowerSection,
    "OFF",
    UDim2.new(1, -76, 0, 244),
    UDim2.fromOffset(62, 26)
)

local function startSelectedTower()
    if Destroyed or TowerStartBusy then return end
    TowerStartBusy = true

    local success, result = pcall(function()
        return TowerController.startTower(SelectedTower)
    end)

    TowerStartBusy = false
    if success then
        TowerRunning = true
        setStatus("STARTING " .. string.upper(SelectedTower))
    else
        TowerRunning = false
        warn("[KYOSH] Tower start failed:", result)
        setStatus("TOWER START FAILED", COLORS.Red)
    end
end

local function stopSelectedTower()
    AutoTower = false
    TowerRunning = false
    updateToggle(AutoTowerButton, false)

    pcall(function()
        SetAutoTower:Fire(false)
    end)

    pcall(function()
        CancelTower()
    end)

    saveConfigSoon()
    setStatus("TOWER STOPPED", COLORS.Red)
end

StartTower.MouseButton1Click:Connect(function()
    task.spawn(startSelectedTower)
end)

StopTower.MouseButton1Click:Connect(stopSelectedTower)

AutoTowerButton.MouseButton1Click:Connect(function()
    AutoTower = not AutoTower
    updateToggle(AutoTowerButton, AutoTower)
    saveConfig(CurrentProfileName)
    saveConfigSoon()

    if AutoTower then
        setStatus("AUTO TOWER RETRY ENABLED")
        task.spawn(startSelectedTower)
    else
        pcall(function()
            SetAutoTower:Fire(false)
        end)
        setStatus("AUTO TOWER DISABLED", COLORS.Gray)
    end
end)

task.spawn(function()
    while not Destroyed do
        if AutoTower then
            task.wait(CONFIG.TowerRetryDelay)
            if AutoTower and not Destroyed and not TowerStartBusy then
                task.spawn(startSelectedTower)
            end
        else
            task.wait(0.25)
        end
    end
end)

-- Auto-hide the Tower.Screen selection overlay using the game's actual UI tree:
-- PlayerGui > Root > Tower > Screen. Keep the branch containing "Floor 1" visible.
local HiddenTowerObjects = {}

local function subtreeHasFloorOne(root)
    for _, descendant in ipairs(root:GetDescendants()) do
        if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
            local normalized = string.lower(descendant.Text or ""):gsub("%s+", "")
            if normalized:find("floor1", 1, true) then
                return true
            end
        end
    end
    if root:IsA("TextLabel") or root:IsA("TextButton") then
        local normalized = string.lower(root.Text or ""):gsub("%s+", "")
        if normalized:find("floor1", 1, true) then return true end
    end
    return false
end

local function rememberAndHide(object)
    if HiddenTowerObjects[object] == nil then
        HiddenTowerObjects[object] = object.Visible
    end
    object.Visible = false
end

local function restoreHiddenTowerObjects()
    for object, oldVisible in pairs(HiddenTowerObjects) do
        if object and object.Parent then
            object.Visible = oldVisible
        end
    end
    table.clear(HiddenTowerObjects)
end

local function findTowerScreen()
    local root = PlayerGui:FindFirstChild("Root")
    if not root then return nil end
    local tower = root:FindFirstChild("Tower")
    if not tower then return nil end
    local screen = tower:FindFirstChild("Screen")
    if screen and screen:IsA("GuiObject") then return screen end
    return nil
end

local function updateAutoHideTowerUI()
    if not AutoHideTowerUI then
        restoreHiddenTowerObjects()
        return
    end

    local towerScreen = findTowerScreen()
    if not towerScreen then return end

    -- Hide each direct child panel except the one containing the central Floor 1 label.
    -- This keeps the floor indicator visible while removing the unit-pick panels.
    for _, child in ipairs(towerScreen:GetChildren()) do
        if child:IsA("GuiObject") then
            if subtreeHasFloorOne(child) then
                -- Ensure the Floor 1 branch remains visible if a previous pass hid it.
                if HiddenTowerObjects[child] ~= nil then
                    child.Visible = HiddenTowerObjects[child]
                    HiddenTowerObjects[child] = nil
                end
            else
                rememberAndHide(child)
            end
        end
    end

    -- If the game's title is found outside the expected direct-child layout,
    -- hide only its nearest panel and never hide a panel containing Floor 1.
    for _, descendant in ipairs(towerScreen:GetDescendants()) do
        if descendant:IsA("TextLabel") and string.find(string.lower(descendant.Text or ""), "click on a unit", 1, true) then
            local panel = descendant.Parent
            while panel and panel ~= towerScreen and not panel:IsA("Frame") do
                panel = panel.Parent
            end
            if panel and panel ~= towerScreen and panel:IsA("GuiObject") and not subtreeHasFloorOne(panel) then
                rememberAndHide(panel)
            end
        end
    end
end

AutoHideToggle.MouseButton1Click:Connect(function()
    AutoHideTowerUI = not AutoHideTowerUI
    updateToggle(AutoHideToggle, AutoHideTowerUI)
    saveConfigSoon()
    updateAutoHideTowerUI()
end)

task.spawn(function()
    while not Destroyed do
        if AutoHideTowerUI then updateAutoHideTowerUI() end
        task.wait(0.35)
    end
end)

--// AUTO SELL SECTION
local SellSection = createSection("AUTO SELL", 205)
local SellDescription = createLabel(
    SellSection,
    "Sell items at or below your configured threshold",
    UDim2.fromOffset(13, 34),
    UDim2.new(1, -26, 0, 20)
)
SellDescription.TextColor3 = COLORS.Gray
SellDescription.TextSize = 10

local SellInput = Instance.new("TextBox")
SellInput.Name = "SellThresholdInput"
SellInput.Size = UDim2.new(1, -26, 0, 36)
SellInput.Position = UDim2.fromOffset(13, 62)
SellInput.BackgroundColor3 = COLORS.PanelLight
SellInput.BorderSizePixel = 0
SellInput.PlaceholderText = "Example: 1b, 1t, 1sp, 1sx"
SellInput.PlaceholderColor3 = COLORS.Gray
SellInput.TextColor3 = COLORS.White
SellInput.TextSize = 13
SellInput.Font = Enum.Font.GothamMedium
SellInput.ClearTextOnFocus = false
SellInput.Text = ""
SellInput.TextXAlignment = Enum.TextXAlignment.Left
SellInput.Parent = SellSection
addCorner(SellInput, 8)

local SellInputPadding = Instance.new("UIPadding")
SellInputPadding.PaddingLeft = UDim.new(0, 10)
SellInputPadding.PaddingRight = UDim.new(0, 10)
SellInputPadding.Parent = SellInput

local SellToggleLabel = createLabel(
    SellSection,
    "Auto Sell",
    UDim2.fromOffset(13, 116),
    UDim2.new(1, -100, 0, 25)
)

local SellToggle = createButton(
    SellSection,
    "OFF",
    UDim2.new(1, -76, 0, 113),
    UDim2.fromOffset(62, 29)
)

local SellApplyButton = createButton(
    SellSection,
    "APPLY THRESHOLD",
    UDim2.fromOffset(13, 157),
    UDim2.new(1, -26, 0, 32),
    COLORS.PurpleDark
)

-- Uses the same compact parser as the game's original AutoSell controller.
local function parseSellValue(inputText)
    local text = tostring(inputText or "")
    text = text:gsub(",", "")
    text = text:gsub("%s+", "")

    if text == "" then
        return 0
    end

    local success, value = pcall(function()
        local numericValue = tonumber(text)
        if numericValue ~= nil then
            return numericValue
        end
        return NumberFormatter.ParseCompact(text)
    end)

    if not success or typeof(value) ~= "number" then
        return nil
    end

    if value ~= value or value == math.huge or value == -math.huge then
        return nil
    end

    return value
end

local function formatSellValue(value)
    if typeof(value) ~= "number" or value <= 0 then
        return ""
    end

    local success, formatted = pcall(function()
        return NumberFormatter.FormatCompact(value)
    end)

    if success then
        return tostring(formatted)
    end

    return tostring(value)
end

local function applySellThreshold(value)
    if typeof(value) ~= "number" or value < 0 then
        setStatus("INVALID SELL THRESHOLD", COLORS.Red)
        return false
    end

    local validationSuccess, isValid = pcall(function()
        return SettingsConfig.IsValid("AutoSell", value)
    end)

    if not validationSuccess or not isValid then
        setStatus("THRESHOLD REJECTED BY GAME SETTINGS", COLORS.Red)
        return false
    end

    local fireSuccess, fireError = pcall(function()
        UpdateAutoSell:Fire(value)
    end)

    if not fireSuccess then
        warn("[KYOSH] Auto Sell update failed:", fireError)
        setStatus("AUTO SELL UPDATE FAILED", COLORS.Red)
        return false
    end

    return true
end

local function commitSellInput(enableAfterApply)
    local value = parseSellValue(SellInput.Text)

    if value == nil or value < 0 then
        SellInput.Text = formatSellValue(SellThreshold)
        setStatus("INVALID NUMBER FORMAT", COLORS.Red)
        return false
    end

    if value == 0 then
        SellThreshold = 0
        saveConfigSoon()
        SellInput.Text = ""
        if AutoSellEnabled or enableAfterApply then
            if applySellThreshold(0) then
                AutoSellEnabled = false
                updateToggle(SellToggle, false)
                setStatus("AUTO SELL DISABLED", COLORS.Gray)
                return true
            end
        end
        setStatus("THRESHOLD CLEARED", COLORS.Gray)
        return true
    end

    if not AutoSellEnabled and not enableAfterApply then
        SellThreshold = value
        saveConfigSoon()
        SellInput.Text = formatSellValue(value)
        setStatus("THRESHOLD SAVED - AUTO SELL IS OFF", COLORS.Gray)
        return true
    end

    if applySellThreshold(value) then
        SellThreshold = value
        saveConfigSoon()
        SellInput.Text = formatSellValue(value)
        if enableAfterApply then
            AutoSellEnabled = true
            updateToggle(SellToggle, true)
        end
        setStatus("AUTO SELL THRESHOLD UPDATED")
        return true
    end

    SellInput.Text = formatSellValue(SellThreshold)
    return false
end

SellInput.FocusLost:Connect(function()
    if SellInput.Text ~= "" then
        commitSellInput(false)
    end
end)

SellApplyButton.MouseButton1Click:Connect(function()
    commitSellInput(AutoSellEnabled)
end)

SellToggle.MouseButton1Click:Connect(function()
    if AutoSellEnabled then
        if applySellThreshold(0) then
            AutoSellEnabled = false
            updateToggle(SellToggle, false)
            setStatus("AUTO SELL DISABLED", COLORS.Gray)
        end
        return
    end

    local value = parseSellValue(SellInput.Text)
    if value == nil or value <= 0 then
        setStatus("ENTER A VALID THRESHOLD FIRST", COLORS.Red)
        return
    end

    if applySellThreshold(value) then
        SellThreshold = value
        saveConfigSoon()
        SellInput.Text = formatSellValue(value)
        AutoSellEnabled = true
        updateToggle(SellToggle, true)
        setStatus("AUTO SELL ENABLED")
    end
end)

--// LOAD / OBSERVE CURRENT GAME SETTING
local function syncAutoSellFromGame()
    local success, currentValue = pcall(function()
        return DataController.AutoSell()
    end)

    -- If AUTO LOAD restored a profile, keep its saved threshold and toggle.
    -- Otherwise, initialize the UI from the game's current Auto Sell setting.
    if success and typeof(currentValue) == "number" and not StartupProfileLoaded then
        SellThreshold = currentValue
        AutoSellEnabled = currentValue > 0
        SellInput.Text = formatSellValue(currentValue)
        updateToggle(SellToggle, AutoSellEnabled)
    end
end

syncAutoSellFromGame()

if AutoSellEnabled and SellThreshold > 0 then
    task.defer(function()
        if applySellThreshold(SellThreshold) then
            SellInput.Text = formatSellValue(SellThreshold)
            updateToggle(SellToggle, true)
        else
            AutoSellEnabled = false
            updateToggle(SellToggle, false)
        end
    end)
else
    updateToggle(SellToggle, false)
end

pcall(function()
    DataController.AutoSell.Observe(function()
        if not Destroyed then
            syncAutoSellFromGame()
        end
    end)
end)

--// AUTO QUEST CLAIM SECTION
local QuestSection = createSection("AUTO QUEST CLAIM", 155)
local QuestDescription = createLabel(
    QuestSection,
    "Claim completed Daily and Weekly quest rewards",
    UDim2.fromOffset(13, 33),
    UDim2.new(1, -26, 0, 20)
)
QuestDescription.TextColor3 = COLORS.Gray
QuestDescription.TextSize = 10

local DailyQuestLabel = createLabel(
    QuestSection,
    "Daily quest rewards",
    UDim2.fromOffset(13, 66),
    UDim2.new(1, -100, 0, 24)
)
local DailyQuestToggle = createButton(
    QuestSection,
    "OFF",
    UDim2.new(1, -76, 0, 63),
    UDim2.fromOffset(62, 28)
)

local WeeklyQuestLabel = createLabel(
    QuestSection,
    "Weekly quest rewards",
    UDim2.fromOffset(13, 108),
    UDim2.new(1, -100, 0, 24)
)
local WeeklyQuestToggle = createButton(
    QuestSection,
    "OFF",
    UDim2.new(1, -76, 0, 105),
    UDim2.fromOffset(62, 28)
)

updateToggle(DailyQuestToggle, AutoClaimDaily)
updateToggle(WeeklyQuestToggle, AutoClaimWeekly)

DailyQuestToggle.MouseButton1Click:Connect(function()
    AutoClaimDaily = not AutoClaimDaily
    updateToggle(DailyQuestToggle, AutoClaimDaily)
    saveConfigSoon()
    setStatus(AutoClaimDaily and "DAILY AUTO CLAIM ENABLED" or "DAILY AUTO CLAIM DISABLED")
end)

WeeklyQuestToggle.MouseButton1Click:Connect(function()
    AutoClaimWeekly = not AutoClaimWeekly
    updateToggle(WeeklyQuestToggle, AutoClaimWeekly)
    saveConfigSoon()
    setStatus(AutoClaimWeekly and "WEEKLY AUTO CLAIM ENABLED" or "WEEKLY AUTO CLAIM DISABLED")
end)

-- Uses the exact claim signal and argument order shown in QuestController.
local ClaimAttempts = {}
local function checkAndClaimQuests(period)
    local periodConfig = QuestConfig.Periods[period]
    local dataAccessor = DataController.Quests[period]

    if not periodConfig or not dataAccessor then
        return
    end

    local success, questData = pcall(function()
        return dataAccessor()
    end)

    if not success or type(questData) ~= "table" then
        return
    end

    local expiresAt = questData.expiresAt
    if typeof(expiresAt) ~= "number" or expiresAt <= 0 then
        return
    end

    local progress = questData.progress or {}
    local claimed = questData.claimed or {}
    local serverNow = math.floor(workspace:GetServerTimeNow())

    -- Do not claim expired quests while the game is waiting for its refresh.
    if expiresAt <= serverNow then
        return
    end

    for _, quest in ipairs(periodConfig.quests) do
        local currentProgress = tonumber(progress[quest.id]) or 0
        local isClaimed = claimed[quest.id] == true
        local attemptKey = period .. ":" .. quest.id .. ":" .. tostring(expiresAt)
        local lastAttempt = ClaimAttempts[attemptKey] or 0

        if currentProgress >= quest.target and not isClaimed and os.clock() - lastAttempt >= 5 then
            ClaimAttempts[attemptKey] = os.clock()

            local fired, fireError = pcall(function()
                ClaimQuestReward:Fire(period, quest.id, expiresAt)
            end)

            if not fired then
                warn("[KYOSH] Quest claim request failed:", fireError)
            end
        end
    end
end

task.spawn(function()
    while not Destroyed do
        if AutoClaimDaily then
            checkAndClaimQuests("Daily")
        end

        if AutoClaimWeekly then
            checkAndClaimQuests("Weekly")
        end

        task.wait(2)
    end
end)

--// AUTO QUEST SHOP
-- The exact purchase signal and argument are taken from QuestController:
-- QuestService:GetSignal("Buy") and Buy:Fire(itemName).
local QuestShopSection = createSection("AUTO QUEST SHOP", 230)
local QuestShopDescription = createLabel(
    QuestShopSection,
    "Select the items you want to buy with quest tickets",
    UDim2.fromOffset(13, 31),
    UDim2.new(1, -26, 0, 18)
)
QuestShopDescription.TextColor3 = COLORS.Gray
QuestShopDescription.TextSize = 9

local QuestShopButtons = {}
local QuestShopBusy = false
local QuestShopLastPurchase = {}
local function getTicketAmount()
    local ok, ticketData = pcall(function()
        return DataController.Inventory.Tickets()
    end)
    if not ok or type(ticketData) ~= "table" then return 0 end
    return tonumber(ticketData.amount) or 0
end

for index, item in ipairs(QuestConfig.Shop or {}) do
    local column = (index - 1) % 2
    local row = math.floor((index - 1) / 2)
    local x = column == 0 and 12 or 192
    local y = 57 + row * 32
    local itemLabel = createLabel(
        QuestShopSection,
        item.name .. "  •  " .. tostring(item.tickets) .. " tickets",
        UDim2.fromOffset(x, y + 3),
        UDim2.new(0, 132, 0, 24)
    )
    itemLabel.TextSize = 9
    itemLabel.TextTruncate = Enum.TextTruncate.AtEnd

    local toggle = createButton(
        QuestShopSection,
        "OFF",
        UDim2.fromOffset(x + 134, y),
        UDim2.fromOffset(42, 27)
    )
    updateToggle(toggle, QuestShopSelection[item.name] == true)
    QuestShopButtons[item.name] = toggle

    toggle.MouseButton1Click:Connect(function()
        QuestShopSelection[item.name] = not QuestShopSelection[item.name]
        updateToggle(toggle, QuestShopSelection[item.name])
        saveConfigSoon()
        setStatus(QuestShopSelection[item.name] and ("AUTO BUY: " .. string.upper(item.name)) or ("AUTO BUY OFF: " .. string.upper(item.name)))
    end)
end

local function questShopItemAlreadyOwned(item)
    if not item.gamepass then return false end
    local ok, owned = pcall(function()
        local accessor = DataController.OwnedGamepasses[item.name]
        return accessor and accessor() == true
    end)
    return ok and owned == true
end

task.spawn(function()
    while not Destroyed do
        if not QuestShopBusy then
            local ticketBalance = getTicketAmount()
            for _, item in ipairs(QuestConfig.Shop or {}) do
                if Destroyed then break end
                if QuestShopSelection[item.name] == true
                    and ticketBalance >= (tonumber(item.tickets) or math.huge)
                    and not questShopItemAlreadyOwned(item)
                    and os.clock() - (QuestShopLastPurchase[item.name] or 0) >= 3 then

                    QuestShopBusy = true
                    QuestShopLastPurchase[item.name] = os.clock()
                    local ok, err = pcall(function()
                        BuyQuestShopItem:Fire(item.name)
                    end)
                    if not ok then
                        warn("[KYOSH] Quest shop purchase failed for " .. item.name .. ": " .. tostring(err))
                    else
                        setStatus("QUEST SHOP BUY: " .. string.upper(item.name))
                    end
                    -- Let the server update ticket balance before another purchase.
                    task.wait(3)
                    ticketBalance = getTicketAmount()
                    QuestShopBusy = false
                    break
                end
            end
        end
        task.wait(1)
    end
end)

--// NAMED CONFIGURATION PROFILES
local ConfigSection = createSection("CONFIGURATION PROFILES", 150)

local ProfileNameInput = Instance.new("TextBox")
ProfileNameInput.Name = "ProfileName"
ProfileNameInput.Size = UDim2.new(1, -26, 0, 30)
ProfileNameInput.Position = UDim2.fromOffset(13, 32)
ProfileNameInput.BackgroundColor3 = COLORS.PanelLight
ProfileNameInput.BorderSizePixel = 0
ProfileNameInput.Font = Enum.Font.GothamMedium
ProfileNameInput.TextSize = 11
ProfileNameInput.TextColor3 = COLORS.White
ProfileNameInput.PlaceholderText = "Enter profile name..."
ProfileNameInput.PlaceholderColor3 = COLORS.Gray
ProfileNameInput.ClearTextOnFocus = false
ProfileNameInput.Text = CurrentProfileName
ProfileNameInput.Parent = ConfigSection
addCorner(ProfileNameInput, 7)

local ProfileButtons = {}
ProfileButtons.Save = createButton(ConfigSection, "SAVE", UDim2.fromOffset(13, 70), UDim2.new(0.31, -6, 0, 29), COLORS.PurpleDark)
ProfileButtons.Load = createButton(ConfigSection, "LOAD", UDim2.new(0.345, 0, 0, 70), UDim2.new(0.31, -6, 0, 29), COLORS.PanelLight)
ProfileButtons.Auto = createButton(ConfigSection, "AUTO LOAD: OFF", UDim2.new(0.69, 0, 0, 70), UDim2.new(0.31, -6, 0, 29), COLORS.PanelLight)

local ConfigStatusLabel = createLabel(
    ConfigSection,
    FileSavingAvailable and "Profiles save as separate files" or "File APIs unavailable in this environment",
    UDim2.fromOffset(13, 108),
    UDim2.new(1, -26, 0, 25)
)
ConfigStatusLabel.TextColor3 = FileSavingAvailable and COLORS.Green or COLORS.Gray
ConfigStatusLabel.TextSize = 9
ConfigStatusLabel.TextWrapped = true

local function refreshProfileAutoLoadButton()
    local activeName = loadAutoProfileName()
    local enabled = activeName ~= nil and activeName == sanitizeProfileName(ProfileNameInput.Text)
    ProfileButtons.Auto.Text = enabled and "AUTO LOAD: ON" or "AUTO LOAD: OFF"
    ProfileButtons.Auto.BackgroundColor3 = enabled and COLORS.PurpleDark or COLORS.PanelLight
end

local function syncLoadedProfileToUI()
    updateToggle(RollToggle, AutoRoll)
    updateToggle(SkipButton, SkipAnimation)
    updateToggle(AutoTowerButton, AutoTower)
    updateToggle(SellToggle, AutoSellEnabled)
    updateToggle(DailyQuestToggle, AutoClaimDaily)
    updateToggle(WeeklyQuestToggle, AutoClaimWeekly)
    updateToggle(AutoHideToggle, AutoHideTowerUI)
    for itemName, button in pairs(QuestShopButtons) do
        updateToggle(button, QuestShopSelection[itemName] == true)
    end
    updateAutoHideTowerUI()
    selectTower(SelectedTower)
    SellInput.Text = formatSellValue(SellThreshold)
    if AutoSellEnabled then applySellThreshold(SellThreshold) end
    if AutoTower then
        task.delay(0.2, function()
            if AutoTower and not Destroyed then task.spawn(startSelectedTower) end
        end)
    else
        pcall(function() SetAutoTower:Fire(false) end)
    end
end

ProfileButtons.Save.MouseButton1Click:Connect(function()
    local name = sanitizeProfileName(ProfileNameInput.Text)
    if name == "" then
        ConfigStatusLabel.Text = "ENTER A PROFILE NAME FIRST"
        ConfigStatusLabel.TextColor3 = COLORS.Red
        return
    end
    if saveConfig(name) then
        ProfileNameInput.Text = name
        -- Saving a profile also marks it as the startup profile so its
        -- Auto Roll / Auto Tower Retry states are restored on next execution.
        local autoLoadSaved = setAutoLoad(name, true)
        ConfigStatusLabel.Text = autoLoadSaved
            and ("SAVED + AUTO LOAD: " .. name)
            or ("SAVED PROFILE: " .. name .. " (AUTO LOAD FAILED)")
        ConfigStatusLabel.TextColor3 = autoLoadSaved and COLORS.Green or COLORS.Red
        refreshProfileAutoLoadButton()
        setStatus(autoLoadSaved and "PROFILE SAVED / AUTO LOAD ENABLED" or "PROFILE SAVED")
    else
        ConfigStatusLabel.Text = "SAVE FAILED / FILE API UNAVAILABLE"
        ConfigStatusLabel.TextColor3 = COLORS.Red
    end
end)

ProfileButtons.Load.MouseButton1Click:Connect(function()
    local name = sanitizeProfileName(ProfileNameInput.Text)
    if name ~= "" and loadConfig(name) then
        ProfileNameInput.Text = name
        syncLoadedProfileToUI()
        ConfigStatusLabel.Text = "LOADED PROFILE: " .. name
        ConfigStatusLabel.TextColor3 = COLORS.Green
        refreshProfileAutoLoadButton()
        setStatus("PROFILE LOADED")
    else
        ConfigStatusLabel.Text = "PROFILE NOT FOUND"
        ConfigStatusLabel.TextColor3 = COLORS.Red
    end
end)

ProfileButtons.Auto.MouseButton1Click:Connect(function()
    local name = sanitizeProfileName(ProfileNameInput.Text)
    if name == "" then
        ConfigStatusLabel.Text = "ENTER A PROFILE NAME FIRST"
        ConfigStatusLabel.TextColor3 = COLORS.Red
        return
    end
    local currentlyEnabled = loadAutoProfileName() == name
    if setAutoLoad(name, not currentlyEnabled) then
        ConfigStatusLabel.Text = not currentlyEnabled and ("AUTO LOAD SET: " .. name) or "AUTO LOAD DISABLED"
        ConfigStatusLabel.TextColor3 = COLORS.Green
        refreshProfileAutoLoadButton()
    else
        ConfigStatusLabel.Text = "AUTO LOAD SETUP FAILED"
        ConfigStatusLabel.TextColor3 = COLORS.Red
    end
end)

ProfileNameInput:GetPropertyChangedSignal("Text"):Connect(refreshProfileAutoLoadButton)
refreshProfileAutoLoadButton()

-- Periodic safety save updates the currently selected profile, including
-- Auto Roll and Auto Tower Retry state.
task.spawn(function()
    while not Destroyed do
        task.wait(10)
        if FileSavingAvailable then saveConfig(CurrentProfileName) end
    end
end)

--// FOOTER
local Footer = Instance.new("TextLabel")
Footer.BackgroundTransparency = 1
Footer.Size = UDim2.new(1, -20, 0, 18)
Footer.Font = Enum.Font.GothamMedium
Footer.Text = "KYOSH  •  ANIME DICE"
Footer.TextColor3 = COLORS.Gray
Footer.TextSize = 9
Footer.Parent = Content

--// RESPONSIVE LAYOUT
local Camera = workspace.CurrentCamera
local function updateLayout()
    if not Camera or not Main.Parent then return end

    local viewport = Camera.ViewportSize
    local landscape = viewport.X > viewport.Y and viewport.X >= 600
    local margin = 12

    if landscape then
        local width = math.min(CONFIG.LandscapeWidth, viewport.X - margin * 2)
        local height = math.min(CONFIG.LandscapeHeight, viewport.Y - margin * 2)
        Main.Size = UDim2.fromOffset(width, height)

        local columnWidth = math.floor((width - 30) / 2)
        local rightX = columnWidth + 10

        RollSection.Size = UDim2.fromOffset(columnWidth, 155)
        RollSection.Position = UDim2.fromOffset(0, 0)
        TowerSection.Size = UDim2.fromOffset(columnWidth, 280)
        TowerSection.Position = UDim2.fromOffset(0, 165)

        SellSection.Size = UDim2.fromOffset(columnWidth, 205)
        SellSection.Position = UDim2.fromOffset(rightX, 0)
        QuestSection.Size = UDim2.fromOffset(columnWidth, 155)
        QuestSection.Position = UDim2.fromOffset(rightX, 215)
        QuestShopSection.Size = UDim2.fromOffset(columnWidth, 230)
        QuestShopSection.Position = UDim2.fromOffset(rightX, 380)
        ConfigSection.Size = UDim2.fromOffset(columnWidth, 150)
        ConfigSection.Position = UDim2.fromOffset(rightX, 620)
        StatusSection.Size = UDim2.fromOffset(columnWidth, 66)
        StatusSection.Position = UDim2.fromOffset(0, 455)

        Footer.Position = UDim2.fromOffset(rightX, 780)
        Content.CanvasSize = UDim2.fromOffset(0, 810)
    else
        local width = math.min(CONFIG.PortraitWidth, viewport.X - margin * 2)
        local height = math.min(CONFIG.PortraitHeight, viewport.Y - margin * 2)
        Main.Size = UDim2.fromOffset(width, height)

        local columnWidth = width - 20
        RollSection.Size = UDim2.fromOffset(columnWidth, 155)
        RollSection.Position = UDim2.fromOffset(0, 0)
        TowerSection.Size = UDim2.fromOffset(columnWidth, 280)
        TowerSection.Position = UDim2.fromOffset(0, 165)
        SellSection.Size = UDim2.fromOffset(columnWidth, 205)
        SellSection.Position = UDim2.fromOffset(0, 455)
        QuestSection.Size = UDim2.fromOffset(columnWidth, 155)
        QuestSection.Position = UDim2.fromOffset(0, 670)
        QuestShopSection.Size = UDim2.fromOffset(columnWidth, 230)
        QuestShopSection.Position = UDim2.fromOffset(0, 835)
        ConfigSection.Size = UDim2.fromOffset(columnWidth, 150)
        ConfigSection.Position = UDim2.fromOffset(0, 1075)
        StatusSection.Size = UDim2.fromOffset(columnWidth, 66)
        StatusSection.Position = UDim2.fromOffset(0, 1240)

        Footer.Position = UDim2.fromOffset(0, 1310)
        Content.CanvasSize = UDim2.fromOffset(0, 1340)
    end

    Content.Size = UDim2.new(1, -20, 1, -76)
    Content.Position = UDim2.fromOffset(10, 66)
end

updateLayout()
if Camera then
    Camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateLayout)
end

-- Reflect loaded settings in the controls.
updateToggle(RollToggle, AutoRoll)
updateToggle(SkipButton, SkipAnimation)
updateToggle(AutoTowerButton, false)
updateToggle(AutoHideToggle, AutoHideTowerUI)
updateAutoHideTowerUI()

-- Restore profile-controlled toggles, including Auto Tower Retry.
-- Auto Roll's loop and the tower retry loop will resume from these states.
if StartupProfileLoaded then
    updateToggle(RollToggle, AutoRoll)
    updateToggle(AutoTowerButton, AutoTower)
    updateToggle(AutoHideToggle, AutoHideTowerUI)

    -- Persist the normalized/compatible profile and report restored states.
    saveConfig(CurrentProfileName)
    if AutoRoll or AutoTower then
        setStatus(
            "AUTO-LOADED: ROLL " .. (AutoRoll and "ON" or "OFF")
            .. " / TOWER RETRY " .. (AutoTower and "ON" or "OFF"),
            COLORS.Green
        )
    end

    if AutoTower then
        task.delay(0.5, function()
            if AutoTower and not Destroyed then
                task.spawn(startSelectedTower)
            end
        end)
    end
end

--// CLOSE / CLEANUP
CloseButton.MouseButton1Click:Connect(function()
    if Destroyed then return end

    saveConfig()
    Destroyed = true
    AutoRoll = false
    AutoTower = false

    pcall(function()
        SetAutoTower:Fire(false)
    end)

    ScreenGui:Destroy()
end)

print("[KYOSH] Updated Anime Dice control panel loaded.")
