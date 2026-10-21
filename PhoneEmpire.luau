--[[
    ============================================================
      BUILD A PHONE EMPIRE  ·  AUTO HUB  (WindUI)
    ============================================================

    What it does
      · Auto Research  - walks the whole 313-item tech tree for you,
                         cheapest-first by default, and never stops.
      · Auto Money     - designs the next phone from your best parts,
                         develops it, launches it with marketing and
                         reprices devices towards their market value.
      · Extra income   - buys out rivals and claims candy quests.
      · Auto return    - optionally closes the in-game panel back to
                         the main HUD after every action.
      · AFK pack       - anti-AFK, speed keeper, daily reward,
                         staff training, hiring, morale, office.
      · Live stats     - RP, money, year, research progress.

    Toggle the window with RIGHT SHIFT (or the button in the corner).

    Every action is a normal game remote call, so it behaves exactly
    like clicking the buttons yourself.
]]

if getgenv().PT_HUB_DESTROY then
    pcall(getgenv().PT_HUB_DESTROY)
    getgenv().PT_HUB_DESTROY = nil
end

local RL = (type(STATE) == "table" and STATE) or nil

--=============================================================
-- Services
--=============================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local PhoneTycoon = ReplicatedStorage:WaitForChild("PhoneTycoon")
local Remotes = PhoneTycoon:WaitForChild("Remotes")
local Config = require(PhoneTycoon:WaitForChild("Config"))
local Economy = require(PhoneTycoon:WaitForChild("Economy"))

--=============================================================
-- Settings (persisted to disk when the executor supports it)
--=============================================================

local SETTINGS_FILE = "PhoneEmpireHub/settings.json"

local DEFAULTS = {
    -- research
    autoResearch = true,
    priority = "Cheapest first",
    reserveRp = 0,
    returnToMain = true,
    notifyOnStart = true,

    -- afk
    antiAfk = true,
    autoSpeed = true,
    speed = 4,
    autoDaily = true,
    autoTrain = true,
    trainMax = 5,
    autoHire = true,
    autoParty = true,
    autoOffice = false,
    autoExpand = false,
    autoBoosts = false,

    -- money
    autoDev = true,
    autoLaunch = true,
    launchCampaign = "Best affordable",
    devPriceMult = 1,
    devMinCash = 20000000,
    autoRivals = true,
    rivalReserve = 4,
    autoCandy = true,
    autoPrice = false,
    priceMult = 1,
    autoRescue = true,

    -- engine
    tick = 1,
}

local cfg = {}
for k, v in pairs(DEFAULTS) do
    cfg[k] = v
end

local function loadSettings()
    if not (isfile and readfile and isfile(SETTINGS_FILE)) then
        return
    end
    local ok, raw = pcall(readfile, SETTINGS_FILE)
    if not ok or type(raw) ~= "string" then
        return
    end
    local ok2, data = pcall(function()
        return game:GetService("HttpService"):JSONDecode(raw)
    end)
    if ok2 and type(data) == "table" then
        for k, v in pairs(DEFAULTS) do
            if data[k] ~= nil then
                cfg[k] = data[k]
            end
        end
    end
end

local function saveSettings()
    if not (writefile and makefolder) then
        return false
    end
    pcall(makefolder, "PhoneEmpireHub")
    local ok, encoded = pcall(function()
        return game:GetService("HttpService"):JSONEncode(cfg)
    end)
    if not ok then
        return false
    end
    return (pcall(writefile, SETTINGS_FILE, encoded))
end

loadSettings()

--=============================================================
-- State + remote helpers
--=============================================================

local Hub = {
    state = nil,
    started = false,
    status = "Starting…",
    log = {},
    lastAction = "—",
    startedCount = 0,
    errors = 0,
    cfg = cfg,
}

local function pushLog(line)
    table.insert(Hub.log, 1, string.format("[%s] %s", os.date("%H:%M:%S"), line))
    while #Hub.log > 40 do
        table.remove(Hub.log)
    end
    Hub.lastAction = line
end

--- Calls a game action remote. Never throws.
local function call(action, ...)
    local args = table.pack(...)
    local ok, res = pcall(function()
        return Remotes.Action:InvokeServer(action, table.unpack(args, 1, args.n))
    end)
    if not ok then
        Hub.errors = Hub.errors + 1
        return { ok = false, msg = tostring(res) }
    end
    if type(res) == "table" and res.data and action == "getState" then
        Hub.state = res.data
    end
    return res
end

local function refreshState()
    local res = call("getState")
    if type(res) == "table" and type(res.data) == "table" then
        Hub.state = res.data
        return true
    end
    return false
end

-- The server pushes a fresh state table on every tick; keep the newest one.
if RL then
    RL.connect(Remotes.State.OnClientEvent, function(state)
        Hub.state = state
    end)
else
    Remotes.State.OnClientEvent:Connect(function(state)
        Hub.state = state
    end)
end

refreshState()

local function st()
    return Hub.state
end

local function yearNow()
    local s = st()
    if not s then
        return Config.START_YEAR
    end
    local ok, y = pcall(Economy.year, s.day)
    return ok and y or Config.START_YEAR
end

--=============================================================
-- Research engine
--=============================================================

local function activeResearch()
    local s = st()
    if not s then
        return {}
    end
    local ok, list = pcall(Economy.researchList, s)
    if ok and type(list) == "table" then
        return list
    end
    return {}
end

local function researchSlots()
    local s = st()
    if not s then
        return 1
    end
    local ok, n = pcall(Economy.researchSlots, s)
    return (ok and tonumber(n)) or 1
end

local function researchedCount()
    local s = st()
    if not s then
        return 0
    end
    local n = 0
    for id in pairs(s.researched or {}) do
        if Config.ResearchById and Config.ResearchById[id] then
            n = n + 1
        end
    end
    return n
end

local function totalResearch()
    return #Config.Research
end

