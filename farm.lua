if not game:IsLoaded() then game.Loaded:Wait() end

-- ===== НАСТРОЙКИ =====
local MIN_PER_SEC     = 3500000   -- порог дохода (голды/сек)
local FIRST_MIN_SEC   = 2500000   -- порог первой минуты на новом сервере
local MAX_STRIKES     = 5         -- сколько ошибок до ухода
local STRIKE_TTL      = 3600      -- ошибки исчезают через столько сек (час)
local CHECK_TIME      = 60        -- как часто проверять доход (сек)
local LOAD_WAIT       = 10        -- ждать после входа на сервер
local HOP_DELAY       = 6         -- как в оригинале
local HOP_WAIT        = 30        -- пауза после телепорта (в оригинале 15, увеличено в 2 раза)
local VISIT_TTL       = 3600      -- сколько сек помнить посещённые сервера
local RECONNECT_DELAY = 16        -- пауза между попытками вернуться (в оригинале 8, увеличено в 2 раза)
local RECONNECT_MAX   = 1575      -- ~7 часов попыток (при паузе 16 сек)
local GOLD_WAIT       = 60        -- сколько ждать появления Gold/GoldEarned
local FARM_KEY        = Enum.KeyCode.E  -- кнопка автофарма (переключатель)

-- Приоритет серверов (заходим на любые, но в таком порядке):
local PREF_PLAYERS    = 11        -- 1-й приоритет: 11+ игроков
local SECOND_PLAYERS  = 10        -- 2-й приоритет: 10 игроков
                                  -- 3-й: все остальные

-- Заявки в друзья
local FRIEND_ENABLED  = true
local FRIEND_MIN_SEC  = 3000000   -- слать заявки, только если первая минута >= этого дохода
local FRIEND_DELAY    = 4         -- пауза между заявками (сек), не ставь меньше 3
local FRIEND_MAX      = 30        -- максимум заявок за один сервер
local FRIEND_TTL      = 604800    -- 7 дней не слать повторно тем же людям
-- =====================

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local VirtualInputManager = game:GetService("VirtualInputManager")
local CoreGui = game:GetService("CoreGui")
local LocalPlayer = Players.LocalPlayer
local httpRequest = request or http_request or (syn and syn.request)
local FILE = "farm_state.json"

-- ===== АНТИ-АФК =====
LocalPlayer.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
end)
task.spawn(function()
    while true do
        task.wait(60)
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end)

-- ===== НАЖАТИЕ КЛАВИШИ =====
local function pressKey(key)
    local ok = pcall(function()
        VirtualInputManager:SendKeyEvent(true, key, false, game)
        task.wait(0.1)
        VirtualInputManager:SendKeyEvent(false, key, false, game)
    end)
    if not ok then warn("[Клавиша] Не удалось нажать через VirtualInputManager") end
end

-- ===== СОСТОЯНИЕ (хранится в файле) =====
local state = {good = nil, visited = {}, strikes = {}, strikeServer = nil, requested = {}}

local function save()
    pcall(function() writefile(FILE, HttpService:JSONEncode(state)) end)
end

pcall(function()
    local data = HttpService:JSONDecode(readfile(FILE))
    if type(data) == "table" then
        state.good = data.good
        state.strikeServer = data.strikeServer
        for id, t in pairs(data.requested or {}) do
            if os.time() - t < FRIEND_TTL then state.requested[id] = t end
        end
        for id, t in pairs(data.visited or {}) do
            if os.time() - t < VISIT_TTL then state.visited[id] = t end
        end
        for _, t in ipairs(data.strikes or {}) do
            if os.time() - t < STRIKE_TTL then table.insert(state.strikes, t) end
        end
    end
end)
state.visited[game.JobId] = os.time()

local function pruneStrikes()
    local fresh = {}
    for _, t in ipairs(state.strikes) do
        if os.time() - t < STRIKE_TTL then table.insert(fresh, t) end
    end
    state.strikes = fresh
end

if state.strikeServer ~= game.JobId then
    state.strikes = {}
    state.strikeServer = game.JobId
end
save()