--- Every item that could be started right now.
local function candidates()
    local s = st()
    if not s then
        return {}
    end

    local busy = {}
    for _, entry in ipairs(activeResearch()) do
        busy[entry.id] = true
    end

    local year = yearNow()
    local out = {}

    for index, item in ipairs(Config.Research) do
        if not s.researched[item.id] and not busy[item.id] then
            local unlocked = true
            for _, req in ipairs(item.requires or {}) do
                if not s.researched[req] then
                    unlocked = false
                    break
                end
            end
            if unlocked and year >= (item.year or 0) then
                out[#out + 1] = { item = item, order = index }
            end
        end
    end

    return out
end

local PRIORITIES = {
    "Cheapest first",
    "Most expensive",
    "Highest tier",
    "Tree order",
}

local function sortCandidates(list)
    local mode = cfg.priority
    table.sort(list, function(a, b)
        local x, y = a.item, b.item
        if mode == "Most expensive" then
            if (x.cost or 0) ~= (y.cost or 0) then
                return (x.cost or 0) > (y.cost or 0)
            end
        elseif mode == "Highest tier" then
            if (x.tier or 0) ~= (y.tier or 0) then
                return (x.tier or 0) > (y.tier or 0)
            end
            return (x.cost or 0) < (y.cost or 0)
        elseif mode == "Tree order" then
            return a.order < b.order
        else
            if (x.cost or 0) ~= (y.cost or 0) then
                return (x.cost or 0) < (y.cost or 0)
            end
        end
        return a.order < b.order
    end)
end

--- Closes the in-game side panel so you are back on the main HUD.
local function returnToMainScreen()
    local ok = pcall(function()
        local gui = PlayerGui:FindFirstChild("PhoneTycoonGui")
        local root = gui and gui:FindFirstChild("Root")
        local hud = root and root:FindFirstChild("Hud")
        local window = hud and hud:FindFirstChild("GameWindow")
        if not window or not window.Visible then
            return
        end
        local button = window:FindFirstChild("CloseButton")
        if not (button and getconnections) then
            window.Visible = false
            return
        end
        for _, connection in ipairs(getconnections(button.Activated)) do
            if type(connection.Function) == "function" then
                pcall(connection.Function)
            end
        end
        if window.Visible then
            window.Visible = false
        end
    end)
    return ok
end

local function panelOpen()
    local gui = PlayerGui:FindFirstChild("PhoneTycoonGui")
    local root = gui and gui:FindFirstChild("Root")
    local hud = root and root:FindFirstChild("Hud")
    local window = hud and hud:FindFirstChild("GameWindow")
    return window ~= nil and window.Visible == true
end

--- One research attempt. Returns the started item name, or nil.
local function tryStartResearch(force)
    local s = st()
    if not s then
        return nil
    end

    local active = activeResearch()
    local slots = researchSlots()
    if #active >= slots and not force then
        return nil
    end

    local list = candidates()
    if #list == 0 then
        Hub.status = "Lab idle · nothing available yet"
        return nil
    end

    sortCandidates(list)

    local budget = (s.rp or 0) - (cfg.reserveRp or 0)
    local cheapest = list[1].item.cost or 0
    if budget < cheapest and not force then
        Hub.status = string.format(
            "Saving RP · need %d more for %s",
            math.ceil(cheapest - budget),
            list[1].item.name
        )
        return nil
    end

    for _, entry in ipairs(list) do
        local item = entry.item
        if force or (item.cost or 0) <= budget then
            local res = call("research", item.id)
            if type(res) == "table" and res.ok then
                Hub.startedCount = Hub.startedCount + 1
                Hub.status = string.format("Researching %s · %d RP", item.name, item.cost)
                pushLog("Started " .. item.name .. " (" .. tostring(item.cost) .. " RP)")
                if cfg.notifyOnStart and Hub.notify then
                    Hub.notify(item.name, "Research started · " .. tostring(item.cost) .. " RP")
                end
                refreshState()
                if cfg.returnToMain then
                    task.defer(returnToMainScreen)
                end
                return item.name
            end
        end
    end

    return nil
end

--=============================================================
-- AFK features
--=============================================================

local timers = {}
local function ready(key, interval)
    local now = os.clock()
    if (timers[key] or 0) + interval <= now then
        timers[key] = now
        return true
    end
    return false
end

-- Anti-AFK: a harmless virtual click keeps Roblox from idling the client out.
if RL then
    RL.connect(LocalPlayer.Idled, function()
        if not cfg.antiAfk then
            return
        end
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new(0, 0))
        end)
        pushLog("Anti-AFK pulse")
    end)
else
    LocalPlayer.Idled:Connect(function()
        if not cfg.antiAfk then
            return
        end
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new(0, 0))
        end)
        pushLog("Anti-AFK pulse")
    end)
end

local function dayNumberNow()
    local ok, n = pcall(Economy.dayNumber, workspace:GetServerTimeNow())
    return ok and n or 0
end

local function dailyReady()
    local s = st()
    if not s then
        return false
    end
    local last = (s.daily and s.daily.last) or 0
    return dayNumberNow() > last
end

local function bestCandidate()
    local s = st()
    if not s or not s.candidates then
        return nil
    end
    local best
    for _, c in ipairs(s.candidates) do
        if not best
            or (c.skill or 0) > (best.skill or 0)
            or ((c.skill or 0) == (best.skill or 0) and (c.wage or 0) < (best.wage or 0))
        then
            best = c
        end
    end
    return best
end

local function avgMorale()
    local s = st()
    if not s or #s.employees == 0 then
        return 100
    end
    local total = 0
    for _, e in ipairs(s.employees) do
        total = total + (e.morale or 100)
    end
    return total / #s.employees
end

local function runAfkTasks()
    local s = st()
    if not s then
        return
    end

    -- keep the clock running at the chosen multiplier
    if cfg.autoSpeed and ready("speed", 10) then
        if not panelOpen() and (s.speed or 0) ~= cfg.speed then
            call("setSpeed", cfg.speed)
        end
    end

    -- daily reward
    if cfg.autoDaily and ready("daily", 45) and dailyReady() then
        local res = call("claimDaily")
        if type(res) == "table" and res.ok then
            pushLog("Claimed the daily reward")
        end
    end

    -- train staff, one per cycle, cheapest first
    if cfg.autoTrain and ready("train", 8) then
        local target
        for _, e in ipairs(s.employees or {}) do
            if (e.skill or 5) < cfg.trainMax and (not target or (e.skill or 0) < (target.skill or 0)) then
                target = e
            end
        end
        if target then
            local cost = 0
            local ok, value = pcall(Economy.trainCost, target.skill, s)
            if ok and type(value) == "number" then
                cost = value
            end
            if (s.money or 0) > cost * 2 then
                local res = call("train", target.id)
                if type(res) == "table" and res.ok then
                    pushLog("Trained " .. tostring(target.name or "employee"))
                end
            end
        end
    end

    -- hire the strongest candidate
    if cfg.autoHire and ready("hire", 20) then
        local pick = bestCandidate()
        if pick and (s.money or 0) > (pick.wage or 0) * 3 then
            call("hire", pick.id)
        end
    end

    -- keep morale up with a party
    if cfg.autoParty and ready("party", 90) then
        if avgMorale() < 70 and (s.money or 0) > 50000 then
            local res = call("party")
            if type(res) == "table" and res.ok then
                pushLog("Threw an office party")
            end
        end
    end

    -- office upgrade
    if cfg.autoOffice and ready("office", 120) then
        call("upgradeOffice")
    end

    -- buy a region when affordable
    if cfg.autoExpand and ready("expand", 180) then
        local owned = s.regions or {}
        local cheapest, cheapestCost
        for _, region in ipairs(Config.Regions or {}) do
            if region.id and not owned[region.id] then
                local ok, cost = pcall(Economy.regionCost, s, region)
                if not ok then
                    cost = region.cost or 0
                end
                if type(cost) == "number" and (not cheapestCost or cost < cheapestCost) then
                    cheapest, cheapestCost = region, cost
                end
            end
        end
        if cheapest and (s.money or 0) > cheapestCost * 3 then
            call("expand", cheapest.id)
        end
    end

    -- optional: spend spare RP on research boosts
    if cfg.autoBoosts and ready("boost", 300) then
        local active = activeResearch()
        if #active > 0 then
            local spare = (s.rp or 0) - (cfg.reserveRp or 0) - 500
            if spare > 0 then
                call("rpBoost", "quality")
                call("rpBoost", "bugs")
            end
        end
    end
end

--=============================================================
-- Money engine (design -> develop -> launch -> reprice)
--=============================================================

local CAMPAIGNS = {
    "None",
    "Online ads",
    "TV campaign",
    "Global launch event",
    "Best affordable",
}

local CAMPAIGN_IDS = {
    ["None"] = "none",
    ["Online ads"] = "online",
    ["TV campaign"] = "tv",
    ["Global launch event"] = "event",
}

local function notify(title, content)
    if Hub.notify then
        Hub.notify(title, content)
    end
end

local function shortMoney(value)    local ok, text = pcall(Economy.money, value)
    if ok and type(text) == "string" then
        return text
    end
    local n = tonumber(value) or 0
    if n >= 1e9 then
        return string.format("%.1fB", n / 1e9)
    elseif n >= 1e6 then
        return string.format("%.1fM", n / 1e6)
    elseif n >= 1e3 then
        return string.format("%.1fK", n / 1e3)
    end
    return tostring(math.floor(n))
end

local function deepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for k, v in pairs(value) do
        copy[deepCopy(k)] = deepCopy(v)
    end
    return copy
end

--- Newest device that has a design we can clone.
local function latestDevice()
    local s = st()
    if not s or type(s.phones) ~= "table" then
        return nil
    end
    local best
    for _, phone in ipairs(s.phones) do
        if type(phone) == "table" and type(phone.design) == "table" then
            if not best or (phone.id or 0) > (best.id or 0) then
                best = phone
            end
        end
    end
    return best
end

local function marketingInfo()
    local year = yearNow()
    local out = {}
    for _, campaign in ipairs(Config.Marketing or {}) do
        local ok, cost = pcall(Economy.marketingCost, campaign, year)
        out[#out + 1] = {
            id = campaign.id,
            name = campaign.name or campaign.id,
            hype = campaign.hype or 1,
            cost = (ok and type(cost) == "number") and cost or (campaign.cost or 0),
        }
    end
    return out
end

local function pickCampaign(money)
    money = tonumber(money) or 0
    local wanted = cfg.launchCampaign or "Best affordable"

    if wanted ~= "Best affordable" then
        local id = CAMPAIGN_IDS[wanted]
        if id then
            for _, campaign in ipairs(marketingInfo()) do
                if campaign.id == id then
                    return campaign
                end
            end
        end
    end

    local best
    for _, campaign in ipairs(marketingInfo()) do
        -- keep enough cash behind for the production run
        if campaign.id == "none" or campaign.cost * 3 <= money then
            if not best or campaign.hype > best.hype then
                best = campaign
            end
        end
    end
    return best or { id = "none", name = "None", hype = 1, cost = 0 }
end

--- True once the design team has finished the current project.
local function devReady(dev)
    if type(dev) ~= "table" then
        return false
    end
    if dev.phase == "ready" or dev.ready == true then
        return true
    end
    if type(dev.progress) == "number" and dev.progress >= 1 then
        return true
    end
    if type(dev.day) == "number" and type(dev.daysTotal) == "number" and dev.daysTotal > 0 then
        return dev.day >= dev.daysTotal
    end
    return false
end

--- Clones the newest device and swaps in the best researched chassis.
local function buildDesign()
    local s = st()
    if not s then
        return nil
    end

    local previous = latestDevice()
    local design
    if previous then
        design = deepCopy(previous.design)
    else
        local ok, created = pcall(Economy.defaultDesign, "phone", yearNow())
        if not ok or type(created) ~= "table" then
            return nil
        end
        design = created
    end

    pcall(Economy.migrateDesign, design)

    local okChassis, chassis = pcall(Economy.bestChassis, s.researched or {}, yearNow())
    if okChassis and type(chassis) == "table" and chassis.id then
        design.chassis = chassis.id
    end

    local count = #(s.phones or {}) + 1
    local okName, name = pcall(Economy.nextVersionName, previous and previous.name or nil)
    if okName and type(name) == "string" and name ~= "" then
        design.name = name
    elseif type(design.name) ~= "string" or design.name == "" then
        design.name = "gen-" .. count
    end

    return design
end

local function plannedPrice(previous, design)
    local base
    if previous and type(previous.price) == "number" and previous.price > 0 then
        base = previous.price
    else
        local ok, value = pcall(Economy.valuePrice, 8, yearNow(), design.device or "phone")
        base = (ok and type(value) == "number" and value) or 500
    end
    local multiplier = tonumber(cfg.devPriceMult) or 1
    return math.max(1, math.floor(base * multiplier + 0.5))
end

local function startProject(force)
    local s = st()
    if not s then
        return false, "Waiting for the game state…"
    end
    if s.dev then
        if devReady(s.dev) then
            return false, "The current project is finished - launch it first."
        end
        return false, "A project is already in development."
    end

    local design = buildDesign()
    if not design then
        return false, "Could not build a design."
    end

    local previous = latestDevice()
    local price = plannedPrice(previous, design)
    local reserve = tonumber(cfg.devMinCash) or 20000000
    if not force and (s.money or 0) < reserve then
        return false, "Saving cash · need " .. shortMoney(reserve)
    end

    local res = call("startDev", design, price)
    if type(res) == "table" and res.ok then
        Hub.devStarted = (Hub.devStarted or 0) + 1
        pushLog(string.format("Started %s · price %s", tostring(design.name), shortMoney(price)))
        notify("New project", string.format("%s · selling at %s", tostring(design.name), shortMoney(price)))
        refreshState()
        return true, design.name
    end
    return false, (type(res) == "table" and res.msg) or "rejected"