-- ===== ГОЛДА =====
local function getGold()
    local e = LocalPlayer:FindFirstChild("GoldEarned")
    if e and e:IsA("ValueBase") and tonumber(e.Value) then return tonumber(e.Value) end
    local g = LocalPlayer:FindFirstChild("Gold")
    if g and g:IsA("ValueBase") and tonumber(g.Value) then return tonumber(g.Value) end
    return nil
end

local function waitGold(timeout)
    local t0 = os.clock()
    while os.clock() - t0 < timeout do
        if getGold() ~= nil then return true end
        task.wait(2)
    end
    return false
end

-- ===== ТЕЛЕПОРТ =====
local giveUp = false
local fullSince = nil
TeleportService.TeleportInitFailed:Connect(function(plr, result, msg)
    if plr ~= LocalPlayer then return end
    warn("[Телепорт] Не удался:", result.Name, "|", msg)
    if result == Enum.TeleportResult.GameFull then
        fullSince = fullSince or os.clock()
    end
    if result == Enum.TeleportResult.GameEnded or result == Enum.TeleportResult.Unauthorized then
        giveUp = true
    end
end)

local function hopOnce()
    if not httpRequest then warn("[Хоп] В Xeno нет request") return end
    local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true"):format(game.PlaceId)
    local ok, res = pcall(httpRequest, {Url = url, Method = "GET"})
    if not ok or not res then warn("[Хоп] Ошибка запроса") return end
    if res.StatusCode == 429 then warn("[Хоп] Лимит запросов, жду 30 сек") task.wait(30) return end
    if res.StatusCode ~= 200 then warn("[Хоп] Код:", res.StatusCode) return end
    local ok2, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
    if not ok2 or not data or not data.data then return end

    -- ищем лучший сервер по приоритету: 11+ -> 10 -> все остальные
    local best, bestTier = nil, 99
    for _, s in ipairs(data.data) do
        if s.id ~= game.JobId and not state.visited[s.id]
            and s.playing and s.maxPlayers and s.playing < s.maxPlayers then
            local tier = 3
            if s.playing >= PREF_PLAYERS then
                tier = 1
            elseif s.playing >= SECOND_PLAYERS then
                tier = 2
            end
            if tier < bestTier then
                best, bestTier = s, tier
                if tier == 1 then break end
            end
        end
    end

    if best then
        state.visited[best.id] = os.time()
        save()
        print(("[Хоп] Иду на %s (%d игроков, приоритет %d)"):format(best.id, best.playing, bestTier))
        pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId, best.id, LocalPlayer) end)
        task.wait(HOP_WAIT)
        return
    end
    warn("[Хоп] Свободных серверов нет, жду")
end

local function forgetGood()
    state.good = nil
    state.strikes = {}
    state.strikeServer = nil
    save()
end

local function hopForever()
    while true do
        hopOnce()
        task.wait(HOP_DELAY)
    end
end

local function returnToGood()
    local id = state.good
    if not id then return false end
    giveUp = false
    fullSince = nil
    print("[Возврат] Пытаюсь вернуться на", id)
    for attempt = 1, RECONNECT_MAX do
        if game.JobId == id then return true end
        if giveUp or (fullSince and os.clock() - fullSince >= 30) then break end
        print(("[Возврат] Попытка %d/%d"):format(attempt, RECONNECT_MAX))
        pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId, id, LocalPlayer) end)
        task.wait(RECONNECT_DELAY)
    end
    warn("[Возврат] Сервер недоступен, забываю его и ищу новый")
    forgetGood()
    return false
end

-- ===== АВТОРЕКОННЕКТ =====
local reconnecting = false
task.spawn(function()
    local ok, overlay = pcall(function()
        return CoreGui:WaitForChild("RobloxPromptGui", 30):WaitForChild("promptOverlay", 30)
    end)
    if not ok or not overlay then return end
    overlay.ChildAdded:Connect(function(child)
        if child.Name ~= "ErrorPrompt" or reconnecting then return end
        reconnecting = true
        warn("[Реконнект] Вылет")
        task.spawn(function()
            if state.good then returnToGood() end
            hopForever()
        end)
    end)
end)

-- ===== ИЗМЕРЕНИЕ ДОХОДА =====
local function measure(seconds)
    local gained = 0
    local last = getGold()
    local t0 = os.clock()
    while os.clock() - t0 < seconds do
        task.wait(5)
        local now = getGold()
        if now then
            if last and now > last then gained += (now - last) end
            last = now
        end
    end
    return gained / (os.clock() - t0)
end

-- ===== ЗАПУСК АВТОФАРМА, ЕСЛИ ОН НЕ ИДЁТ =====
local function ensureFarm()
    -- меряем дольше, чтобы лаг не принять за остановку фарма
    -- (кнопка - переключатель, лишнее нажатие выключит рабочий фарм)
    local r = measure(30)
    if r > 0 then
        print("[Фарм] Идёт сам")
        return
    end
    print("[Фарм] Голда не растёт, нажимаю", FARM_KEY.Name)
    pressKey(FARM_KEY)
    task.wait(3)
    local r2 = measure(15)
    if r2 > 0 then
        print("[Фарм] Запустился")
    else
        warn("[Фарм] Не запустился после нажатия, проверь кнопку FARM_KEY")
    end
end

-- ===== ЗАЯВКИ В ДРУЗЬЯ =====
local function friendEveryone()
    local sent = 0
    for _, p in ipairs(Players:GetPlayers()) do
        if sent >= FRIEND_MAX then break end
        if p ~= LocalPlayer and p.Parent == Players and not state.requested[tostring(p.UserId)] then
            local isFriend = false
            pcall(function() isFriend = LocalPlayer:IsFriendsWith(p.UserId) end)
            if isFriend then
                state.requested[tostring(p.UserId)] = os.time()
            else
                local ok = pcall(function() LocalPlayer:RequestFriendship(p) end)
                if ok then
                    sent += 1
                    state.requested[tostring(p.UserId)] = os.time()
                    save()
                    print(("[Друзья] Заявка %d/%d -> %s"):format(sent, FRIEND_MAX, p.Name))
                else
                    warn("[Друзья] Не удалось отправить заявку:", p.Name)
                end
                task.wait(FRIEND_DELAY)
            end
        end
    end
    print("[Друзья] Готово, отправлено:", sent)
end

-- ===== ГЛАВНЫЙ ЦИКЛ =====
task.wait(LOAD_WAIT)

if not waitGold(GOLD_WAIT) then
    warn("[Голда] Gold/GoldEarned не появилась за", GOLD_WAIT, "сек, ухожу на другой сервер")
    forgetGood()
    hopForever()
    return
end

if state.good and state.good ~= game.JobId then
    returnToGood()
end

local firstMinute = (state.good ~= game.JobId)
print("[Старт] Сервер:", game.JobId, "| первая минута:", firstMinute)

ensureFarm()

while true do
    while reconnecting do task.wait(5) end
    local rate = measure(CHECK_TIME)
    if reconnecting then continue end
    print(("[Доход] %.2fM/сек"):format(rate / 1e6))

    if firstMinute then
        firstMinute = false
        if rate < FIRST_MIN_SEC then
            print("[Хоп] Первая минута слабая, ухожу сразу")
            forgetGood()
            hopForever()
        else
            state.good = game.JobId
            state.strikeServer = game.JobId
            save()
            print("[Сервер] Запомнил как прибыльный:", game.JobId)
            if FRIEND_ENABLED and rate >= FRIEND_MIN_SEC then
                print("[Друзья] Сервер с бустом, рассылаю заявки")
                task.spawn(friendEveryone)
            end
        end
    end

    pruneStrikes()
    if rate < MIN_PER_SEC then
        table.insert(state.strikes, os.time())
        save()
        print(("[Ошибка] %d/%d"):format(#state.strikes, MAX_STRIKES))
        if #state.strikes >= MAX_STRIKES then
            print("[Хоп] Ошибок набралось, ищу новый сервер")
            forgetGood()
            hopForever()
        end
    else
        save()
    end
end