end

local function launchProject(force)
    local s = st()
    if not s then
        return false, "Waiting for the game state…"
    end
    if not s.dev then
        return false, "No project in development."
    end
    if not force and not devReady(s.dev) then
        return false, "Still in development."
    end

    local campaign = pickCampaign(s.money or 0)
    if not force and campaign.cost > 0 and (s.money or 0) < campaign.cost * 2 then
        return false, "Waiting for cash for " .. campaign.name
    end

    local devDesign = type(s.dev.design) == "table" and s.dev.design or nil
    local res = call("launch", campaign.id)
    if type(res) == "table" and res.ok then
        Hub.launched = (Hub.launched or 0) + 1
        local name = (devDesign and devDesign.name) or "new device"
        pushLog(string.format("Launched %s · %s", tostring(name), campaign.name))
        notify("Launched", string.format("%s · %s", tostring(name), campaign.name))
        refreshState()
        return true, name
    end
    return false, (type(res) == "table" and res.msg) or "rejected"
end

--- Moves active devices towards the price the game says they are worth.
local priceTimers = {}
local function targetPrice(phone)
    local ok, value = pcall(Economy.valuePrice, phone.critic or 8, yearNow(), phone.device or "phone")
    if not ok or type(value) ~= "number" or value <= 0 then
        return nil
    end
    local multiplier = tonumber(cfg.priceMult) or 1
    local floorPrice = math.max(1, math.floor((phone.unitCost or 1) * 1.5))
    local ceiling = math.max(floorPrice, math.floor(value * 2.5))
    local target = math.floor(value * multiplier + 0.5)
    return math.max(floorPrice, math.min(ceiling, target))
end

local function adaptPrices()
    local s = st()
    if not s then
        return 0
    end

    local changes = 0
    for _, phone in ipairs(s.phones or {}) do
        if type(phone) == "table" and phone.active and type(phone.id) == "number" then
            local last = priceTimers[phone.id] or 0
            if os.clock() - last > 90 then
                local target = targetPrice(phone)
                local current = tonumber(phone.price) or 0
                if target and current > 0 and math.abs(target - current) / current > 0.08 then
                    local res = call("setPrice", phone.id, target)
                    if type(res) == "table" and res.ok then
                        priceTimers[phone.id] = os.clock()
                        changes = changes + 1
                        pushLog(string.format(
                            "Repriced %s · %s -> %s",
                            tostring(phone.name or phone.id),
                            shortMoney(current),
                            shortMoney(target)
                        ))
                    end
                end
            end
        end
    end
    return changes
end

--- Buys the cheapest rival we can comfortably afford.
local function buyoutRival()
    local s = st()
    if not s or type(s.rivals) ~= "table" then
        return false, "Rival list unavailable."
    end

    local year = yearNow()
    local reserve = tonumber(cfg.rivalReserve) or 4
    local bestIndex, bestCost, bestName

    for index, rivalCfg in ipairs(Config.Rivals or {}) do
        local info = s.rivals[index]
        local unavailable = type(info) == "table" and (info.bought or info.gone)
        if not unavailable then
            local ok, cost = pcall(Economy.buyoutCost, rivalCfg, year)
            if ok and type(cost) == "number" and cost > 0 and (s.money or 0) >= cost * reserve then
                if not bestCost or cost < bestCost then
                    bestIndex = index
                    bestCost = cost
                    bestName = rivalCfg.name
                end
            end
        end
    end

    if not bestIndex then
        return false, "No rival is affordable right now."
    end

    local res = call("buyRival", bestIndex)
    if type(res) == "table" and res.ok then
        pushLog(string.format("Bought out %s · %s", tostring(bestName or bestIndex), shortMoney(bestCost)))
        notify("Rival bought", string.format("%s · %s", tostring(bestName or bestIndex), shortMoney(bestCost)))
        refreshState()
        return true, bestName
    end
    return false, (type(res) == "table" and res.msg) or "rejected"
end

local function candyGoals()
    local map = {}
    for _, quest in ipairs(Config.CANDY_QUESTS or {}) do
        if type(quest) == "table" and quest.id and type(quest.goal) == "number" then
            map[quest.id] = quest.goal
        end
    end
    return map
end

local function claimCandy()
    local s = st()
    local quests = s and s.candyQuests and s.candyQuests.list
    if type(quests) ~= "table" then
        return 0
    end

    local goals = candyGoals()
    local claimed = 0
    for _, quest in ipairs(quests) do
        if type(quest) == "table" and quest.id and not quest.claimed then
            local goal = goals[quest.id]
            if goal and (tonumber(quest.n) or 0) >= goal then
                local res = call("candyQuestClaim", quest.id)
                if type(res) == "table" and res.ok then
                    claimed = claimed + 1
                    Hub.candies = (Hub.candies or 0) + (quest.reward or 0)
                    pushLog("Claimed candy quest " .. tostring(quest.id))
                end
            end
        end
    end
    if claimed > 0 then
        refreshState()
    end
    return claimed
end

local function runMoneyTasks()
    local s = st()
    if not s then
        return
    end
    -- launch before starting so the design team frees up immediately
    if cfg.autoLaunch and ready("moneyLaunch", 4) then
        launchProject(false)
    end
    if cfg.autoDev and ready("moneyDev", 4) then
        startProject(false)
    end
    if cfg.autoPrice and ready("moneyPrice", 20) then
        adaptPrices()
    end
    if cfg.autoRivals and ready("moneyRivals", 90) then
        buyoutRival()
    end
    if cfg.autoCandy and ready("moneyCandy", 30) then
        claimCandy()
    end

    -- bankruptcy safety net
    if cfg.autoRescue and (s.money or 0) < 0 and ready("moneyRescue", 120) then
        local res = call("claimInsuranceRescue")
        if type(res) == "table" and res.ok then
            pushLog("Used the bankruptcy insurance rescue")
            notify("Saved", "Bankruptcy insurance rescue used.")
            refreshState()
        end
    end

    Hub.devPhase = s.dev and (devReady(s.dev) and "ready" or "dev") or nil
end

--=============================================================
-- Engine loop
--=============================================================

local function statusText()
    local s = st()
    if not s then
        return "Waiting for the game state…"
    end
    local done = researchedCount()
    local total = totalResearch()
    local active = activeResearch()
    local lab
    if #active == 0 then
        lab = "idle"
    else
        local parts = {}
        for _, entry in ipairs(active) do
            local item = Config.ResearchById[entry.id]
            parts[#parts + 1] = string.format(
                "%s (%s d)",
                item and item.name or entry.id,
                tostring(entry.daysLeft)
            )
        end
        lab = table.concat(parts, ", ")
    end
    return string.format(
        "RP %s  ·  tech %d/%d  ·  %s  ·  lab: %s",
        tostring(math.floor(s.rp or 0)),
        done,
        total,
        yearNow(),
        lab
    )
end

task.spawn(function()
    while (not RL or RL.alive()) and not Hub.stopped do
        local ok, err = pcall(function()
            if not Hub.state then
                refreshState()
            end
            if cfg.autoResearch then
                tryStartResearch(false)
            end
            runAfkTasks()
            runMoneyTasks()
        end)
        if not ok then
            Hub.errors = Hub.errors + 1
            Hub.status = "Error: " .. tostring(err)
            pushLog("Loop error: " .. tostring(err))
        end
        task.wait(math.max(0.35, tonumber(cfg.tick) or 1))
    end
end)

--=============================================================
-- User interface
--=============================================================

local WindUI
do
    local ok, result = pcall(function()
        local source = game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua")
        return loadstring(source)()
    end)
    if not ok then
        warn("[Auto Hub] WindUI failed to load: " .. tostring(result))
        return
    end
    WindUI = result
end

local function safe(method, ...)
    local ok, result = pcall(method, ...)
    if not ok then
        return nil
    end
    return result
end

local Window = WindUI:CreateWindow({
    Title = "Phone Empire",
    Icon = "smartphone",
    Author = "Auto Hub · research pilot",
    Folder = "PhoneEmpireHub",
    Size = UDim2.fromOffset(680, 520),
    MinSize = Vector2.new(600, 420),
    Theme = "Dark",
    Transparent = false,
    Acrylic = true,
    Resizable = true,
    ScrollBarEnabled = true,
    ToggleKey = Enum.KeyCode.RightShift,
    User = { Enabled = true, Anonymous = false },
})

Hub.notify = function(title, content)
    safe(function()
        WindUI:Notify({
            Title = title,
            Content = content,
            Duration = 4,
            Icon = "flask-conical",
        })
    end)
end

--- Puts the window back in the middle of the screen.
local function centerWindow()
    pcall(function()
        local holder = (gethui and gethui()) or game:GetService("CoreGui")
        local gui = holder:FindFirstChild("WindUI")
        local window = gui and gui:FindFirstChild("Window")
        local frame = window and window:FindFirstChild("Frame")
        if frame and frame:IsA("GuiObject") then
            frame.AnchorPoint = Vector2.new(0.5, 0.5)
            frame.Position = UDim2.fromScale(0.5, 0.5)
        end
    end)
end

task.defer(function()
    task.wait(0.8)
    centerWindow()
end)

local function section(parent, title, icon)
    -- Sections are collapsible and default to closed, which would hide
    -- everything inside them, so they are opened up front.
    local created = safe(function()
        return parent:Section({ Title = title, Icon = icon, Opened = true })
    end)
    return created or parent
end

local function paragraph(parent, title, desc)
    return safe(function()
        return parent:Paragraph({ Title = title, Desc = desc })
    end)
end

local function addToggle(parent, opts)
    return safe(function()
        return parent:Toggle(opts)
    end)
end

local function addButton(parent, opts)
    return safe(function()
        return parent:Button(opts)
    end)
end

local function addSlider(parent, opts)
    return safe(function()
        return parent:Slider(opts)
    end)
end

local function addDropdown(parent, opts)
    return safe(function()
        return parent:Dropdown(opts)
    end)
end

---------------------------------------------------------------
-- Tab: Research
---------------------------------------------------------------

local researchTab = Window:Tab({ Title = "Research", Icon = "flask-conical" })

local researchSection = section(researchTab, "Auto research", "bot")

local statusParagraph = paragraph(
    researchSection,
    "Status",
    "Starting up…"
)

local activeParagraph = paragraph(
    researchSection,
    "Lab",
    "Reading the game state…"
)

local nextParagraph = paragraph(
    researchSection,
    "Next targets",
    "—"
)

addToggle(researchSection, {
    Title = "Auto Research",
    Desc = "Keeps the lab busy with the next available technology, forever.",
    Value = cfg.autoResearch,
    Callback = function(value)
        cfg.autoResearch = value
        pushLog("Auto research " .. (value and "ON" or "OFF"))
        saveSettings()
    end,
})

addDropdown(researchSection, {
    Title = "Pick order",
    Desc = "Which tech the AI grabs first when a slot frees up.",
    Values = PRIORITIES,
    Value = cfg.priority,
    Callback = function(value)
        cfg.priority = value
        pushLog("Order: " .. tostring(value))
        saveSettings()
    end,
})

addSlider(researchSection, {
    Title = "RP reserve",
    Desc = "Never spend below this much research points.",
    Value = { Min = 0, Max = 5000, Default = cfg.reserveRp },
    Step = 10,
    Callback = function(value)
        cfg.reserveRp = value
        saveSettings()
    end,
})

addToggle(researchSection, {
    Title = "Return to main screen",
    Desc = "Closes the game panel after each action so you sit on the HUD.",
    Value = cfg.returnToMain,
    Callback = function(value)
        cfg.returnToMain = value
        if value then
            returnToMainScreen()
        end
        saveSettings()
    end,
})

local actionsSection = section(researchTab, "Manual", "mouse-pointer-click")

addButton(actionsSection, {
    Title = "Research the next tech now",
    Desc = "Starts one technology immediately, ignoring the RP reserve.",
    Icon = "play",
    Callback = function()
        local started = tryStartResearch(true)
        if started then
            Hub.notify("Started", started)
        else
            Hub.notify("Nothing to start", "No unlocked tech left, or the lab is full.")
        end
    end,
})

addButton(actionsSection, {
    Title = "Refresh state",
    Desc = "Re-reads your company from the server.",
    Icon = "refresh-cw",
    Callback = function()
        refreshState()
        Hub.notify("Synced", "Company state refreshed.")
    end,
})

---------------------------------------------------------------
-- Tab: Money
---------------------------------------------------------------

local moneyTab = Window:Tab({ Title = "Money", Icon = "banknote" })

local pipelineSection = section(moneyTab, "Phone pipeline", "smartphone")

local moneyStatusParagraph = paragraph(pipelineSection, "Pipeline", "Reading the factory…")

addToggle(pipelineSection, {
    Title = "Auto design & start a project",
    Desc = "Clones your newest device, fits the best researched chassis and starts development again.",
    Value = cfg.autoDev,
    Callback = function(value)
        cfg.autoDev = value
        pushLog("Auto project " .. (value and "ON" or "OFF"))
        saveSettings()
    end,
})

addToggle(pipelineSection, {
    Title = "Auto launch finished devices",
    Desc = "Launches the moment development finishes, with the campaign you pick below.",
    Value = cfg.autoLaunch,
    Callback = function(value)
        cfg.autoLaunch = value
        pushLog("Auto launch " .. (value and "ON" or "OFF"))
        saveSettings()
    end,
})

addDropdown(pipelineSection, {
    Title = "Marketing campaign",
    Desc = "How hard each launch is pushed. Best affordable keeps cash for production.",
    Values = CAMPAIGNS,
    Value = cfg.launchCampaign,
    Callback = function(value)
        cfg.launchCampaign = value
        pushLog("Campaign: " .. tostring(value))
        saveSettings()
    end,
})

addSlider(pipelineSection, {
    Title = "Launch price multiplier",
    Desc = "Multiplies your previous device's price. 1.0 = same price again.",
    Value = { Min = 0.5, Max = 3, Default = cfg.devPriceMult },
    Step = 0.05,
    Callback = function(value)
        cfg.devPriceMult = value
        saveSettings()
    end,
})

addSlider(pipelineSection, {
    Title = "Cash buffer before starting",
    Desc = "Millions that must be in the bank before a new project is started.",
    Value = { Min = 0, Max = 2000, Default = math.floor((cfg.devMinCash or 20000000) / 1000000) },
    Step = 5,
    Callback = function(value)
        cfg.devMinCash = value * 1000000
        saveSettings()
    end,
})

local incomeSection = section(moneyTab, "Extra income", "coins")

addToggle(incomeSection, {
    Title = "Auto buy out rivals",
    Desc = "Swallows the cheapest competitor you can comfortably afford.",
    Value = cfg.autoRivals,
    Callback = function(value)
        cfg.autoRivals = value
        pushLog("Auto rival buyouts " .. (value and "ON" or "OFF"))
        saveSettings()
    end,
})

addSlider(incomeSection, {
    Title = "Rival price buffer",
    Desc = "Only buy a rival when your cash is this many times its price.",
    Value = { Min = 1, Max = 20, Default = cfg.rivalReserve },
    Step = 0.5,
    Callback = function(value)
        cfg.rivalReserve = value
        saveSettings()
    end,
})

addToggle(incomeSection, {
    Title = "Auto claim candy quests",
    Desc = "Claims every candy quest the moment its goal is met.",
    Value = cfg.autoCandy,
    Callback = function(value)
        cfg.autoCandy = value
        pushLog("Auto candy " .. (value and "ON" or "OFF"))
        saveSettings()
    end,
})

addToggle(incomeSection, {
    Title = "Auto repricing",
    Desc = "Moves each device on sale towards what the game says it is worth.",
    Value = cfg.autoPrice,
    Callback = function(value)
        cfg.autoPrice = value
        pushLog("Auto repricing " .. (value and "ON" or "OFF"))
        saveSettings()
    end,
})

addSlider(incomeSection, {
    Title = "Price target",
    Desc = "Multiplier on the game's market value. Below 1.0 sells more units, above 1.0 earns more each.",
    Value = { Min = 0.5, Max = 2, Default = cfg.priceMult },
    Step = 0.05,
    Callback = function(value)
        cfg.priceMult = value
        saveSettings()
    end,
})

addToggle(incomeSection, {
    Title = "Auto bankruptcy rescue",
    Desc = "Spends the insurance rescue automatically if the company ever goes into the red.",
    Value = cfg.autoRescue,
    Callback = function(value)
        cfg.autoRescue = value
        pushLog("Auto rescue " .. (value and "ON" or "OFF"))
        saveSettings()
    end,
})

local nowSection = section(moneyTab, "Do it now", "zap")

addButton(nowSection, {
    Title = "Turn the whole money pipeline ON",
    Desc = "One click: auto projects, auto launches, rival buyouts, candy claims and rescue.",
    Icon = "power",
    Callback = function()
        cfg.autoDev = true
        cfg.autoLaunch = true
        cfg.autoRivals = true
        cfg.autoCandy = true
        cfg.autoRescue = true
        saveSettings()
        pushLog("Money pipeline enabled")
        Hub.notify("Pipeline", "Auto projects, launches, rivals, candy and rescue are all ON.")
    end,
})

addButton(nowSection, {
    Title = "Start a new project",
    Desc = "Designs the next device and sends it to the team immediately.",
    Icon = "pencil-ruler",
    Callback = function()
        local ok, message = startProject(true)
        Hub.notify(ok and "Project started" or "Could not start", tostring(message))
    end,
})

addButton(nowSection, {
    Title = "Launch the finished project",
    Desc = "Launches now, even if development is not quite done.",
    Icon = "rocket",
    Callback = function()
        local ok, message = launchProject(true)
        Hub.notify(ok and "Launched" or "Could not launch", tostring(message))
    end,
})

addButton(nowSection, {
    Title = "Buy the cheapest rival",
    Desc = "Instantly checks prices and swallows the best deal.",
    Icon = "handshake",
    Callback = function()
        local ok, message = buyoutRival()
        Hub.notify(ok and "Rival bought" or "No deal", tostring(message))
    end,
})

addButton(nowSection, {
    Title = "Claim candy quests",
    Desc = "Claims every finished candy quest right now.",
    Icon = "candy",
    Callback = function()
        local n = claimCandy()
        Hub.notify("Candy", n > 0 and ("Claimed " .. n .. " quest(s).") or "Nothing ready yet.")
    end,
})

---------------------------------------------------------------
-- Tab: AFK
---------------------------------------------------------------

local afkTab = Window:Tab({ Title = "AFK", Icon = "moon" })

local afkSection = section(afkTab, "Stay online", "wifi")

addToggle(afkSection, {
    Title = "Anti-AFK",
    Desc = "Stops Roblox idling you out while you are away.",
    Value = cfg.antiAfk,
    Callback = function(value)
        cfg.antiAfk = value
        saveSettings()
    end,
})

addToggle(afkSection, {
    Title = "Keep game speed",
    Desc = "Re-applies your speed multiplier if the game pauses time.",
    Value = cfg.autoSpeed,
    Callback = function(value)
        cfg.autoSpeed = value
        saveSettings()
    end,
})

addDropdown(afkSection, {
    Title = "Speed",
    Values = { "1x", "2x", "4x", "8x" },
    Value = tostring(cfg.speed) .. "x",
    Callback = function(value)
        cfg.speed = tonumber(string.match(value, "%d+")) or 4
        call("setSpeed", cfg.speed)
        saveSettings()
    end,
})

local idleSection = section(afkTab, "Idle income", "coins")

addToggle(idleSection, {
    Title = "Auto daily reward",
    Desc = "Claims the daily gift the moment it is ready.",
    Value = cfg.autoDaily,
    Callback = function(value)
        cfg.autoDaily = value
        saveSettings()
    end,
})

addToggle(idleSection, {
    Title = "Auto RP boosts",
    Desc = "Spends spare RP on lab quality and bug-fix boosts.",
    Value = cfg.autoBoosts,
    Callback = function(value)
        cfg.autoBoosts = value
        saveSettings()
    end,
})

addToggle(idleSection, {
    Title = "Auto office upgrade",
    Desc = "Buys the next office level when you can afford it.",
    Value = cfg.autoOffice,
    Callback = function(value)
        cfg.autoOffice = value
        saveSettings()
    end,
})

addToggle(idleSection, {
    Title = "Auto expand regions",
    Desc = "Opens the cheapest new market you can afford.",
    Value = cfg.autoExpand,
    Callback = function(value)
        cfg.autoExpand = value
        saveSettings()
    end,
})

local staffSection = section(afkTab, "Staff", "users")

addToggle(staffSection, {
    Title = "Auto train staff",
    Desc = "Turns money into stars, one employee at a time.",
    Value = cfg.autoTrain,
    Callback = function(value)
        cfg.autoTrain = value
        saveSettings()
    end,
})

addSlider(staffSection, {
    Title = "Train up to",
    Desc = "Stars to stop training at.",
    Value = { Min = 1, Max = 5, Default = cfg.trainMax },
    Step = 1,
    Callback = function(value)
        cfg.trainMax = value
        saveSettings()
    end,
})

addToggle(staffSection, {
    Title = "Auto hire",
    Desc = "Picks the strongest candidate whenever a desk is free.",
    Value = cfg.autoHire,
    Callback = function(value)
        cfg.autoHire = value
        saveSettings()
    end,
})

addToggle(staffSection, {
    Title = "Auto office party",
    Desc = "Throws a party when team morale dips.",
    Value = cfg.autoParty,
    Callback = function(value)
        cfg.autoParty = value
        saveSettings()
    end,
})

---------------------------------------------------------------
-- Tab: Stats
---------------------------------------------------------------

local statsTab = Window:Tab({ Title = "Stats", Icon = "chart-column" })

local statsParagraph = paragraph(statsTab, "Company", "—")
local goalParagraph = paragraph(statsTab, "Goal", "—")
local researchStats = paragraph(statsTab, "Research", "—")
local devicesParagraph = paragraph(statsTab, "On sale", "—")
local activityParagraph = paragraph(statsTab, "Recent actions", "—")

addButton(statsTab, {
    Title = "Refresh stats",
    Desc = "Pull the newest numbers from the server.",
    Icon = "refresh-cw",
    Callback = function()
        refreshState()
    end,
})

---------------------------------------------------------------
-- Tab: Settings
---------------------------------------------------------------

local settingsTab = Window:Tab({ Title = "Settings", Icon = "settings" })

local engineSection = section(settingsTab, "Engine", "cpu")

addSlider(engineSection, {
    Title = "Loop delay",
    Desc = "Seconds between checks. Lower is more responsive.",
    Value = { Min = 0.35, Max = 5, Default = cfg.tick },
    Step = 0.05,
    Callback = function(value)
        cfg.tick = value
        saveSettings()
    end,
})

addToggle(engineSection, {
    Title = "Notify on start",
    Desc = "Popup whenever a new technology begins.",
    Value = cfg.notifyOnStart,
    Callback = function(value)
        cfg.notifyOnStart = value
        saveSettings()
    end,
})

addButton(engineSection, {
    Title = "Save settings",
    Desc = "Writes your toggles to disk.",
    Icon = "save",
    Callback = function()
        local ok = saveSettings()
        Hub.notify("Settings", ok and "Saved." or "Could not write the file, but they stay for this session.")
    end,
})

addButton(engineSection, {
    Title = "Return to main screen",
    Desc = "Closes the in-game panel back to the HUD.",
    Icon = "house",
    Callback = function()
        returnToMainScreen()
    end,
})

addButton(engineSection, {
    Title = "Centre window",
    Desc = "Brings the hub back to the middle of the screen.",
    Icon = "move",
    Callback = function()
        centerWindow()
    end,
})

addButton(engineSection, {
    Title = "Unload hub",
    Desc = "Stops everything and removes the window.",
    Icon = "power",
    Callback = function()
        if getgenv().PT_HUB_DESTROY then
            pcall(getgenv().PT_HUB_DESTROY)
        end
    end,
})

-- The library leaves every tab container hidden until one is picked, so
-- select the first tab once the window has finished building.
task.defer(function()
    task.wait(0.5)
    pcall(function()
        researchTab:Select()
    end)
end)

--=============================================================
-- Live UI refresh
--=============================================================

local function formatMoney(value)
    local ok, text = pcall(Economy.money, value)
    if ok and type(text) == "string" then
        return text
    end
    return tostring(math.floor(value or 0))
end

local lastUi = 0
local function refreshUi(force)
    local now = os.clock()
    if not force and now - lastUi < 0.75 then
        return
    end
    lastUi = now

    local s = st()
    if not s then
        return
    end

    safe(function()
        statusParagraph:SetDesc(statusText())
    end)
    safe(function()
        statusParagraph:SetTitle(string.format("Auto research: %s", cfg.autoResearch and "ON" or "OFF"))
    end)

    local active = activeResearch()
    if #active == 0 then
        safe(function()
            activeParagraph:SetDesc("The lab is idle. The AI will start something as soon as RP allows it.")
        end)
    else
        local lines = {}
        for _, entry in ipairs(active) do
            local item = Config.ResearchById[entry.id]
            lines[#lines + 1] = string.format(
                "%s · %s days left · %s RP",
                item and item.name or entry.id,
                tostring(entry.daysLeft),
                tostring(item and item.cost or "?")
            )
        end
        safe(function()
            activeParagraph:SetDesc(table.concat(lines, "\n"))
        end)
    end

    local list = candidates()
    sortCandidates(list)
    local rp = math.floor(s.rp or 0)
    if #list == 0 then
        safe(function()
            nextParagraph:SetDesc("Nothing available. Either every technology is done, or the next one needs a later year.")
        end)
    else
        local lines = {}
        for i = 1, math.min(8, #list) do
            local item = list[i].item
            local tag = (item.cost or 0) <= rp and "ready" or "need " .. tostring((item.cost or 0) - rp) .. " RP"
            lines[#lines + 1] = string.format("%d. %s · %s RP · %s", i, item.name, tostring(item.cost), tag)
        end
        safe(function()
            nextParagraph:SetDesc(table.concat(lines, "\n"))
        end)
    end

    safe(function()
        statsParagraph:SetDesc(string.format(
            "Cash: %s\nRP: %s\nYear: %s (day %s)\nEmployees: %d\nDevices: %d\nReputation: %.2f\nStarted this session: %d",
            formatMoney(s.money),
            tostring(math.floor(s.rp or 0)),
            tostring(yearNow()),
            tostring(s.day),
            #(s.employees or {}),
            #(s.phones or {}),
            (s.reputation or 0),
            Hub.startedCount
        ))
    end)

    safe(function()
        local lines = {}
        for _, phone in ipairs(s.phones or {}) do
            if phone.active and #lines < 6 then
                lines[#lines + 1] = string.format(
                    "%s · %s · %.1f/10 · stock %s",
                    tostring(phone.name or "?"),
                    shortMoney(phone.price or 0),
                    phone.critic or 0,
                    tostring(math.floor(phone.stock or 0))
                )
            end
        end
        devicesParagraph:SetDesc(#lines > 0 and table.concat(lines, "\n") or "Nothing on sale right now.")
    end)

    safe(function()
        local goals = Config.Goals or {}
        local index = s.goalIndex or 1
        local goal = goals[index]
        if goal then
            local lines = { tostring(goal.text or "?") }
            if goal.hint and goal.hint ~= "" then
                lines[#lines + 1] = tostring(goal.hint)
            end
            if goal.reward and goal.reward ~= 0 then
                lines[#lines + 1] = "Reward: " .. tostring(goal.reward)
            end
            goalParagraph:SetTitle(string.format("Goal %d of %d", index, #goals))
            goalParagraph:SetDesc(table.concat(lines, "\n"))
        else
            goalParagraph:SetDesc("Every goal is complete.")
        end
    end)

    safe(function()
        local perDay = 0
        for _, employee in ipairs(s.employees or {}) do
            if employee.role == "Researcher" then
                local ok, value = pcall(Economy.researchOutput, employee)
                if ok and type(value) == "number" then
                    perDay = perDay + value
                end
            end
        end
        researchStats:SetDesc(string.format(
            "%d of %d technologies researched (%d%%)\nLab slots: %d\nResearch power: %.1f RP/day",
            researchedCount(),
            totalResearch(),
            math.min(100, math.floor(researchedCount() / math.max(1, totalResearch()) * 100)),
            researchSlots(),
            perDay
        ))
    end)

    safe(function()
        local lines = {}
        local dev = s.dev
        if dev then
            local percent = 0
            if type(dev.daysTotal) == "number" and dev.daysTotal > 0 and type(dev.day) == "number" then
                percent = math.floor(dev.day / dev.daysTotal * 100)
            elseif type(dev.progress) == "number" then
                percent = math.floor(dev.progress * 100)
            end
            if devReady(dev) then
                lines[#lines + 1] = "Design team: FINISHED - ready to launch"
            else
                lines[#lines + 1] = string.format("Design team: developing (%d%%)", percent)
            end
        else
            lines[#lines + 1] = "Design team: idle"
        end

        local previous = latestDevice()
        if previous then
            lines[#lines + 1] = string.format(
                "Newest device: %s · %s · %.1f/10",
                tostring(previous.name or "?"),
                shortMoney(previous.price or 0),
                previous.critic or 0
            )
        end

        local active, onSale = 0, 0
        for _, phone in ipairs(s.phones or {}) do
            if phone.active then
                active = active + 1
            else
                onSale = onSale + 1
            end
        end
        lines[#lines + 1] = string.format("Devices: %d in production · %d at end of life", active, onSale)

        local campaign = pickCampaign(s.money or 0)
        lines[#lines + 1] = string.format(
            "Next launch: %s (%s)",
            campaign.name,
            campaign.cost > 0 and shortMoney(campaign.cost) or "free"
        )
        lines[#lines + 1] = string.format(
            "Started %d · launched %d this session",
            Hub.devStarted or 0,
            Hub.launched or 0
        )

        moneyStatusParagraph:SetTitle(string.format(
            "Pipeline: %s",
            (cfg.autoDev or cfg.autoLaunch) and "AUTO" or "manual"
        ))
        moneyStatusParagraph:SetDesc(table.concat(lines, "\n"))
    end)

    safe(function()
        local lines = {}
        for i = 1, math.min(6, #Hub.log) do
            lines[#lines + 1] = Hub.log[i]
        end
        activityParagraph:SetDesc(#lines > 0 and table.concat(lines, "\n") or "Nothing yet.")
    end)
end

task.spawn(function()
    while (not RL or RL.alive()) and not Hub.stopped do
        pcall(refreshUi, false)
        task.wait(0.75)
    end
end)

refreshUi(true)

--=============================================================
-- Teardown
--=============================================================

local destroyed = false
getgenv().PT_HUB_DESTROY = function()
    if destroyed then
        return
    end
    destroyed = true
    Hub.stopped = true
    cfg.autoResearch = false
    cfg.autoDev = false
    cfg.autoLaunch = false
    cfg.autoRivals = false
    cfg.autoCandy = false
    cfg.autoPrice = false
    pcall(function()
        Window:Destroy()
    end)
    if Hub.notify then
        Hub.notify("Auto Hub", "Stopped. All automation is off.")
    end
end

if RL then
    RL.onCleanup(function()
        pcall(getgenv().PT_HUB_DESTROY)
    end)
end

getgenv().PhoneEmpireHub = Hub

Hub.notify("Auto Hub ready", "Right Shift toggles the window. Research, design, launch and rollouts are " .. ((cfg.autoResearch or cfg.autoDev) and "ON" or "OFF") .. ".")
pushLog("Hub loaded · " .. tostring(researchedCount()) .. "/" .. tostring(totalResearch()) .. " tech")
