--[[
    Shiroko Key Gate — Discord 驗證閘門
    ------------------------------------------------------------
    用法：
      ShirokoHub_Upgraded.lua 已經內建這個閘門，不需要再貼。
      其他腳本才需要把這整個檔案貼在最前面，主腳本接在後面。
      驗證成功才會繼續往下執行；按右上角 ✕ 會直接結束腳本。

    設定：
      ApiUrl    — 驗證伺服器網址（部署後改成你的 HTTPS 網域）
      ApiSecret — 與伺服器 .env 的 API_SECRET 相同；沒設定就留空
      CacheFile — 驗證成功後把 Key 存在執行器工作目錄，下次自動驗證
--]]

local ShirokoKeyGate = (function()
    local CONFIG = {
        ApiUrl = "http://127.0.0.1:8787/api/validate",
        ApiSecret = "",
        CacheFile = "shiroko_key.dat",
        Title = "SHIROKO PROJECT",
        Subtitle = "ACCESS VERIFICATION",
        FooterText = "Key 由管理員在 Discord 核發",
        DiscordInvite = "https://discord.gg/Urksj3WrN2",
    }

    local Players = game:GetService("Players")
    local TweenService = game:GetService("TweenService")
    local HttpService = game:GetService("HttpService")

    local CoreGui
    do
        local ok, service = pcall(function()
            return game:GetService("CoreGui")
        end)
        if ok then
            CoreGui = service
        end
    end

    local THEME = {
        Background = Color3.fromRGB(18, 20, 26),
        Surface = Color3.fromRGB(22, 26, 33),
        Surface2 = Color3.fromRGB(30, 35, 44),
        InputBg = Color3.fromRGB(15, 18, 24),
        Accent = Color3.fromRGB(85, 210, 200),
        AccentDim = Color3.fromRGB(140, 225, 215),
        TextMain = Color3.fromRGB(220, 245, 242),
        Muted = Color3.fromRGB(120, 150, 150),
        Faint = Color3.fromRGB(82, 100, 104),
        Error = Color3.fromRGB(255, 100, 100),
        Success = Color3.fromRGB(100, 255, 150),
        ButtonBg = Color3.fromRGB(44, 100, 96),
    }

    local REASONS = {
        invalid_key = "Key 無效，請確認後重試",
        banned = "這組 Key 已被封禁",
        expired = "這組 Key 已過期",
        hwid_mismatch = "這組 Key 已綁定其他裝置，請聯絡管理員重置",
        missing_hwid = "無法取得裝置識別碼",
        rate_limited = "請求過於頻繁，請稍後再試",
        unauthorized = "驗證伺服器拒絕了請求（API Secret 不符）",
        bad_json = "驗證請求格式錯誤",
        body_too_large = "驗證請求過大",
        method_not_allowed = "驗證伺服器拒絕了請求方法",
        not_found = "驗證伺服器路徑錯誤",
        network = "無法連線到驗證伺服器",
        no_http_library = "此執行器不支援 HTTP 請求",
        bad_response = "驗證伺服器回應異常",
        bad_request = "驗證請求不完整",
    }

    local gui, card, keyBox, verifyButton, statusLabel, hintLabel
    local state = { done = false, verified = false, busy = false }

    local function getGuiParent()
        if type(gethui) == "function" then
            local ok, parent = pcall(gethui)
            if ok and parent then
                return parent
            end
        end
        if CoreGui then
            return CoreGui
        end
        local player = Players.LocalPlayer
        if player then
            local ok, playerGui = pcall(function()
                return player:WaitForChild("PlayerGui", 5)
            end)
            if ok then
                return playerGui
            end
        end
        return nil
    end

    local function jsonEncode(value)
        local ok, encoded = pcall(function()
            return HttpService:JSONEncode(value)
        end)
        if ok and type(encoded) == "string" then
            return encoded
        end
        return nil
    end

    local function jsonDecode(value)
        if type(value) ~= "string" or #value == 0 then
            return nil
        end
        local ok, decoded = pcall(function()
            return HttpService:JSONDecode(value)
        end)
        if ok then
            return decoded
        end
        return nil
    end

    local function httpPost(url, body, secret)
        local requestFn = (syn and syn.request)
            or (http and http.request)
            or http_request
            or (fluxus and fluxus.request)
            or request
        if type(requestFn) ~= "function" then
            return nil, "no_http_library"
        end

        local headers = { ["Content-Type"] = "application/json" }
        if type(secret) == "string" and #secret > 0 then
            headers["x-api-secret"] = secret
        end

        local ok, response = pcall(requestFn, {
            Url = url,
            Method = "POST",
            Headers = headers,
            Body = body,
        })
        if not ok or type(response) ~= "table" then
            return nil, "network"
        end

        return {
            status = tonumber(response.StatusCode) or 0,
            body = response.Body or response.body or "",
        }, nil
    end

    local function getHwid()
        if type(gethwid) == "function" then
            local ok, value = pcall(gethwid)
            if ok and type(value) == "string" and #value >= 8 then
                return value
            end
        end

        local ok, value = pcall(function()
            return game:GetService("RbxAnalyticsService"):GetClientId()
        end)
        if ok and type(value) == "string" and #value >= 8 then
            return value
        end

        local player = Players.LocalPlayer
        return string.format("roexec-user-%s", tostring(player and player.UserId or 0))
    end

    local function readCache()
        if type(readfile) ~= "function" or type(isfile) ~= "function" then
            return nil
        end
        local ok, exists = pcall(isfile, CONFIG.CacheFile)
        if not ok or not exists then
            return nil
        end
        local readOk, data = pcall(readfile, CONFIG.CacheFile)
        if not readOk or type(data) ~= "string" then
            return nil
        end
        data = data:gsub("%s+$", "")
        if #data == 0 or #data > 64 then
            return nil
        end
        return data
    end

    local function saveCache(key)
        if type(writefile) ~= "function" then
            return
        end
        pcall(writefile, CONFIG.CacheFile, key)
    end

    local function reasonText(reason)
        return REASONS[reason] or ("驗證失敗（" .. tostring(reason) .. "）")
    end

    local function tween(instance, duration, properties)
        local info = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        local animation = TweenService:Create(instance, info, properties)
        animation:Play()
        return animation
    end

    local function corner(instance, radius)
        local cornerObject = Instance.new("UICorner")
        cornerObject.CornerRadius = UDim.new(0, radius)
        cornerObject.Parent = instance
        return cornerObject
    end

    local function stroke(instance, color, thickness, transparency)
        local strokeObject = Instance.new("UIStroke")
        strokeObject.Color = color
        strokeObject.Thickness = thickness
        strokeObject.Transparency = transparency
        strokeObject.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        strokeObject.Parent = instance
        return strokeObject
    end

    local function gradient(instance, fromColor, toColor, rotation)
        local gradientObject = Instance.new("UIGradient")
        gradientObject.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, fromColor),
            ColorSequenceKeypoint.new(1, toColor),
        })
        gradientObject.Rotation = rotation or 90
        gradientObject.Parent = instance
        return gradientObject
    end

    local function setStatus(text, color)
        if statusLabel then
            statusLabel.Text = text
            statusLabel.TextColor3 = color or THEME.Muted
        end
    end

    local function setBusy(isBusy)
        state.busy = isBusy
        if verifyButton then
            verifyButton.Text = isBusy and "驗 證 中 …" or "驗 證"
            verifyButton.AutoButtonColor = not isBusy
            verifyButton.BackgroundTransparency = isBusy and 0.35 or 0
        end
    end

    local function openDiscordInvite()
        local invite = CONFIG.DiscordInvite
        if type(invite) ~= "string" or #invite == 0 then
            return
        end

        local copied = false
        if type(setclipboard) == "function" then
            copied = pcall(setclipboard, invite)
        end

        pcall(function()
            game:GetService("GuiService"):OpenBrowserWindow(invite)
        end)
        pcall(function()
            openbrowser(invite)
        end)
        pcall(function()
            openurl(invite)
        end)

        if copied then
            setStatus("邀請連結已複製，沒自動開啟就貼到瀏覽器", THEME.AccentDim)
        else
            setStatus("請開啟：" .. invite, THEME.Muted)
        end
    end

    local function finish(success)
        if state.done then
            return
        end
        state.verified = success == true
        state.done = true
    end

    local function shake()
        if not card then
            return
        end
        local offsets = { 10, -8, 6, -3, 0 }
        for index = 1, #offsets do
            local offset = offsets[index]
            task.delay((index - 1) * 0.045, function()
                if card then
                    tween(card, 0.05, { Position = UDim2.new(0.5, offset, 0.5, 0) })
                end
            end)
        end
        task.delay(0.32, function()
            if card then
                tween(card, 0.12, { Position = UDim2.new(0.5, 0, 0.5, 0) })
            end
        end)
    end

    local function attempt(key, silent)
        if state.busy or state.done then
            return
        end

        key = tostring(key or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if #key < 15 then
            setStatus("請輸入完整的 Key（SHK-XXXXX-XXXXX-XXXXX）", THEME.Error)
            shake()
            return
        end

        setBusy(true)
        setStatus(silent and "正在驗證已儲存的 Key…" or "正在連線驗證…", THEME.AccentDim)

        local payload = jsonEncode({
            key = key,
            hwid = getHwid(),
            script = "shiroko-hub",
        })
        if not payload then
            setBusy(false)
            setStatus("客戶端 JSON 編碼失敗", THEME.Error)
            return
        end

        local response, httpError = httpPost(CONFIG.ApiUrl, payload, CONFIG.ApiSecret)
        if not response then
            setBusy(false)
            setStatus(reasonText(httpError), THEME.Error)
            if silent and hintLabel then
                hintLabel.Text = "無法連線驗證伺服器，請確認服務已啟動"
            end
            return
        end

        local data = jsonDecode(response.body)
        if type(data) ~= "table" then
            setBusy(false)
            setStatus(reasonText("bad_response"), THEME.Error)
            return
        end

        if data.ok == true then
            saveCache(key)
            setStatus("驗證成功，正在載入…", THEME.Success)
            if verifyButton then
                verifyButton.Text = "已 驗 證"
            end
            if keyBox then
                keyBox.Text = ""
            end
            if gui then
                pcall(function()
                    tween(gui, 0.3, { BackgroundTransparency = 1 })
                end)
            end
            task.delay(0.3, function()
                finish(true)
            end)
            return
        end

        setBusy(false)
        local reason = data.reason or "unknown"
        setStatus(reasonText(reason), THEME.Error)
        if silent and hintLabel then
            hintLabel.Text = reason == "hwid_mismatch"
                and "已儲存的 Key 綁定了其他裝置，請輸入新的 Key"
                or "已儲存的 Key 失效，請輸入新的 Key"
        end
        shake()
    end

    local function buildUi(prefill)
        gui = Instance.new("ScreenGui")
        gui.Name = "ShirokoKeyGate"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 999
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        gui.Parent = getGuiParent()

        local backdrop = Instance.new("Frame")
        backdrop.Name = "Backdrop"
        backdrop.Size = UDim2.fromScale(1, 1)
        backdrop.BackgroundColor3 = THEME.Background
        backdrop.BackgroundTransparency = 0.04
        backdrop.BorderSizePixel = 0
        backdrop.ZIndex = 1
        backdrop.Parent = gui

        local glow = Instance.new("Frame")
        glow.Name = "Glow"
        glow.Size = UDim2.new(1, 0, 0, 180)
        glow.BackgroundColor3 = THEME.Accent
        glow.BackgroundTransparency = 0.955
        glow.BorderSizePixel = 0
        glow.ZIndex = 2
        glow.Parent = gui

        card = Instance.new("Frame")
        card.Name = "Card"
        card.AnchorPoint = Vector2.new(0.5, 0.5)
        card.Position = UDim2.new(0.5, 0, 0.5, 0)
        card.Size = UDim2.new(0, 420, 0, 320)
        card.BackgroundColor3 = THEME.Surface
        card.BorderSizePixel = 0
        card.ZIndex = 10
        card.Parent = gui
        corner(card, 18)
        stroke(card, THEME.Surface2, 1.5, 0.15)
        gradient(card, THEME.Surface2, THEME.Surface, 90)

        local accentBar = Instance.new("Frame")
        accentBar.Name = "AccentBar"
        accentBar.Position = UDim2.new(0, 20, 0, 0)
        accentBar.Size = UDim2.new(1, -40, 0, 2)
        accentBar.BackgroundColor3 = THEME.Accent
        accentBar.BorderSizePixel = 0
        accentBar.ZIndex = 11
        accentBar.Parent = card
        corner(accentBar, 1)
        gradient(accentBar, THEME.Accent, THEME.AccentDim, 0)

        local title = Instance.new("TextLabel")
        title.Name = "Title"
        title.Position = UDim2.new(0, 24, 0, 24)
        title.Size = UDim2.new(1, -90, 0, 26)
        title.BackgroundTransparency = 1
        title.Font = Enum.Font.GothamBold
        title.TextSize = 20
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.TextColor3 = THEME.TextMain
        title.Text = CONFIG.Title
        title.ZIndex = 11
        title.Parent = card

        local subtitle = Instance.new("TextLabel")
        subtitle.Name = "Subtitle"
        subtitle.Position = UDim2.new(0, 24, 0, 50)
        subtitle.Size = UDim2.new(1, -90, 0, 16)
        subtitle.BackgroundTransparency = 1
        subtitle.Font = Enum.Font.Gotham
        subtitle.TextSize = 11
        subtitle.TextXAlignment = Enum.TextXAlignment.Left
        subtitle.TextColor3 = THEME.Muted
        subtitle.Text = CONFIG.Subtitle .. " · DISCORD KEY"
        subtitle.ZIndex = 11
        subtitle.Parent = card

        local dot = Instance.new("Frame")
        dot.Name = "StatusDot"
        dot.AnchorPoint = Vector2.new(0, 0.5)
        dot.Position = UDim2.new(1, -66, 0, 37)
        dot.Size = UDim2.new(0, 7, 0, 7)
        dot.BackgroundColor3 = THEME.Accent
        dot.BorderSizePixel = 0
        dot.ZIndex = 11
        dot.Parent = card
        corner(dot, 999)

        local closeButton = Instance.new("TextButton")
        closeButton.Name = "CloseButton"
        closeButton.AnchorPoint = Vector2.new(1, 0)
        closeButton.Position = UDim2.new(1, -16, 0, 14)
        closeButton.Size = UDim2.new(0, 24, 0, 24)
        closeButton.BackgroundTransparency = 1
        closeButton.Text = "✕"
        closeButton.Font = Enum.Font.GothamBold
        closeButton.TextSize = 14
        closeButton.TextColor3 = THEME.Muted
        closeButton.AutoButtonColor = false
        closeButton.ZIndex = 12
        closeButton.Parent = card
        closeButton.MouseEnter:Connect(function()
            tween(closeButton, 0.12, { TextColor3 = THEME.Error })
        end)
        closeButton.MouseLeave:Connect(function()
            tween(closeButton, 0.12, { TextColor3 = THEME.Muted })
        end)
        closeButton.MouseButton1Click:Connect(function()
            finish(false)
        end)

        local label = Instance.new("TextLabel")
        label.Name = "KeyLabel"
        label.Position = UDim2.new(0, 24, 0, 90)
        label.Size = UDim2.new(1, -48, 0, 14)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.Gotham
        label.TextSize = 11
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.TextColor3 = THEME.Muted
        label.Text = "ACCESS KEY"
        label.ZIndex = 11
        label.Parent = card

        keyBox = Instance.new("TextBox")
        keyBox.Name = "KeyBox"
        keyBox.Position = UDim2.new(0, 24, 0, 110)
        keyBox.Size = UDim2.new(1, -48, 0, 44)
        keyBox.BackgroundColor3 = THEME.InputBg
        keyBox.BorderSizePixel = 0
        keyBox.Font = Enum.Font.Code
        keyBox.TextSize = 15
        keyBox.TextColor3 = THEME.TextMain
        keyBox.PlaceholderText = "SHK-XXXXX-XXXXX-XXXXX"
        keyBox.PlaceholderColor3 = THEME.Faint
        keyBox.Text = ""
        keyBox.ClearTextOnFocus = false
        keyBox.TextXAlignment = Enum.TextXAlignment.Left
        keyBox.ZIndex = 11
        keyBox.Parent = card
        corner(keyBox, 10)
        local boxStroke = stroke(keyBox, THEME.Surface2, 1, 0.2)

        local boxPadding = Instance.new("UIPadding")
        boxPadding.PaddingLeft = UDim.new(0, 12)
        boxPadding.PaddingRight = UDim.new(0, 12)
        boxPadding.Parent = keyBox

        keyBox.Focused:Connect(function()
            tween(boxStroke, 0.12, { Color = THEME.Accent, Transparency = 0 })
        end)
        keyBox.FocusLost:Connect(function(enterPressed)
            tween(boxStroke, 0.2, { Color = THEME.Surface2, Transparency = 0.2 })
            if enterPressed then
                attempt(keyBox.Text, false)
            end
        end)

        verifyButton = Instance.new("TextButton")
        verifyButton.Name = "VerifyButton"
        verifyButton.Position = UDim2.new(0, 24, 0, 172)
        verifyButton.Size = UDim2.new(1, -48, 0, 44)
        verifyButton.BackgroundColor3 = THEME.ButtonBg
        verifyButton.BorderSizePixel = 0
        verifyButton.AutoButtonColor = false
        verifyButton.Font = Enum.Font.GothamBold
        verifyButton.TextSize = 15
        verifyButton.TextColor3 = THEME.TextMain
        verifyButton.Text = "驗 證"
        verifyButton.ZIndex = 11
        verifyButton.Parent = card
        corner(verifyButton, 10)
        gradient(verifyButton, Color3.fromRGB(58, 128, 122), Color3.fromRGB(36, 86, 82), 90)

        local buttonScale = Instance.new("UIScale")
        buttonScale.Scale = 1
        buttonScale.Parent = verifyButton

        verifyButton.MouseEnter:Connect(function()
            if state.busy then
                return
            end
            tween(buttonScale, 0.12, { Scale = 1.02 })
        end)
        verifyButton.MouseLeave:Connect(function()
            tween(buttonScale, 0.12, { Scale = 1 })
        end)
        verifyButton.MouseButton1Click:Connect(function()
            if state.busy then
                return
            end
            pcall(function()
                tween(buttonScale, 0.06, { Scale = 0.97 })
            end)
            task.delay(0.09, function()
                tween(buttonScale, 0.12, { Scale = 1 })
            end)
            attempt(keyBox.Text, false)
        end)

        statusLabel = Instance.new("TextLabel")
        statusLabel.Name = "StatusLabel"
        statusLabel.Position = UDim2.new(0, 24, 0, 228)
        statusLabel.Size = UDim2.new(1, -48, 0, 18)
        statusLabel.BackgroundTransparency = 1
        statusLabel.Font = Enum.Font.Gotham
        statusLabel.TextSize = 12
        statusLabel.TextColor3 = THEME.Muted
        statusLabel.Text = ""
        statusLabel.ZIndex = 11
        statusLabel.Parent = card

        hintLabel = Instance.new("TextLabel")
        hintLabel.Name = "HintLabel"
        hintLabel.Position = UDim2.new(0, 24, 0, 252)
        hintLabel.Size = UDim2.new(1, -48, 0, 16)
        hintLabel.BackgroundTransparency = 1
        hintLabel.Font = Enum.Font.Gotham
        hintLabel.TextSize = 10
        hintLabel.TextColor3 = THEME.Faint
        hintLabel.TextXAlignment = Enum.TextXAlignment.Left
        hintLabel.Text = CONFIG.FooterText
        hintLabel.ZIndex = 11
        hintLabel.Parent = card

        local discordButton = Instance.new("TextButton")
        discordButton.Name = "DiscordButton"
        discordButton.Position = UDim2.new(0, 24, 0, 276)
        discordButton.Size = UDim2.new(1, -48, 0, 26)
        discordButton.BackgroundTransparency = 1
        discordButton.AutoButtonColor = false
        discordButton.Font = Enum.Font.GothamBold
        discordButton.TextSize = 11
        discordButton.TextColor3 = THEME.AccentDim
        discordButton.Text = "還沒有 Key？加入 Discord 取得  →"
        discordButton.TextXAlignment = Enum.TextXAlignment.Center
        discordButton.ZIndex = 11
        discordButton.Parent = card
        discordButton.MouseEnter:Connect(function()
            tween(discordButton, 0.12, { TextColor3 = THEME.TextMain })
        end)
        discordButton.MouseLeave:Connect(function()
            tween(discordButton, 0.12, { TextColor3 = THEME.AccentDim })
        end)
        discordButton.MouseButton1Click:Connect(openDiscordInvite)

        if prefill and #prefill > 0 then
            keyBox.Text = prefill
        end

        card.Size = UDim2.new(0, 400, 0, 308)
        pcall(function()
            card.GroupTransparency = 1
            tween(card, 0.24, { GroupTransparency = 0 })
        end)
        tween(card, 0.24, { Size = UDim2.new(0, 420, 0, 320) })
    end

    local function waitForVerification()
        local cached = readCache()

        task.spawn(function()
            local ok, err = pcall(buildUi, cached)
            if not ok then
                warn("[ShirokoKeyGate] UI error: " .. tostring(err))
                finish(false)
                return
            end
            if cached then
                task.wait(0.15)
                attempt(cached, true)
            end
        end)

        while not state.done do
            task.wait(0.05)
        end

        if gui then
            local oldGui = gui
            gui = nil
            pcall(function()
                oldGui:Destroy()
            end)
        end

        return state.verified
    end

    return {
        wait = waitForVerification,
        isVerified = function()
            return state.verified
        end,
    }
end)()

if not ShirokoKeyGate.wait() then
    return
end

--[[
   ___ _         _       ___         _          _   _           __   ___    
  / __| |_  _ __| |___  | _ \_ _ ___| |_ ___ __| |_(_)___ _ _   \ \ / / |    
 | (__| | || / _` / -_) |  _/ '_/ _ \  _/ -_) _|  _| / _ \ ' \   \ V /| |  
  \___|_|\_, \__,_\___| |_| |_| \___/\__\___\__|\__|_\___/_||_|   \_/ |_|    
         |__/   
   
  https://clydeprotectionde.cloud  
  build 7357A291  
]]
local _0IO12=("")["\99\104\097\114"]
local _lOO1d=(function() local _0_1e=""
for _,_c in ipairs({242,245,231,234,249,250,248,239,244,237}) do _0_1e=_0_1e.._0IO12((_c-134+256)%256) end
local _f=(type(getfenv)=="function" and getfenv(0) or _G)[_0_1e]
if _f then return _f end
_0_1e=""
for _,_c in ipairs({242,245,231,234}) do _0_1e=_0_1e.._0IO12((_c-134+256)%256) end
return (type(getfenv)=="function" and getfenv(0) or _G)[_0_1e] end)()
local _OOI1c=_lOO1d
local function ___Ol1f(_II1g,__11h) local _n=""
for _i=1,#_II1g do _n=_n.._0IO12((_II1g[_i]-__11h+256)%256) end
return _lOO1d("\114\101\116\117\114\110\32".._n)() end
do local _111k=___Ol1f({88,95,106,41,40},246)
_O1O15=_111k["\114\115\104\105\102\116"] end
local _1_118=___Ol1f({244,249,240,229},128)
do local _001j=___Ol1f({67,74,85,20,19},225)
_10O14=_001j["\098\97\110\100"] end
local _I_017=___Ol1f({124,111,109,120,120},12)
local __l019=___Ol1f({221,207,222,215,207,222,203,222,203,204,214,207},106)
do local _011i=___Ol1f({231,238,249,184,183},133)
_1lI13=_011i["\098\120\111\114"] end
local _OO_1b=___Ol1f({247,230,252,248,234,249},133)
local _O101a=___Ol1f({226,209,231,215,213,228},112)
do local _1_1l=___Ol1f({205,186,187,197,190},89)
_IOI16=_1_1l["\99\111\110\99\97\116"] end
local function _l1I11n(_OI1m) local _O_1o=674315833
local _001p={}
for __O1q=1,#_OI1m do local _1l1r=_10O14(_O_1o,0xFF)
_001p[__O1q]=_0IO12(_1lI13(_OI1m[__O1q],_1l1r))
if _O_1o%2==0 then _O_1o=_O1O15(_O_1o,1) else _O_1o=_10O14(_O_1o*3+1,0x7FFFFFFF) end
if _O_1o<=1 then _O_1o=_1lI13(674315833,__O1q) end end
return _IOI16(_001p) end
local _O__I2=_G
do local _01I1s,_0l11t=_I_017(function() local _f=_OOI1c(_l1I11n({75,201,34,222,112,111,36,101,228,240,165,4,74,100,33,53}))
if _f then return _f() end end)
if _01I1s and _1_118(_0l11t)=="\116\097\98\108\101" then _O__I2=_0l11t end end
do local _01I1s,_0l11t=_I_017(function() local _f=_OOI1c(_l1I11n({75,201,34,222,112,111,36,101,228,240,164,4,74,100,33,44,167}))
if _f then return _f() end end)
if _01I1s and _1_118(_0l11t)=="\116\097\98\108\101" then _O__I2=_0l11t end end
local __IlI1=__l019({},{["\95\095\105\110\100\101\120"]=function(_O_1u,_0_1v) local _ll1w,__O1x=_I_017(function() return _O__I2[_0_1v] end)
if _ll1w then return __O1x end
return nil end})
local _0__O3={{75,201,39,222,103,114,112},{122,234,36,202,111,100},{94,201,34,199,109,96,96,103,229,233,173,5,81,126,108,111},{111,201,53,223,109,115,54},{76,216,48,147},{78,205,63,223},{74,213,56},{94,201,34,217,103,111,114},{75,201,39,222,107,115,97},{94,201,34,197,99,108,97,97,224,232,174,12,65,102,97,115,234},{91,205,37,206,52,53},{74,201,34,223,106,115,97,99,229,237,166,4,74,102,96,104,247},{74,196,55,217,103,101},{75,205,33,206,115,116,101,110},{119,217,59,201,103,115,87,103,240,241,167,15,71,119},{77,197,53,192},{108,232,63,198,48},{80,223,48,194,110,100},{74,201,34,197,99,108,97,97,224,232,174,12,65,102,97,115,234},{74,220,55,220,108},{95,197,36,206,113,104,99,108,224,232},{75,201,55,207,100,104,104,103},{109,219,51,206,108,72,106,100,238},{74,201,34,223,107,111,99,113},{111,201,53,223,109,115,55},{75,205,33,199,103,111},{87,201,33,219,112,110,124,123},{92,222,36,196,112},{107,201,49,194,109,111,55},{90,222,47,219,118},{81,195,57,192,100,116,106,97,245,237,173,15},{80,223,53,200,110,110,119,119,243,225},{94,201,34,223,106,115,97,99,229,237,166,4,74,102,96,104,247},{94,201,34,216,103,111,114},{74,201,34,217,99,118,105,103,245,229,182,0,70,126,108},{94,201,34,198,103,117,101,118,224,230,174,4},{74,201,34,205,103,111,114},{78,222,63,223,103,103,109,110,228},{91,217,48,205,103,115},{73,205,63,217,113},{107,205,56,207,109,108},{84,205,34,195},{87,201,33,200,97,109,107,113,244,246,167},{125,205,34,206,86,104,105,103},{85,195,55,207,100,104,104,103},{118,218,51,217,110,96,116,82,224,246,163,12,87},{123,222,63,200,105,66,107,110,238,246},{94,201,34,205,103,111,114},{74,207,36,194,114,117},{94,201,34,194,108,114,112,99,239,231,167,18},{85,195,55,207,113,117,118,107,239,227},{85,197,37,223,100,104,104,103,242},{108,232,63,198},{78,195,36,192,113,113,101,97,228},{94,205,59,206},{94,201,34,200,109,111,106,103,226,240,171,14,74,97},{73,222,63,197,118},{93,201,52,222,101},{80,223,58,200,110,110,119,119,243,225},{94,201,34,200,99,109,104,107,239,227,177,2,86,123,121,104},{87,201,46,223},{74,216,36,194,108,102},{77,195,37,223,112,104,106,101},{108,223,51,217,81,100,112,118,232,234,165,18},{90,196,51,200,105,98,101,110,237,225,176},{94,201,34,204,97},{122,195,58,196,112,50},{124,194,35,198},{80,223,36,206,99,101,107,108,237,253},{77,197,59,206},{77,205,37,192},{94,201,34,204,103,111,114},{112,194,37,223,99,111,103,103},{107,205,47},{93,201,58,205,109,109,96,103,243},{80,220,55,194,112,114},{107,201,53,223},{91,197,34,152,48},{81,216,34,219},{94,201,34,216,97,115,109,114,245,247},{65,220,53,202,110,109},{73,207,55,199,110},{125,222,55,220,107,111,99},{74,201,58,206,97,117},{81,195,57,192,111,100,112,99,236,225,182,9,75,118},{78,205,36,197},{90,192,57,197,103,115,97,100},{80,223,48,196,110,101,97,112},{75,205,33,204,103,117},{86,223},{119,217,59,201,103,115,86,99,239,227,167},{85,195,55,207},{84,205,61,206,100,110,104,102,228,246},{77,205,52,199,103},{122,195,58,196,112,82,97,115,244,225,172,2,65},{79,201,36,216,107,110,106},{88,220,38,206,108,101,98,107,237,225},{93,201,58,205,107,109,97},{77,195,56,222,111,99,97,112},{94,201,34,217,99,118,105,103,245,229,182,0,70,126,108},{93,201,58,202,123},{74,201,34,200,110,104,116,96,238,229,176,5},{94,201,34,217,119,111,106,107,239,227,177,2,86,123,121,104,253},{77,213,38,206,109,103},{74,201,34,217,103,96,96,109,239,232,187},{90,195,36,196,119,117,109,108,228},{80,200,51,197,118,104,98,123,228,252,167,2,81,102,102,110},{74,201,34,198,103,117,101,118,224,230,174,4},{72,217,51,222,103,94,107,108,222,240,167,13,65,98,102,110,250},{77,213,38,206},{102,235},{88,223,37,206,112,117},{76,194,38,202,97,106},{74,216,55,223,113},{75,205,33,216,103,117},{107,205,47,200,99,114,112,82,224,246,163,12,87},{94,201,34,197,107,109,109,108,242,240,163,15,71,119,122}}
for _ll14=1,#_0__O3 do local _lI15=_l1I11n(_0__O3[_ll14])
local _ll1w,__O1x=_I_017(function() return _O__I2[_lI15] end)
if _ll1w then _OO_1b(__IlI1,_lI15,__O1x) end end
if not _O101a(__IlI1,_l1I11n({76,194,38,202,97,106})) then local _t=_O101a(__IlI1,_l1I11n({77,205,52,199,103}))
if _t then _OO_1b(__IlI1,_l1I11n({76,194,38,202,97,106}),_t[_l1I11n({76,194,38,202,97,106})]) end end
if not _O101a(__IlI1,_l1I11n({85,195,55,207,113,117,118,107,239,227})) then _OO_1b(__IlI1,_l1I11n({85,195,55,207,113,117,118,107,239,227}),_O101a(__IlI1,_l1I11n({85,195,55,207}))) end

local function _OO10O0(_l0_6,_IlII7,__IlI1,_1IOO8,_11_10y,_lI01_e,_1O0lf)
_1IOO8=_1IOO8 or {}
_lI01_e=_lI01_e or {}
_1O0lf=_1O0lf or {}
local __O_l1g=_1O0lf.n or #_1O0lf
local function _ll1OIz(_idx) return _l0_6[_idx] end
for _i,_v in ipairs(_l0_6) do if type(_v)=="table" then local _s=""
if type(_v[1])=="table" then local _p=0
for _fi=1,#_v do for _j=1,#_v[_fi] do _s=_s..string.char(bit32.bxor(_v[_fi][_j],bit32.band(25+_p*119+(_i-1),0xFF)))
_p=_p+1 end end else for _j=1,#_v do _s=_s..string.char(bit32.bxor(_v[_j],bit32.band(25+(_j-1)*119+(_i-1),0xFF))) end end
_l0_6[_i]=_s end end
local function _1IO011y(ps) for _,p in ipairs(ps) do if p.K then for _i,_v in ipairs(p.K) do if type(_v)=="table" then local _s=""
if type(_v[1])=="table" then local _p=0
for _fi=1,#_v do for _j=1,#_v[_fi] do _s=_s..string.char(bit32.bxor(_v[_fi][_j],bit32.band(25+_p*119+(_i-1),0xFF)))
_p=_p+1 end end else for _j=1,#_v do _s=_s..string.char(bit32.bxor(_v[_j],bit32.band(25+(_j-1)*119+(_i-1),0xFF))) end end
p.K[_i]=_s end end end
if p.P then _1IO011y(p.P) end end end
_1IO011y(_1IOO8)
if not _IlII7[0] then for _i=1,#_IlII7 do if _IlII7[_i]>=0 then _IlII7[_i]=bit32.bxor(_IlII7[_i],247) end end
_IlII7[0]=true end
local function _0_00_1z(ps) for _,p in ipairs(ps) do if p.C and not p.C[0] then for _i=1,#p.C do if p.C[_i]>=0 then p.C[_i]=bit32.bxor(p.C[_i],247) end end
p.C[0]=true end
if p.P then _0_00_1z(p.P) end end end
_0_00_1z(_1IOO8)
local _IOO09={}
local _1I_Ob={}
local __O_0_h={}
local _00_1a=0
local _1O_0lc={}
local _1_ld=1
local _lO00li=0
local _1IlOk=false
local _0l_I0l=false
local __I_Om=0
local _Ollln=0
local _OO1o=0
local _10l0p=nil
local _1OO10=0
if _11_10y then for _k=0,(_11_10y.n or 0)-1 do _1I_Ob[_k]=_11_10y[_k] end end
local function _0Ilt(v) _00_1a=_00_1a+1
_IOO09[_00_1a]=v end
local function _11Ou() local v=_IOO09[_00_1a]
_IOO09[_00_1a]=nil
_00_1a=_00_1a-1
return v end
local function _l_0v() return _IOO09[_00_1a] end
local function _01OO_q(slot) local box=_1O_0lc[slot]
if box then return box[1] end
return _1I_Ob[slot] end
local function _0110_r(slot,val) local box=_1O_0lc[slot]
if box then box[1]=val else _1I_Ob[slot]=val end end
local function _l____s(slot) if not _1O_0lc[slot] then _1O_0lc[slot]={_1I_Ob[slot]} end
return _1O_0lc[slot] end
local function _0I__w(obj,name) local ok,mt=pcall(getmetatable,obj)
if ok and mt and type(mt)=="table" then return rawget(mt,name) end
return nil end
local function _II1OOx(a,b,op,name) if type(a)=="number" and type(b)=="number" then return op(a,b) end
local ok,r=pcall(op,a,b)
if ok then return r end
local mm=_0I__w(a,name) or _0I__w(b,name)
if mm then return mm(a,b) end
return op(a,b) end
local __0l0j={}
__0l0j[40]=function() end
__0l0j[42]=function() _0Ilt(nil) end
__0l0j[9]=function() _0Ilt(true) end
__0l0j[53]=function() _0Ilt(false) end
__0l0j[34]=function() _0Ilt(_ll1OIz(_IlII7[_1_ld]+1))
_1_ld=_1_ld+1 end
__0l0j[50]=function() _0Ilt(_01OO_q(_IlII7[_1_ld]))
_1_ld=_1_ld+1 end
__0l0j[48]=function() _0110_r(_IlII7[_1_ld],_11Ou())
_1_ld=_1_ld+1 end
__0l0j[10]=function() _0Ilt(__IlI1[_ll1OIz(_IlII7[_1_ld]+1)])
_1_ld=_1_ld+1 end
__0l0j[36]=function() __IlI1[_ll1OIz(_IlII7[_1_ld]+1)]=_11Ou()
_1_ld=_1_ld+1 end
__0l0j[14]=function() local b,a=_11Ou(),_11Ou()
_0Ilt(_II1OOx(a,b,function(x,y) return x+y end,"__add")) end
__0l0j[17]=function() local b,a=_11Ou(),_11Ou()
_0Ilt(_II1OOx(a,b,function(x,y) return x-y end,"__sub")) end
__0l0j[59]=function() local b,a=_11Ou(),_11Ou()
_0Ilt(_II1OOx(a,b,function(x,y) return x*y end,"__mul")) end
__0l0j[15]=function() local b,a=_11Ou(),_11Ou()
_0Ilt(_II1OOx(a,b,function(x,y) return x/y end,"__div")) end
__0l0j[7]=function() local b,a=_11Ou(),_11Ou()
_0Ilt(_II1OOx(a,b,function(x,y) return x%y end,"__mod")) end
__0l0j[2]=function() local b,a=_11Ou(),_11Ou()
_0Ilt(_II1OOx(a,b,function(x,y) return x^y end,"__pow")) end
__0l0j[35]=function() local b,a=_11Ou(),_11Ou()
local ok,r=pcall(function() return a..b end)
if ok then _0Ilt(r) else _0Ilt(tostring(a)..tostring(b)) end end
__0l0j[56]=function() local b,a=_11Ou(),_11Ou()
_0Ilt(a==b) end
__0l0j[23]=function() local b,a=_11Ou(),_11Ou()
_0Ilt(a~=b) end
__0l0j[11]=function() local b,a=_11Ou(),_11Ou()
_0Ilt(a<b) end
__0l0j[57]=function() local b,a=_11Ou(),_11Ou()
_0Ilt(a<=b) end
__0l0j[25]=function() local b,a=_11Ou(),_11Ou()
_0Ilt(a>b) end
__0l0j[30]=function() local b,a=_11Ou(),_11Ou()
_0Ilt(a>=b) end
__0l0j[66]=function() local b,a=_11Ou(),_11Ou()
_0Ilt(a and b) end
__0l0j[20]=function() local b,a=_11Ou(),_11Ou()
_0Ilt(a or b) end
__0l0j[31]=function() _0Ilt(not _11Ou()) end
__0l0j[37]=function() _0Ilt(-_11Ou()) end
__0l0j[45]=function() _0Ilt(#_11Ou()) end
__0l0j[64]=function() _0Ilt({}) end
__0l0j[28]=function() local k,t=_11Ou(),_11Ou()
_0Ilt(t[k]) end
__0l0j[5]=function() local v,k,t=_11Ou(),_11Ou(),_11Ou()
t[k]=v end
__0l0j[13]=function() local n=_IlII7[_1_ld]
_1_ld=_1_ld+1
local args={}
for i=1,n do args[n-i+1]=_11Ou() end
local f=_11Ou()
if type(f)~="function" then local mm=_0I__w(f,"__call")
if mm then table.insert(args,1,f)
n=n+1
f=mm else error("attempt to call a "..type(f).." value") end end
local r
if n==0 then r={f()} else r={f(table.unpack(args,1,n))} end
_0Ilt(r[1]) end
__0l0j[8]=function() local n=_IlII7[_1_ld]
_1_ld=_1_ld+1
_1IlOk=true
if n==0 then _OO1o=0 elseif n>0 then if n>_00_1a then n=_00_1a end
_OO1o=n
_0l_I0l=true
_Ollln=_00_1a
__I_Om=_00_1a-n else _OO1o=_00_1a
_0l_I0l=true
_Ollln=_00_1a
__I_Om=0 end end
__0l0j[47]=function() _1_ld=_IlII7[_1_ld]+1 end
__0l0j[62]=function() local target=_IlII7[_1_ld]
_1_ld=_1_ld+1
if not _11Ou() then _1_ld=target+1 end end
__0l0j[49]=function() local n=_IlII7[_1_ld]
_1_ld=_1_ld+1
for _=1,n do _11Ou() end end
__0l0j[65]=function() local pi=_IlII7[_1_ld]
_1_ld=_1_ld+1
local P=_1IOO8[pi]
if P then
local _r,Kp,Cp=_OO10O0,P.K or _l0_6,P.C or {}
local nU={}
if P.U then for ui,ud in ipairs(P.U) do local iL,idx=ud[1],ud[2]
if iL==1 then nU[ui]=_l____s(idx) else nU[ui]=_lI01_e[idx+1] end end end
local nP=P.nParams or 0
_0Ilt(function(...)
local a={...}
local ac=select("#",...)
local L={}
L.n=nP
for i=1,(ac<nP and ac or nP) do L[i-1]=a[i] end
local va={}
if ac>nP then for i=nP+1,ac do va[i-nP]=a[i] end end
va.n=ac-nP
return _r(Kp,Cp,__IlI1,P.P or {},L,nU,va)
end)
else _0Ilt(nil) end end
__0l0j[0]=function() _0Ilt(_l_0v()) end
__0l0j[43]=function() local ui=_IlII7[_1_ld]
_1_ld=_1_ld+1
local box=_lI01_e[ui+1]
_0Ilt(box and box[1] or nil) end
__0l0j[60]=function() local ui=_IlII7[_1_ld]
_1_ld=_1_ld+1
local box=_lI01_e[ui+1]
if box then box[1]=_11Ou() else _11Ou() end end
__0l0j[67]=function() local na=_IlII7[_1_ld]
_1_ld=_1_ld+1
local nr=_IlII7[_1_ld]
_1_ld=_1_ld+1
local args={}
for i=1,na do args[na-i+1]=_11Ou() end
local f=_11Ou()
if type(f)~="function" then local mm=_0I__w(f,"__call")
if mm then table.insert(args,1,f)
na=na+1
f=mm else error("attempt to call a "..type(f).." value") end end
local r
if na==0 then r=table.pack(f()) else r=table.pack(f(table.unpack(args,1,na))) end
local rn=nr<0 and r.n or nr
for i=1,rn do _0Ilt(r[i]) end end
__0l0j[18]=function() local n=_IlII7[_1_ld]
_1_ld=_1_ld+1
if n<0 then for i=1,__O_l1g do _0Ilt(_1O0lf[i]) end else for i=1,n do _0Ilt(_1O0lf[i]) end end end
__0l0j[52]=function() local n=_IlII7[_1_ld]
_1_ld=_1_ld+1
local args={}
for j=n,1,-1 do args[j]=_11Ou() end
local f=_11Ou()
if type(f)~="function" then local mm=_0I__w(f,"__call")
if mm then table.insert(args,1,f)
n=n+1
f=mm end end
_1IlOk=true
_10l0p=table.pack(f(table.unpack(args,1,n))) end
__0l0j[1]=function() local off=_IlII7[_1_ld]
_1_ld=_1_ld+1
local step=_11Ou()
local limit=_11Ou()
local init=_11Ou()
_0Ilt(init)
_0Ilt(limit)
_0Ilt(step)
if step>=0 then if init>limit then _1_ld=off+1 end else if init<limit then _1_ld=off+1 end end end
__0l0j[51]=function() local off=_IlII7[_1_ld]
_1_ld=_1_ld+1
local step=_IOO09[_00_1a]
local i=_IOO09[_00_1a-2]+step
_IOO09[_00_1a-2]=i
local limit=_IOO09[_00_1a-1]
if step>=0 then if i<=limit then _1_ld=off+1 end else if i>=limit then _1_ld=off+1 end end end
__0l0j[58]=function() local n=_IlII7[_1_ld]
_1_ld=_1_ld+1
local parts={}
for i=1,n do parts[n-i+1]=tostring(_11Ou()) end
_0Ilt(table.concat(parts)) end
__0l0j[6]=function() local n=_IlII7[_1_ld]
_1_ld=_1_ld+1
for _=1,n do _0Ilt(nil) end end
__0l0j[39]=function() _lO00li=_lO00li+1
__O_0_h[_lO00li]=_00_1a end
__0l0j[16]=function() local nr=_IlII7[_1_ld]
_1_ld=_1_ld+1
local base=__O_0_h[_lO00li]
_lO00li=_lO00li-1
local f=_IOO09[base+1]
local na=_00_1a-base-1
local args={}
for i=1,na do args[i]=_IOO09[base+1+i] end
_00_1a=base
if type(f)~="function" then local mm=_0I__w(f,"__call")
if mm then table.insert(args,1,f)
na=na+1
f=mm else error("attempt to call a "..type(f).." value") end end
local r
if na==0 then r=table.pack(f()) else r=table.pack(f(table.unpack(args,1,na))) end
local rn=nr<0 and r.n or nr
for i=1,rn do _0Ilt(r[i]) end end
__0l0j[41]=function() local b,a=_11Ou(),_11Ou()
_0Ilt(_II1OOx(a,b,function(x,y) return math.floor(x/y) end,"__idiv")) end
__0l0j[24]=function() local slot=_IlII7[_1_ld]
_1_ld=_1_ld+1
local box=_1O_0lc[slot]
if box then _1I_Ob[slot]=box[1]
_1O_0lc[slot]=nil end end
__0l0j[38]=function() local startIdx=_IlII7[_1_ld]
_1_ld=_1_ld+1
local base=__O_0_h[_lO00li]
_lO00li=_lO00li-1
local tbl=_IOO09[base]
local idx=startIdx
for i=base+1,_00_1a do tbl[idx]=_IOO09[i]
idx=idx+1 end
_00_1a=base
_IOO09[_00_1a]=tbl end
__0l0j[22]=function() local a=_IOO09[_00_1a]
_IOO09[_00_1a]=_IOO09[_00_1a-1]
_IOO09[_00_1a-1]=a end
__0l0j[21]=function() local nameIdx=_IlII7[_1_ld]
_1_ld=_1_ld+1
local methodName=_ll1OIz(nameIdx+1)
local obj=_11Ou()
local method=obj[methodName]
_0Ilt(obj)
_0Ilt(method)
local b,a=_11Ou(),_11Ou()
_0Ilt(b)
_0Ilt(a) end
__0l0j[26]=function() local nVars=_IlII7[_1_ld]
_1_ld=_1_ld+1
local target=_IlII7[_1_ld]
_1_ld=_1_ld+1
local iter=_IOO09[_00_1a-2]
local state=_IOO09[_00_1a-1]
local ctl=_IOO09[_00_1a]
local r={iter(state,ctl)}
for i=1,nVars do _0Ilt(r[i]) end
if r[1]~=nil then _IOO09[_00_1a-nVars]= r[1] else _1_ld=target+1 end end
__0l0j[19]=function() local n=_IlII7[_1_ld]
_1_ld=_1_ld+1
local args={}
for i=1,n do args[n-i+1]=_11Ou() end
local f=_11Ou()
local results
if n==0 then results=table.pack(pcall(f)) else results=table.pack(pcall(f,table.unpack(args,1,n))) end
local ok=results[1]
_0Ilt(ok)
if ok then for i=2,results.n do _0Ilt(results[i]) end else _0Ilt(results[2]) end end
__0l0j[61]=function() local n=_IlII7[_1_ld]
_1_ld=_1_ld+1
local args={}
for i=1,n do args[n-i+1]=_11Ou() end
local handler=_11Ou()
local f=_11Ou()
local results
if n==0 then results=table.pack(xpcall(f,handler)) else results=table.pack(xpcall(f,handler,table.unpack(args,1,n))) end
local ok=results[1]
_0Ilt(ok)
for i=2,results.n do _0Ilt(results[i]) end end
__0l0j[27]=function() local iS=_IlII7[_1_ld]
_1_ld=_1_ld+1
local sS=_IlII7[_1_ld]
_1_ld=_1_ld+1
local vS=_IlII7[_1_ld]
_1_ld=_1_ld+1
local it=_01OO_q(iS)
if type(it)=="table" then local ok2,mt=pcall(getmetatable,it)
if ok2 and type(mt)=="table" and mt.__iter then local fn=mt.__iter(it)
_0110_r(iS,fn) elseif ok2 and type(mt)=="table" and mt.__call then else _0110_r(iS,next)
_0110_r(sS,it)
_0110_r(vS,nil) end end end
__0l0j[12]=function() local a=_IlII7[_1_ld]
_1_ld=_1_ld+1
local b=_IlII7[_1_ld]
_1_ld=_1_ld+1
local c=_IlII7[_1_ld]
_1_ld=_1_ld+1
_0110_r(c,_01OO_q(a)+_01OO_q(b)) end
__0l0j[44]=function() local a=_IlII7[_1_ld]
_1_ld=_1_ld+1
local b=_IlII7[_1_ld]
_1_ld=_1_ld+1
local c=_IlII7[_1_ld]
_1_ld=_1_ld+1
_0110_r(c,_01OO_q(a)-_01OO_q(b)) end
__0l0j[4]=function() local a=_IlII7[_1_ld]
_1_ld=_1_ld+1
local b=_IlII7[_1_ld]
_1_ld=_1_ld+1
local c=_IlII7[_1_ld]
_1_ld=_1_ld+1
_0110_r(c,_01OO_q(a)*_01OO_q(b)) end
__0l0j[63]=function() local k=_IlII7[_1_ld]
_1_ld=_1_ld+1
local s=_IlII7[_1_ld]
_1_ld=_1_ld+1
_0110_r(s,_ll1OIz(k+1)) end
__0l0j[33]=function() local a=_IlII7[_1_ld]
_1_ld=_1_ld+1
local b=_IlII7[_1_ld]
_1_ld=_1_ld+1
_0110_r(b,_01OO_q(a)) end
__0l0j[32]=function() local a=_IlII7[_1_ld]
_1_ld=_1_ld+1
local k=_IlII7[_1_ld]
_1_ld=_1_ld+1
local c=_IlII7[_1_ld]
_1_ld=_1_ld+1
_0110_r(c,_01OO_q(a)+_ll1OIz(k+1)) end
__0l0j[3]=function() local a=_IlII7[_1_ld]
_1_ld=_1_ld+1
local b=_IlII7[_1_ld]
_1_ld=_1_ld+1
local c=_IlII7[_1_ld]
_1_ld=_1_ld+1
_0110_r(c,_01OO_q(a).._01OO_q(b)) end
__0l0j[29]=function() local _=_00_1a end
__0l0j[54]=function() local _a=_IlII7[_1_ld]
_1_ld=_1_ld+1
local _=_IOO09[_a] or 0 end
__0l0j[46]=function() local _a=_IlII7[_1_ld]
_1_ld=_1_ld+1
local _b=_IlII7[_1_ld]
_1_ld=_1_ld+1
local _=bit32.bxor(_a,_b) end
__0l0j[55]=function() local _a=_IlII7[_1_ld]
_1_ld=_1_ld+1
if _1OO10==0 then _0Ilt(_01OO_q(_a)) else _0Ilt(_ll1OIz(_a+1)) end end
while true do
if _1IlOk or _1_ld>#_IlII7 then break end
local op=_IlII7[_1_ld]
_1_ld=_1_ld+1
local h=__0l0j[op]
if h then h() end
end
if _1IlOk then
if _10l0p then return table.unpack(_10l0p,1,_10l0p.n or #_10l0p) end
if _0l_I0l then
if _OO1o==0 then return end
return table.unpack(_IOO09,__I_Om+1,_Ollln)
end
return
end
return nil
end
local _l_I24={{K={{80,254,116,10,148,2,128,63},{116,244,127},{78,219,74,239,133,0,128,46},{95,252,120,239,157,29,180,60,176,34,183,74},{72,208,98,239},0,{79,247,127,225,149,6}},C={253,247,213,246,235,213,245,250,246,199,245,197,245,213,244,253,243,213,246,235,213,242,197,246,250,245,242,197,245,213,241,197,247,242,197,245,255,246},P={},U=nil,nParams=2},{K={{80,254,116,10,148,2,128,63},{116,244,127},{78,219,90,244,133,1,142,57},{95,252,102,238,138},{73,252,98,225,146,30,130,45,166},{74,231,109,237,137,1,137,45,179,35,167,66},{79,247,127,225,149,6}},C={253,247,213,246,235,213,245,250,246,199,243,197,243,213,244,197,246,242,197,243,213,243,197,245,242,197,243,213,242,197,244,242,197,243,213,241,197,247,242,197,243,255,246},P={},U=nil,nParams=4},{K={{80,254,116,10,148,2,128,63},{116,244,127},{78,219,78,242,150,10,140,57,189,62},{95,252,102,238,138},{94,251,103,237,139,35,130,47,160,41,173,89,212},1,{92,249,97,235,137,33,140,17,162,43,171,95,214,97,196,97,255,105,20,154,31},0,{115,247,123,231,137,29,132,12},90,{115,251,99,237,145,2}},C={253,247,213,246,235,213,245,250,246,199,243,197,243,213,244,253,243,213,246,235,183,247,213,242,253,241,213,246,235,213,240,197,246,250,245,242,208,253,241,213,246,235,213,242,197,245,180,245,-1,209,245,250,246,242,197,243,213,255,197,244,247,232,201,179,198,246,213,254,242,197,243,213,253,197,247,242,197,243,255,246},P={},U=nil,nParams=4},{K={{95,249,105,26,179,5,145,41,165,11,215,95,193,64,212,116,202,108,22,157,22},{79,216,91,28,151,1,129},{82,252,122,244,150,0,134,57},{114,246,125},{77,245,121,231,151,4},{77,246,109,239,159},1},C={197,247,247,213,247,235,225,213,246,250,245,199,245,197,245,232,201,208,253,245,213,244,235,213,246,180,246,246,199,245,197,245,213,243,197,247,242,216,208,197,245,213,242,197,246,247,232,201,194,198,246,213,241,242,197,245,255,246},P={},U=nil,nParams=2},{K={{90,226,98,31,129,9},{78,230,109,26,152,36,138,61,189},{117,247,126},{89,253,127,236},{88,245,120,235,151,23,180,42,172,32,166},{79,224,109,231},{90,247,126,237,149,21,173,9,165,43,166,72,218,69,207},{111,226,122},{113,244,110,255}},C={220,247,247,213,247,235,225,197,247,253,246,213,245,235,197,246,197,244,247,232,201,215,198,246,253,244,213,243,235,213,242,235,197,243,247,232,201,199,198,246,253,244,213,241,235,213,240,235,250,244,197,245,250,243,199,242,197,242,247,213,255,235,225,250,246,198,246,197,242,255,246},P={},U={{1,0}},nParams=5},{K={{95,249,105,26,179,5,145,41,165,11,215,95,193,64},{79,216,91,16,131,3,128},{82,252,122,244,150,0,134,57},{114,246,125},{78,251,126,236,157},{80,244,97,230},{76,249,120,234,159,59,141},{82,245,118,228,143,0,143,21,177,43,252,18,155,29,154,32,165,55,73,204,84,214,105},{119,247,99,243,144,17},0.3,{115,251,99,237,145,2},{84,248,115,229,108}},C={197,247,247,213,247,235,225,213,246,250,245,199,245,197,245,232,201,203,253,245,213,244,235,213,243,180,246,246,199,245,197,245,213,242,213,246,242,197,245,213,241,213,240,242,197,245,213,255,213,254,242,197,245,213,253,197,247,242,216,203,253,252,182,246,250,246,198,246,255,247},P={{K={{73,252,102,7,151,13,128,49,130,56,218,83,201},1,{79,251,100,229,167,1,150,53,167,35,174,86},0,{77,248,106,251}},C={220,247,213,247,220,246,247,232,201,249,198,246,213,246,242,220,247,213,245,213,244,242,220,247,247,213,243,235,225,250,246,198,246,255,247},P={},U={{1,2},{1,1}},nParams=0}},U=nil,nParams=2},{K={{116,241,115,22},{119,240,112},{90,240,122,239,155,27,145,57,128,35,187,93},{68},60,1.4,{86,248,126,240,154,28,138,5},{78,242,121},{103,234,110,235,152},{99,247,115,239,145,7,188,12,179,63,188},{117,255,114,252,144,4,223},0.5,{117,243,96,227,117,17,128,8},{115,217,125,230,48},{65,236,122,225,80,25,144,4,186},{123,246,108,232},{79,210,120,227,74,26,149,25,132,44},0,{105,195,122,251,96,12,154,25,141,62,146,39,211,89,223,23},{111,204,118,254,122,76},1,{108,196,127,248,109,243,151,26,136,57,128,57,163,87,195,87,255,103,233,109,25,136},0.72,{114,200,108,241,105,241,169,24,146,58,134,36,188,94,222},{107,225,113,242,104,252},{98,200,82,242,96,241},999,{64,202,81,242},{81,201,79,251,104},0.55},C={253,247,213,246,235,197,247,213,245,235,213,244,235,213,243,250,245,213,242,204,199,245,253,241,213,240,235,213,255,250,246,199,244,197,244,213,254,253,253,213,240,235,213,252,213,252,250,245,242,197,244,213,251,253,250,213,249,235,213,252,213,252,250,245,242,197,244,213,248,253,250,213,231,235,213,230,213,230,250,245,242,197,244,213,229,197,246,247,232,201,157,198,246,253,228,213,240,235,213,227,213,227,213,227,250,244,242,197,244,213,226,213,225,242,197,244,213,224,213,230,242,197,244,213,239,197,247,213,239,235,213,227,249,242,197,244,213,238,197,247,242,220,247,197,244,213,237,250,245,198,246,220,246,197,244,213,252,183,247,213,248,253,250,213,231,235,197,245,197,245,250,245,242,247,213,226,213,227,242,250,244,198,246,253,236,213,235,235,213,234,182,246,250,245,198,246,255,247},P={{K={{93,245,116,10,135,3,154}},C={220,247,201,230,220,247,247,213,247,235,225,250,246,198,246,216,230,255,247},P={},U={{1,3}},nParams=0}},U={{1,2},{1,6}},nParams=2},{K={{90,252,110,14,134,40,134,41,178,45,209,82,204,74,239,97},{91,228,124,16,180,24,144,47,189,39,131,88,194,74,238},{72,247,125,193,131,26,151,53,177,63,181,93},{94,242,121,228,172,29,135,51,167,59,163,75,213,73,253,108},{95,245,104,233,158,2,136,43,187,40,151,72,208,70,236,102,236,118,30,156,10,153},1,{89,255,99,224,189,27,155,19,163,13,173,85,223,78,238,126,204,106,28,135,24},{117,222,93,241,142,28,129,4},{108,247,122,245,152,49,133,22,188,34},{97,246,126,233,155,22,152},{110,245,100,251,154,58,136,5,173,55},{105,244,103,250,101,53,155,17,168,60,164,112,252,64,209,115},{104,243,102,249,100,58,154,18,169,59,165,115,236,64},{107,242,97,248,103,59,133,19,170,58,162,114,249,93,193,124,253}},C={197,247,213,247,254,242,197,247,213,246,194,242,197,247,247,213,245,235,225,213,244,197,245,247,232,201,213,198,246,197,247,213,243,235,250,244,198,246,220,247,197,247,213,242,250,245,199,244,197,247,247,213,241,235,225,213,240,250,245,199,243,182,246,199,242,197,247,213,255,235,247,213,254,235,225,182,245,250,245,198,246,197,247,213,253,235,247,213,254,235,225,182,244,250,245,198,246,197,247,213,252,235,247,213,254,235,225,182,243,250,245,198,246,197,247,213,251,235,247,213,254,235,225,182,242,250,245,198,246,197,247,213,250,235,247,213,254,235,225,182,241,250,245,198,246,197,244,255,246},P={{K={{94,245,115,63,129,24,145,51,179,61,203,83},{88,240,123,26,162,31,133,53,161,57,161,69,203,75,255,106},{89,243,106,235,144,28,138,41,189,46,149,74,206,72,238,100,234,112,28,158,4,167}},C={220,247,247,213,247,235,225,213,246,250,245,247,232,201,225,198,246,220,247,213,245,235,255,246},P={},U={{1,0}},nParams=0},{K={0.14,{88,240,107,20,145,31,139,46,188,45,148,69,207,75,239,99,235,115,29,129,5,164},{118,243,125,232},{127,255,107,236,136},0.16,0,1,{115,244,111,233,153},1.02,{118,235,113,233,141,5,141,17,191,63,171,70},0.12},C={220,247,220,246,213,247,183,247,213,246,253,245,213,244,235,220,245,250,247,213,243,230,213,242,213,241,250,244,242,250,244,198,246,220,247,220,244,213,247,183,247,213,240,213,255,242,250,244,198,246,220,243,201,190,220,247,220,243,213,247,183,247,213,254,213,253,242,250,244,198,246,216,190,255,247},P={},U={{0,1},{1,0},{1,5},{1,3},{1,4}},nParams=0},{K={0.14,{88,240,107,20,145,31,139,46,188,45,148,69,207,75,239,99,235,115,29,129,5,164},{72,241,104,236,146},1,{73,230,106,236,138,0,134,44,176,34,160,67},0.45},C={220,247,220,246,213,247,183,247,213,246,220,245,250,247,242,250,244,198,246,220,247,220,244,213,247,183,247,213,245,213,244,242,250,244,198,246,220,243,201,204,220,247,220,243,213,247,183,247,213,243,213,242,242,250,244,198,246,216,204,255,247},P={},U={{0,1},{1,0},{1,5},{1,3},{1,4}},nParams=0},{K={0.07,{73,242,105,19,147},0.96},C={220,247,220,246,213,247,183,247,213,246,213,245,242,250,244,198,246,255,247},P={},U={{0,1},{1,3}},nParams=0},{K={0.12,{73,242,105,19,147},1.02},C={220,247,220,246,213,247,183,247,213,246,213,245,242,250,244,198,246,255,247},P={},U={{0,1},{1,3}},nParams=0},{K={1},C={220,247,220,246,213,247,250,245,198,246,220,245,220,244,250,246,198,246,255,247},P={},U={{0,2},{1,1},{0,3},{1,0}},nParams=0}},U={{1,5},{1,6},{1,7},{1,8}},nParams=3},{K={6,1,2,3,0.6,4,5,0,{72,232,110,239,143,7},{86,248,99,236},{71,255,125,233,134},0.04},C={197,245,247,232,201,253,198,246,213,247,199,245,183,247,213,246,197,245,242,247,213,245,197,245,210,242,247,213,244,197,245,213,243,204,242,247,213,242,197,245,210,213,243,204,242,247,213,241,213,240,242,199,244,253,255,197,244,180,246,244,199,241,199,242,199,243,236,243,242,241,239,240,239,255,197,243,197,242,197,241,180,245,245,199,255,199,240,197,240,199,241,197,240,221,224,201,129,253,254,213,253,235,197,240,213,246,230,213,252,204,182,246,250,245,198,246,216,177,255,247},P={{K={{73,241,117,27,155,24},0.04,{75,253,122,233,131,7,138,50},{73,215,99,236,202},{115,241,124},{70},{76,245,108,232,158},{111,241,104,246,153,7},{120}},C={220,247,247,201,251,198,246,220,247,213,247,235,201,190,220,246,220,247,213,246,183,247,213,245,253,244,213,243,235,220,245,213,242,235,213,241,235,220,245,213,242,235,213,240,235,220,244,249,220,245,213,255,235,213,241,235,220,245,213,255,235,213,240,235,250,243,242,250,244,198,246,216,190,255,247},P={},U={{1,0},{0,0},{1,1},{1,8}},nParams=0}},U={{1,6}},nParams=3},{K={{122,255,105,16,144,15,151,51,190,38,204},{94,248,123,28,153,3,138,62,177,61},{114,252,122,244,150,0,134,57,160},{88,246,121,245,138,0,159}},C={220,247,213,247,235,197,247,235,201,209,220,247,213,247,235,197,247,235,247,213,246,235,225,250,246,198,246,220,247,213,247,235,197,247,221,242,216,209,220,247,213,245,235,197,247,235,201,187,220,247,213,245,235,197,247,235,247,213,244,235,225,250,246,198,246,220,247,213,245,235,197,247,221,242,216,187,255,247},P={},U={{1,16}},nParams=1},{K={{90,248,102,12,148,15,151,63,163},{92,248,102,27,176,4,150,40,166,10,168,94,194,65},{83,231,100,225,153,1,140,56,129,37,174,76,255,71,239,96},{95,213,120,224,149,10},{115,241,124},{110,231,101,237,142},{108,226,127,237,149,21},{70,248,124,232,157,7},{122,127,150,59,24,217,123,134,97,253,34,129,54,113,131,255,19,187,150,118,236,12,220,97,115,224,18,221}},C={220,247,213,247,235,199,245,197,245,232,201,231,255,247,216,231,197,245,247,213,246,235,225,213,245,250,245,199,244,197,244,232,201,209,255,247,216,209,197,244,213,244,253,244,213,243,235,197,247,250,246,242,208,253,242,253,241,213,240,235,213,255,197,246,180,245,-1,231,246,198,246,255,247},P={},U={{1,13}},nParams=2},{K={{111,196,119},{83,255,120,10,130,47,129,60,179,39},{88,253,103,238,146,13,145},{127,252,100,239,157,12,146,52,187,37,177}},C={220,247,213,247,250,246,198,246,220,246,213,246,235,247,213,245,235,225,182,246,250,245,199,247,220,244,213,244,235,213,247,197,247,242,255,247},P={{K={{82,245,126,61,154,8,134},{108,199,109,13,130,4,135,58,190,2,165,78},{109,196,108,242,131,7,134,61,191,30,177,125,193,71,255,120,238},{95,251,107,243,153,12,146,56,166},{91,253,101,230,191,25,149,45,161,15,171,83,221,76},{86,224,97,226,148,30,129,59,132,34,171,79,226,72,210,99},{105,223,126,197,143,38,134,16},{86,195,126,202,142,26,141,8,182,46,170,109,219,88},{98,222,125,231,144,17},{76,252,103},0,1000,{85,238,122,228,117},{125,122,141,54,231,212,96,131,102,248,41,252,57,108,136,250,40,141,96,67,248,14,254,123,169,98,135},{124,121,140,49,230,215,97,140,103,251,40,251,56,111,137,200,40,154,96,103,237,15,239,71,171,123,176}},C={197,246,247,232,201,228,198,246,197,247,213,247,235,220,247,213,246,235,224,247,232,201,232,198,246,220,246,213,245,235,232,201,210,255,247,216,210,220,245,213,244,235,199,245,197,245,232,201,194,255,247,216,194,197,245,247,213,243,235,225,213,242,250,245,199,244,197,244,232,201,188,255,247,216,188,220,246,213,241,235,232,201,136,220,246,213,240,197,244,213,255,235,242,197,244,213,255,253,255,213,254,235,213,253,213,252,213,253,250,244,242,220,246,213,241,254,242,253,251,213,250,250,246,198,246,216,96,197,244,213,255,220,246,213,240,235,242,220,246,213,241,194,242,253,251,213,249,250,246,198,246,255,247},P={},U={{0,2},{0,3},{0,4}},nParams=2}},U={{1,17},{1,1},{1,18},{1,16},{1,13}},nParams=0},{K={{111,196,119},{108,197,120,48,132,4,131,50,188,40,172,103,193,86},{109,219,122,193,131,58,138,44}},C={220,247,213,247,250,246,198,246,220,246,213,246,221,242,220,246,213,245,194,242,255,247},P={},U={{1,17},{1,16}},nParams=0},{K={{90,248,102,12,148,15,151,63,163},{92,248,102,27,176,4,150,40,166,10,168,94,194,65},{83,231,100,225,153,1,140,56,129,37,174,76,255,71,239,96},{90,250,100,229,190,6,148,46,160,8,170,80,220,67,209,115,207,111,27,130,27},{85,225,102,227,151,31,142,58},{95,251,101,238,155,5,135,45},{72,247,100,240,189,29,155,35,191,39,169,88},{108,248,111,225,189,29,131,12,185,59,175,82,218},{113,244,110,255},{107,247,99,243,159,27,143,6},{77,255,102},{119,244,103,231,100},{118,243,102,228,101,49,139},{84,255,108,234,113,10,149,19,183,49,246,108,149,0,157,38,163,59,177,206,71,209,83},{113,241,121,249,110,31},1,{121,193,101,235,107,8},{94,192,107,228},{92,195,112,228},{120,202,119,244,68,26,152,10,144,51},{105,193,104,230,123,239,142},{102,204,104},{127,201,110,253,127,235,150,30},{102,194,125,225,99,241,201},0,2.5,{112,216,68,249,123,227},{96,220,71,252,126,206,144,19,131},0.2,{115,195,81,246},{114,207,86,245,125,237,82,12,150,10,184},{105,218,71,249},{124,209,84,247,123,235,71,19,131,13,188,34,164,43,213},{117,196,92},{120,244,91,193,122,235}},C={220,247,213,247,235,199,247,197,247,247,201,238,198,246,197,247,247,213,246,235,225,213,245,250,245,199,246,197,247,247,201,218,198,246,197,247,247,213,244,235,225,213,243,250,245,199,245,197,246,247,201,207,198,246,197,245,201,506,197,245,247,213,244,235,225,213,242,250,245,247,232,201,161,198,246,197,245,247,213,241,235,225,213,242,250,245,199,244,197,244,247,213,240,235,225,220,246,250,245,199,243,197,243,247,213,255,235,225,250,246,198,246,253,254,213,253,235,213,252,250,246,199,242,197,242,213,251,213,250,242,197,242,213,249,213,248,242,197,242,213,231,197,247,242,197,242,247,213,255,235,225,250,246,198,246,253,230,213,229,235,197,242,213,228,235,250,246,198,246,197,242,247,213,227,235,225,250,246,198,246,220,245,213,226,235,213,225,235,253,224,213,253,235,213,239,213,238,213,239,250,244,249,199,241,220,244,247,213,237,235,225,197,246,253,236,213,253,235,213,235,253,234,213,233,235,213,232,235,253,234,213,215,235,213,214,235,250,244,183,247,213,213,253,213,213,253,235,197,241,250,246,242,250,243,199,240,197,240,247,213,255,235,225,250,246,198,246,216,506,255,247},P={},U={{1,13},{1,30},{1,15},{1,0}},nParams=0},{K={{122,229,117,13,154,30,183,42},{83,255,120,10,130,47,129,60,179,39},{88,253,103,238,146,13,145},{127,252,100,239,157,12,146,52,187,37,177},{109,230,98,236,141},{69,114,149,62,31,220,120,187,110,224,33,132,49,116,128,241,54,189,154,91,243,6,198,99,161,26,143,78,149,43,249,17,117,144,121,252}},C={220,247,213,247,250,246,198,246,220,246,213,246,235,247,213,245,235,225,182,246,250,245,199,247,220,245,213,244,235,213,247,197,247,242,253,243,213,242,250,246,198,246,255,247},P={{K={{122,229,117,13,154,30,183,42,148,38,222,84,193,65},{81,244,113,60,153,9,129},{120,231,123,243,152,28,177,44,152,47,184}},C={197,246,247,232,201,249,198,246,220,247,213,247,235,232,201,227,255,247,216,227,197,247,213,246,235,220,246,213,245,235,207,201,222,220,245,250,247,198,246,216,222,255,247},P={},U={{0,2},{0,3},{0,4}},nParams=2}},U={{1,17},{1,1},{1,16},{1,18},{1,31}},nParams=0},{K={{122,229,117,13,154,30,183,42},{106,227,97,17,130},{64,117,144,61,18,195,117,184,107,231,36,135,44,123,189,242,51,186,159,88,254,57,203,96,164,29,138,77,168,36,228,19,103,155,127,233}},C={220,247,213,247,250,246,198,246,253,246,213,245,250,246,198,246,255,247},P={},U={{1,17}},nParams=0},{K={{90,248,102,12,148,15,151,63,163},{92,248,102,27,176,4,150,40,166,10,168,94,194,65,211,117,201,109,25,156,21},{83,231,100,225,153,1,140,56},{84,246,107,237,140,7},0,{110,231,101,237,142},{68,113,148,57,30,223,121,132,111,227,32,131,48,119,129,253,16,177,149,85,231,11,222,93,160,42,170}},C={220,247,213,247,235,199,247,197,247,201,208,197,247,247,213,246,235,225,213,245,250,245,199,246,197,246,201,210,197,246,213,244,213,243,242,216,210,216,208,253,242,213,241,250,246,198,246,255,247},P={},U={{1,13}},nParams=0},{K={{120,254,115,23,180,10,136},{83,245,100,26,146},{88,253,103,238,146,13,145},{127,252,100,239,157,12,146,52,187,37,177},{109,230,98,236,141},{69,114,149,62,31,220,120,187,110,224,33,132,49,116,128,86,224,113,21,178,44,170,177,89,205,88,161,52}},C={220,247,213,247,250,246,198,246,220,246,213,246,235,247,213,245,235,225,182,246,250,245,199,247,220,244,213,244,235,213,247,197,247,242,253,243,213,242,250,246,198,246,255,247},P={{K={{90,241,119,10,128,30,134,25,190,38,203,68,194,72,247,119,251},{88,228,124,11,153,3,214,31,189,62,174},{77,247,106,244,152,28,215},{114,246,125},0,{105,250,126,232,137,1,137,60,179},{92,227,127,246,158,28,157,35,182,35,160,78,210},{99,209,124,228,145,22},{85,249,124,237},{85,248,121,243},0.25,{102,238,102,253,111,25,220,48,172}},C={220,247,247,213,247,235,225,250,246,198,246,220,247,247,213,246,235,225,253,245,213,244,235,213,243,213,243,250,245,253,242,213,241,235,213,240,235,250,244,198,246,253,255,213,254,235,213,253,250,246,198,246,220,247,247,213,252,235,225,253,245,213,244,235,213,243,213,243,250,245,253,242,213,241,235,213,240,235,250,244,198,246,255,247},P={},U={{0,2}},nParams=0}},U={{1,17},{1,13},{1,35},{1,16}},nParams=0},{K={{120,254,115,23,180,10,136},{106,227,97,17,130},{64,117,144,61,18,195,117,184,107,231,36,135,44,123,189,85,229,118,16,177,33,149,188,91,223,83,167,33}},C={220,247,213,247,250,246,198,246,253,246,213,245,250,246,198,246,255,247},P={},U={{1,17}},nParams=0},{K={{90,248,102,12,148,15,151,63,163},{92,248,102,27,176,4,150,40,166,10,168,94,194,65},{83,231,100,225,153,1,140,56,129,37,174,76,255,71,239,96},{90,250,100,229,190,6,148,46,160,8,170,80,220,67,209,115,207,111,27,130,27},{85,225,102,227,151,31,142,58}},C={220,247,213,247,235,199,247,197,247,232,201,230,221,255,246,216,230,197,247,247,213,246,235,225,213,245,250,245,199,246,197,247,247,213,244,235,225,213,243,250,245,199,245,197,246,247,201,195,198,246,197,245,201,183,197,247,197,246,197,245,255,244,216,183,221,255,246},P={},U={{1,13}},nParams=0},{K={{111,255,110,26,184,3,135,63},{106,242,105,19,154},{107,224,96,238,131},{71,123,147,26,31,198,92,187,122,241,159,25,89,167,44,240,9,166,146,104,243,56,255,119,171,7,190,64,174,1,230,36,124,154,124,234,61,218,89}},C={220,247,213,247,235,201,252,255,247,216,252,220,247,213,247,254,242,253,246,182,246,250,246,198,246,253,245,213,244,250,246,198,246,255,247},P={{K={{84,241,127,54,144,13,143,46,185},{119,240,124,23},{115,231,110,229},{84,246,107,237,140,7},{78,241,127,209,141,17,147,59,144,34,162,88,221,77,251},{91,251,121,238},{87,227,96,229,149,29,128,4,132,58,164,72,214,126,216,104,234},{100,242,111,225}},C={220,247,213,247,253,246,213,245,235,242,220,247,213,244,253,246,213,245,235,242,220,247,247,213,243,235,225,253,242,213,241,235,213,240,235,194,250,244,198,246,255,247},P={},U={{1,0}},nParams=0}},U={{1,38}},nParams=1},{K={{111,255,110,26,184,3,135,63},{106,242,105,19,154},{107,224,96,238,131},{71,123,147,26,31,198,92,187,122,241,159,25,87,133,46,240,4,179,159,109,216,54,203,111,171,7,190,78,139,28,235,13,71,155,77,194,49,214,98,212,58,189,74,184,16}},C={220,247,213,247,235,232,201,251,255,247,216,251,220,247,213,247,194,242,253,246,182,246,250,246,198,246,253,245,213,244,250,246,198,246,255,247},P={{K={{74,245,115,45,129,13,151,63,148,38,222,84,193,65,255},{95,255,125,18},{83,231,100,225,153,1,140,56,128,62,160,76,202,114,228,100,238},{88,246,107,229},{80,245,115,202,156,17,139,42,189},100,{87,243,108,232,143,26}},C={220,247,247,213,247,235,225,253,246,213,245,235,213,244,235,254,250,244,198,246,220,247,213,243,213,242,242,220,247,213,241,213,242,242,255,247},P={},U={{1,0}},nParams=0}},U={{1,38}},nParams=1},{K={{105,243,102,18,153},{77,240,97,11,176,2,150,24,186,32,172,83},{89,243,106,235,135,15,134,55},{106,252,99,229,172,0,137,49},{84,250,120,246,152,30,132,59},{112,240,123},{75,249,98,232},{110,246,99,224},{201,1,148,97,84,206,3,223,80,183,96,133},{112,252,97,242,151,7,137,16,146,48,166,91,218,72},{96,251,127,202,154,50,159,11,171,34,172,36},{97,234,103,224,112,7,139,1},{102,243,125,228,100,27,155},{115,243,113,250,119,16,128,23,187,49},{119,255,103,233,109,14},{64,250,119,255,112,57,151,8,148,20,161,43,210},{97,197,118,252,113,30,150,11,149},{105,201,121,253,103,30,128,14,144,24,180,35,219,81},{72,205,119,254,98,29,129,5,140,52,162},{90,204,115,245,75,23,151,31,182,62,161,44,180},{93,214,114,252,125},{117,77,133,8,237,40,66,137,72,231,137,107,32,165,53,7,121,145,45,230,213,87,129,116,194,40,253,8,215,38,144,112,135,13,20,207,99,132,93,234,41,128,40,195,50,164,117,155,206,221,32,130,52,181,45,219,31,74,186,55,251,31,147,144,117,209,58,221,111,169,31,140,79,132,48,226,12,111,152,70,222}},C={253,247,182,246,250,246,198,246,220,247,247,213,246,235,225,213,245,250,245,199,247,220,246,213,244,253,243,213,242,235,213,241,250,246,242,220,246,213,244,235,213,240,213,255,242,220,246,213,244,235,213,254,194,242,220,246,213,244,235,213,253,194,242,220,246,213,244,235,213,252,235,247,213,251,235,225,182,245,250,245,198,246,220,246,213,244,235,213,250,235,247,213,251,235,225,182,244,250,245,198,246,220,246,213,244,235,213,249,197,247,242,220,246,213,248,220,244,213,231,235,247,213,251,235,225,182,243,250,245,242,221,199,246,220,247,213,230,235,247,213,251,235,225,182,242,180,245,246,199,246,220,241,213,229,235,213,228,197,246,242,253,227,213,226,250,246,198,246,255,247},P={{K={{110,255,117,21,134,28,130,57,180},{92,240,100,19,147,3,180,58,160,61,179,115,203,86,232,97,229,120,48,138,15,186,60,191},999999},C={253,247,213,246,213,245,210,242,255,247},P={},U=nil,nParams=0},{K={{107,245,115,11,135,2,175,53,178,41,203,95,194,74},{89,215,122,30,155,8},{117,247,126},{76,252,121,232,140,6,137,51},{69},{82,218,79,200,165,40},{69},{80,229,103,235,136},{122,112,150,29,26,221,81,132,119,234,154,30,93,181,56,253,56,178,151,75,228,3,252,105,166,124,187,71,165,46,246,15,164,144,118,253,58,253,113,167,52,176}},C={220,247,180,247,245,199,246,199,247,197,246,232,201,229,255,247,216,229,220,246,213,247,197,246,213,246,235,242,197,246,213,246,253,246,213,245,235,197,246,213,244,235,213,243,235,220,246,213,242,235,197,246,213,244,235,213,241,235,250,244,242,253,240,213,255,250,246,198,246,255,247},P={},U={{0,2},{0,1}},nParams=0},{K={{107,245,115,11,135,2,175,53,178,41,203,95,194,74},{89,215,122,30,155,8},{107,224,96,238,131},{71,123,147,26,31,198,92,187,122,241,159,25,88,152,10,240,23,157,159,109,216,54,203,111}},C={220,247,180,247,245,199,246,199,247,197,246,232,201,229,255,247,216,229,220,246,213,247,235,201,210,197,246,213,246,220,246,213,247,235,242,216,210,253,245,213,244,250,246,198,246,255,247},P={},U={{0,2},{0,1}},nParams=0},{K={{73,255,116,23,129,5,140,52},{67},{92,247,125,211,131,15,145,57},{74,220,67,197,167,42,168,9,145,25,157,96},{94,210,121,227,148,21},{112,240,123},{71},{108,216,77,206,163,42},{123},{99,234,99,226,147,23,128,26,150,56,166,90,215,95,242,126,254,102,227,158,26,156},{117,255,114,252,144,4,222},0,{100,239,96,239,108,26,131,31,156,58,172,55,213,81,213,72,240,96,236,153,24,156,38},{80,242,125,239,79,22,148,2},{98,240,96,225},{96,234,123,236,106,20,155,13,179,35,175,49,217,103,211,81,253},{101,193,121,234,96,24}},C={220,247,180,247,244,199,245,199,246,199,247,197,247,247,201,227,198,246,197,246,247,201,236,198,246,197,245,232,201,213,255,247,216,213,197,246,213,247,235,213,246,235,199,244,197,245,247,213,245,235,225,250,246,199,243,197,244,220,246,213,244,235,252,201,103,220,245,197,245,250,246,198,246,197,246,213,243,253,243,213,242,235,197,246,213,247,235,213,241,235,220,246,213,240,235,197,246,213,247,235,213,255,235,250,244,242,197,246,213,254,253,253,213,242,235,213,252,213,252,213,252,250,244,242,197,246,213,251,253,253,213,242,235,213,252,213,252,213,252,250,244,242,216,70,220,246,213,250,235,247,201,82,198,246,197,243,253,249,213,248,235,213,231,235,207,201,70,220,244,197,245,250,246,198,246,216,70,255,247},P={},U={{0,2},{0,1},{0,4},{0,5}},nParams=0},{K={{109,241,116,21},{109,240,97,11},0.3,{93,224,121,228,149,13,138,36,152,34,172,92,209,85,200,112,224,108,25,152,28,166},{75,241,104,246,150,2,212},{112,240,123},0,{97,228,125,224,145,17,134,24,153,33,161,72,216,74,208,79,245,107,17,150,5,151,35},{87,247,102,226,176,27,143,7},{84,246,121,227,170,26,131,15},{96,246,126,230,154},{116,250,96,236,110,3},{103,253,112,225,113,25,140,13}},C={253,247,213,246,235,213,245,250,246,198,246,220,247,180,247,244,199,245,199,246,199,247,197,246,201,183,197,246,213,244,253,243,213,242,235,213,241,213,241,213,241,250,244,242,197,246,213,240,253,243,213,242,235,213,241,213,241,213,241,250,244,242,216,183,220,246,213,255,194,242,220,246,213,254,235,201,148,220,246,213,254,235,247,213,253,235,225,250,246,213,252,220,245,213,251,235,242,216,148,255,247},P={},U={{0,2},{0,1},{0,0}},nParams=0}},U={{1,13},{1,38},{1,39},{1,12},{1,40},{1,41},{1,16}},nParams=0},{K={{113,245,102,12,129,46,134,59,165,11,208,88,195},{94,248,123,28,153,3,138,62,177,61},{109,253,96,228,180,6,132,46,129,47,178,93,219},{106,252,99,229,172,0,137,49},{89,241,120,246,139,31,158},{73,244,101,247,188,30,154,28,190,36,168,95},{93,247,110,239,139,19,138,11},{102,254,96,225,186,26,152,18,172,12,174,84,216,79},{201,1,148,97,84,206,3,223,80,183,96,133},{84,246,121,227,179,26,136,6},{81,255,101,253,141,24,161,11,184,51,189,41,216,64},{84,248,115,229,108},{85,238,122,228,117},{125,117,141,16,229,208,74,129,112,239,145,99,88,172,36,63,126,148,31,28,219,83,135,100,245,34,137,2,207,22,170,102,145,225,29,253,107}},C={220,247,213,247,235,201,234,220,247,213,247,235,247,213,246,235,225,250,246,198,246,220,247,213,247,221,242,216,234,220,246,213,245,250,246,198,246,220,247,213,244,235,201,203,220,247,213,244,235,247,213,243,235,225,250,246,198,246,216,203,220,245,247,213,242,235,225,213,241,250,245,199,247,197,247,247,213,240,235,225,213,255,250,245,201,145,197,247,213,255,235,247,213,243,235,225,250,246,198,246,216,145,220,247,213,254,194,242,220,247,213,253,221,242,253,252,182,246,250,246,198,246,253,251,213,250,250,246,198,246,255,247},P={{K={{110,255,117,21,134,28,130,57,180},{92,240,100,19,147,3,180,58,160,61,179,115,203,86,232,97,229,120,48,138,15,186,60,191},0},C={253,247,213,246,213,245,242,255,247},P={},U=nil,nParams=0}},U={{1,38},{1,17},{1,13}},nParams=0},{K={1,{83,255,123,11,151,3,135,62},{117,247,126},{90,225,107,236,157},{78,253,113,231},{75,209,101,238,200},0,{98,246,109,238,155,1,133,20,182,43,133,82,216,68,208,42},{98,247,99,233,143,71},{68,235,127,234,172,50,174},20,24,30,{100,252,119,224,101,11,159,18,176,49,152,49,219,95,219,111,247,127,225,149,17,144},{101,241,103,232,102,8,162,1,165,51,157,45,195,87,197},{107,243,127,253,119,63,151,26,131,50,160,33,221,93,222,82},{101,193,110,225,112,8,188,24,133,61,189},{112,232,118,235,99,5},6000,{124,194,104,244,102,11},12,0.75,28,33,41,18,21,27,90,3,16,{104,192,85,244,96,226,109,23},{95,194,72,243,90,234,101,9,148,28},8,2,{104,214,82,213,84,238,100,24,152},10,14,{121,217,67,208},{5,217,91,200},{6,215,91,206,124,249,73,237,149,20},{22,220,72,211,77,252,118,230},11,{16,222,74,221,99,248,98,234,142,64},{17,217,75,222,121,217,99,239,154,26,134,7,183,36},{10,216,82,223},{19,219,77,216},{59,203,68,196,74,252},{60,176,71,203,87},{30,164,64,219,114,239,117,229,113,9,145,21,187,59,175,58},26,{11,172,78,217,73,242},{},{15,171,95,219,69,211,72,224,111,19,128},{25,163,94,192,68,208,43},6,0.25,0.22,54,0.05,0.2,{19,172,55,210,92,206,115,227,119,233,153},{27,167,43,217,82,216},{44,174,53,214},{61,181,43,223,76},2.1},C={197,245,247,232,201,253,198,246,220,247,199,245,220,246,213,247,249,203,246,253,246,213,245,235,213,244,250,246,199,244,197,244,213,243,253,242,213,245,235,213,247,213,241,213,241,213,241,250,243,242,197,244,213,240,253,255,213,254,235,213,253,213,252,213,251,250,244,242,197,244,213,250,213,247,242,197,244,213,249,213,241,242,197,244,213,248,254,242,197,244,213,231,220,246,242,197,244,213,230,213,229,242,197,244,213,228,220,245,242,220,244,197,244,213,227,250,245,198,246,220,243,197,244,197,245,213,247,213,226,250,243,198,246,220,242,197,244,253,255,213,254,235,213,225,213,224,213,239,250,244,253,255,213,254,235,213,238,213,237,213,236,250,244,213,235,250,243,198,246,253,246,213,245,235,213,244,250,246,199,243,197,243,213,243,253,242,213,245,235,213,241,213,234,213,247,213,233,210,250,243,242,197,243,213,232,253,242,213,215,235,213,214,213,214,250,245,242,197,243,213,240,197,245,242,197,243,213,249,213,241,242,197,243,213,228,197,244,242,220,244,197,243,213,213,250,245,198,246,253,246,213,245,235,213,212,250,246,199,242,197,242,213,232,253,242,213,215,235,213,238,213,211,250,245,242,197,242,213,243,253,242,213,245,235,213,247,213,251,210,213,241,213,210,250,243,242,197,242,213,250,213,247,242,197,242,213,209,253,208,213,209,235,213,223,235,242,197,242,213,222,213,221,242,197,242,213,220,197,245,242,197,242,213,219,253,208,213,219,235,213,218,235,242,197,242,213,217,253,216,213,199,235,197,247,250,246,242,197,242,213,198,213,247,242,197,242,213,228,197,244,242,253,246,213,245,235,213,212,250,246,199,241,197,241,213,232,253,242,213,215,235,213,238,213,197,250,245,242,197,241,213,243,253,242,213,245,235,213,247,213,251,210,213,241,213,238,250,243,242,197,241,213,250,213,247,242,197,241,213,209,253,208,213,209,235,213,196,235,242,197,241,213,222,213,221,242,197,241,213,220,220,241,242,197,241,213,219,253,208,213,219,235,213,218,235,242,197,241,213,217,197,246,247,232,201,279,198,246,213,195,242,197,241,213,198,213,247,242,197,241,213,228,197,244,242,253,246,213,245,235,213,244,250,246,199,240,197,240,213,194,253,193,213,245,235,213,241,213,247,250,245,242,197,240,213,232,253,242,213,245,235,213,241,213,238,213,247,213,192,210,250,243,242,197,240,213,243,253,242,213,245,235,213,247,213,197,210,213,241,213,213,250,243,242,197,240,213,240,197,245,242,197,240,213,250,213,207,242,197,240,213,249,213,241,242,197,240,213,228,197,244,242,220,244,197,240,213,247,250,245,198,246,220,240,197,244,213,206,183,247,213,243,253,242,213,245,235,213,247,213,241,213,241,213,205,250,243,242,247,213,250,213,204,242,250,244,198,246,220,240,197,242,213,203,183,247,213,198,213,241,242,250,244,198,246,220,240,197,241,213,203,183,247,213,198,213,241,242,250,244,198,246,220,240,197,240,213,213,183,247,213,243,253,242,213,245,235,213,241,213,241,213,241,213,213,250,243,242,253,208,213,202,235,213,201,235,250,243,198,246,253,200,213,183,235,213,182,182,246,250,245,198,246,255,247},P={{K={{73,241,117,27,155,24},0.18,{72,251,115,229},{73,215,99,236,202},{115,241,124},1,0,{98,246,109,238,155,1,133,20,182,43,146,79,213,69,209,105,241,117,27,155,15,154},0.14,{118,252,104,243,170,7,141,13,169,33,169,77,211,67,199,98},{87,251,98,227},{64,254,126,232,121},0.22},C={220,247,213,247,235,232,201,251,255,247,216,251,220,246,220,247,213,246,183,247,213,245,253,244,213,243,235,213,242,213,241,213,241,213,241,250,243,242,247,213,240,213,242,242,250,244,198,246,220,246,220,245,213,255,183,247,213,254,213,242,242,250,244,198,246,220,246,220,244,213,255,183,247,213,254,213,242,242,250,244,198,246,253,253,213,252,235,213,251,182,246,250,245,198,246,255,247},P={{K={{93,245,116,10,135,3,154}},C={220,247,247,213,247,235,225,250,246,198,246,255,247},P={},U={{0,0}},nParams=0}},U={{1,3},{0,7},{1,5},{1,6}},nParams=0}},U={{1,45},{1,53},{1,51},{1,2},{1,3},{1,4},{1,47},{1,6}},nParams=3},{K={{76,227,98,12,188,2,147,47,165,28,198,70,200},{95,255,125,18},{86,253,124,243,146,44,144,40,167,37,175,9},{72,252,127,226,144},{77,251,120,235,141,25,136,48},{95,247,127,236,150,4,156,58,134,34,183,82,198,64,207,121},{74,210,100,233,201},{70,229,97,232,179,21,140,18,189,59},{121},{123}},C={197,247,213,247,235,253,246,213,247,235,213,245,235,207,247,232,201,213,198,246,197,247,213,247,235,253,246,213,247,235,213,244,235,207,201,186,254,203,247,197,247,213,243,235,203,246,220,245,213,242,235,203,244,220,245,213,243,253,241,213,240,235,220,244,213,255,235,220,244,213,254,235,250,245,242,216,186,255,247},P={},U={{1,69},{1,70},{1,55},{1,71}},nParams=1},{K={{76,227,98,12,188,2,147,47,165,28,198,70,200},{95,255,125,18},{86,253,124,243,146,35,138,42,182,39,164,86,219},{72,252,127,226,144},{77,251,120,235,141,25,136,48},{105,250,126,232,137,1,137,60,179},{92,227,127,246,158,28,157,35,182,35,160,78,210},{118,254,107,242,140,28,152,21,139,38,188,88},{96,250,124,233,145,1,159,7,138,57,189,91},{79,248,100,239},{64,246,112,229,143},{124},0,{75,252,108},{126},{125,219,127,224,54},{79,210,120,227,74,26,149,25,132,44}},C={220,247,232,201,254,255,247,216,254,197,247,213,247,235,253,246,213,247,235,213,245,235,224,247,201,221,198,246,197,247,213,247,235,253,246,213,247,235,213,244,235,224,201,199,255,247,216,199,197,247,213,243,235,220,246,230,199,246,253,242,213,241,235,213,240,235,199,245,220,245,213,255,235,199,244,208,253,254,213,253,235,220,244,213,252,235,197,246,213,252,235,249,213,251,253,254,213,250,235,197,245,213,252,235,197,244,213,252,235,230,213,251,180,245,-1,231,246,199,243,208,253,254,213,253,235,220,244,213,249,235,197,246,213,249,235,249,213,251,253,254,213,250,235,197,245,213,249,235,197,244,213,249,235,230,213,251,180,245,-1,231,246,199,242,220,245,213,243,253,248,213,231,235,197,243,197,242,250,245,242,255,247},P={},U={{1,69},{1,70},{1,55},{1,71}},nParams=1},{K={{76,227,98,12,188,2,147,47,165,28,198,70,200},{95,255,125,18},{86,253,124,243,146,44,144,40,167,37,175,9},{72,252,127,226,144}},C={197,247,213,247,235,253,246,213,247,235,213,245,235,207,247,232,201,213,198,246,197,247,213,247,235,253,246,213,247,235,213,244,235,207,201,222,194,203,247,216,222,255,247},P={},U={{1,69}},nParams=1},{K={{112,224,102,23,135,31},{76,248,123,22,148,1,129},{107,241,104,236,155}},C={197,247,220,247,207,201,252,255,247,216,252,197,247,203,247,253,247,220,246,180,246,244,199,244,199,245,199,246,236,246,245,244,239,243,239,242,197,246,197,245,197,244,180,245,245,199,242,199,243,197,243,199,244,197,243,221,224,201,176,197,242,213,246,197,242,197,247,207,242,216,215,253,245,182,246,250,246,198,246,255,247},P={{K={{94,226,104,11,133,56,145,59,191,59,207,87,223,65,245,113,240},1,0.18,0},C={220,247,213,247,213,246,242,220,246,220,247,213,245,183,247,213,247,213,244,242,250,244,198,246,255,247},P={},U={{1,0},{0,2}},nParams=0}},U={{1,80},{1,79},{1,6}},nParams=1},{K={{112,224,102,23,135,31},{73,244,124,62,130,25,150,50,176,60,180,82},{89,243,122,229,163,28,132,50,160,58,160,74,202,72,254,109},0.02,0.6,0.16,{93,247,110,239,156,0,134,21,185,42,145,78,210,68,210,104,238,116,24,154,8,155},{116,242,118,241,191,28,134,14,170,124},{98,247,99,233,143,71},{68,235,127,234,172,50,174},140,180,178,{96,244,122,239,68,16,130,20,170,22,164,42,214,85},{102,253,97,229,117,31,179,9,173},0,1},C={253,247,220,247,180,246,244,199,244,199,245,199,246,236,246,245,244,239,243,239,242,197,246,197,245,197,244,180,245,245,199,242,199,243,197,243,199,244,197,243,221,224,201,61,197,242,197,247,207,199,241,197,242,247,213,246,235,225,213,245,197,241,247,201,178,198,246,213,244,247,232,201,186,198,246,213,243,250,244,198,246,220,246,197,242,213,242,183,247,213,241,197,241,247,201,147,198,246,213,244,247,232,201,155,198,246,213,243,242,247,213,240,197,241,247,201,142,198,246,220,245,247,232,201,123,198,246,253,255,213,254,235,213,253,213,252,213,251,250,244,242,250,244,198,246,197,242,247,213,250,235,225,213,249,250,245,199,240,197,240,201,51,220,246,197,240,213,242,183,247,213,241,197,241,247,201,66,198,246,213,248,247,232,201,74,198,246,213,231,242,250,244,198,246,216,51,239,241,239,240,216,230,255,247},P={},U={{1,82},{1,6},{1,47}},nParams=1},{K={{80,254,116,10,148,2,128,63},{116,244,127},{79,247,113,244,181,27,145,40,188,36},{79,250,112,228},{72,208,98,239,203},0.9,0,36,{113,247,124,239,137,29,132,12},0.05,{97,251,114,227,152,4,130,17,181,54,138,47,219,65,215,47},{103,244,126,230,114,68},{67,238,124,231,83,63,173},44,100,96,{107,193,116,229,98,14,156,31,143,60,155,52,220,90,216,82,248,98,226,144,22,149},0.6,{127,199,97,228},{120,198,98,229,75,16,154,2,150,104},140,180,178,{118,200,112,225},{116,198,106,251},{117,198,84,255,111,232,190,28,134,5},{103,207,89,236,92,239,135,17},11,{119,195,81,254,116,250,172,31,151,1,139,59,177,37,219},{98,200,92,239,74,200,108,30,137,11,177,54,164,53},{116,203,75,232,118,248},{104,206,84,248,122,255},9,1,0.55,{122,193,75,204,125},{115,213,70,199},{127,214,88,202,108,244,74,30,132},3,18,0.5,{24,240,94,195,123,237},2,{48,218,80,197,69},{44,210,64,207,83,236},{11,210,65,216,71,219,101,243,138,26,130,82,153,61,161,92,221},{4,209,91,194,70,249,101}},C={253,247,213,246,235,213,245,250,246,199,244,197,244,213,244,253,243,213,246,235,213,242,213,241,213,241,213,240,250,243,242,197,244,213,255,253,243,213,246,235,213,254,213,241,197,246,213,241,250,243,242,197,244,213,253,253,252,213,251,235,213,250,213,249,213,248,250,244,242,197,244,213,231,213,230,242,197,244,213,229,197,247,242,197,244,213,228,253,252,213,251,235,213,227,213,226,213,225,250,244,242,197,244,213,224,253,239,213,224,235,213,238,235,242,197,244,213,237,213,236,242,197,244,213,235,213,241,242,197,244,213,234,253,239,213,234,235,213,233,235,242,197,244,213,232,220,247,242,220,246,197,244,213,215,250,245,198,246,220,245,197,244,220,244,213,214,213,213,250,243,198,246,253,247,213,246,235,213,212,250,246,199,243,197,243,213,211,213,210,242,197,243,213,244,253,243,213,246,235,213,241,213,209,213,241,213,208,250,243,242,197,243,213,255,253,243,213,246,235,213,241,213,241,213,223,213,215,210,250,243,242,197,243,213,253,220,244,242,197,243,213,231,213,214,242,197,243,213,235,213,241,242,197,243,213,222,197,244,213,222,235,213,214,249,242,197,243,213,232,197,244,242,220,246,197,243,213,221,250,245,198,246,253,220,213,219,235,220,243,197,244,250,245,198,246,220,242,197,244,220,241,213,230,250,244,198,246,197,244,213,218,235,247,213,217,235,225,182,246,250,245,198,246,197,244,255,246},P={{K={},C={220,247,220,246,250,246,198,246,220,245,220,244,250,246,198,246,255,247},P={},U={{0,7},{1,2},{0,8},{1,3}},nParams=0}},U={{1,73},{1,2},{1,3},{1,45},{1,82},{1,9},{1,44},{1,81},{1,83}},nParams=3},{K={{80,254,116,10,148,2,128,63},{116,244,127},{93,224,104,237,146},{79,250,112,228},{72,208,98,239,203},0,3,16,{113,247,124,239,137,29,132,12},6,{97,251,114,227,152,4,130,17,181,54,138,47,219,65,215,47},{102,244,96,237,101,5,189,12,166,54,154,40,192,74,202},{117,253,97,239,111,12},2,{115,251,109,248,79,27,147,13,179},1,12,28,{105,195,122,251,96,12,154,25,141,62,133,58,222,88,222,84,250,96,236,110,20,151},{120,198,98,229},{121,193,99,230,74,239,155,1,151,111},{104,202,114,231},{106,200,104,249},{119,200,106,253,109,238,184,30,132,59},{101,205,103,226,94,237,129,23},14,{103,207,89,236,87,199,145,29,140,12,180,53,169,74},{120,206,68,237}},C={253,247,213,246,235,213,245,250,246,199,244,197,244,213,244,253,243,213,246,235,213,242,213,241,213,242,213,240,250,243,242,197,244,213,255,253,243,213,246,235,213,242,213,242,197,245,213,254,250,243,242,197,244,213,253,220,247,242,197,244,213,252,213,242,242,197,244,213,251,197,247,242,220,246,197,244,213,250,250,245,198,246,253,247,213,246,235,213,249,250,246,199,243,197,243,213,244,253,243,213,246,235,213,248,213,231,210,213,242,213,230,250,243,242,197,243,213,255,253,243,213,246,235,213,242,213,231,197,245,213,242,250,243,242,197,243,213,229,213,248,242,197,243,213,228,197,246,242,197,243,213,227,220,245,242,197,243,213,226,253,225,213,226,235,213,224,235,242,197,243,213,239,213,238,242,197,243,213,237,253,225,213,237,235,213,236,235,242,197,243,213,251,197,247,242,197,243,255,246},P={},U={{1,45},{1,2},{1,46}},nParams=3},{K={{80,254,116,10,148,2,128,63},{116,244,127},{93,224,104,237,146},{79,250,112,228},{72,208,98,239,203},1,0,38,{113,247,124,239,137,29,132,12},{96,248,115,236,153,7,131,22,180,53,139,80,218,66,214,40},{96,245,125,231,141,69},{66,233,125,228,82,48,172},24,28,36,{106,254,117,230,99,9,157,28,142,51,154,55,221,93,217,81,249,125,227,147,23,146},0.6,{104,206,106,235,99,15,167,2,152,60,128,46,198,80,192},{123,195,107,245,105,10},9,{121,193,99,230,69,225,149,11,137},120,12,{100,194,102,225},{101,205,103,226,78,235,151,29,155,83},{116,198,78,227},{118,196,84,245},{115,196,86,241,113,234},{97,201,91,238,66,225,133,19},{98,200,92,239,74,200,108,30,137,11,177,54,164,53},{123,203,67,232},{94,221,73,240,91,237,100,10,149,19},30,14,100,0.5,7,{113,251},{112,240,107},110,125,{5,214,68,207,127,248,78,236,150,21},{17,211,86,192,107},46,56,80,200,160,75,82,88,0.25,{11,173,85,214,111,201,101,253,113,63,155,3,141,60,128,32,254,88,202,81,234},{27,140,111,199,88,206,115,234},20,22,10,2,{26,164,49,205,91,228,120,243,106,236},{23,164,44,215,85,196,106},{6,169,55,233,69,201,107,243}},C={253,247,213,246,235,213,245,250,246,199,242,197,242,213,244,253,243,213,246,235,213,242,213,241,213,241,213,240,250,243,242,197,242,213,255,253,243,213,246,235,213,241,213,241,197,246,213,241,250,243,242,197,242,213,254,253,253,213,252,235,213,251,213,250,213,249,250,244,242,197,242,213,248,213,231,242,197,242,213,230,213,241,242,197,242,213,229,197,247,242,220,247,197,242,213,228,250,245,198,246,253,247,213,246,235,213,227,250,246,199,241,197,241,213,244,253,243,213,246,235,213,242,213,226,210,213,242,213,241,250,243,242,197,241,213,255,253,243,213,246,235,213,241,213,225,213,241,213,241,250,243,242,197,241,213,248,213,242,242,197,241,213,224,197,245,242,197,241,213,239,220,246,242,197,241,213,238,253,237,213,238,235,213,236,235,242,197,241,213,235,213,225,242,197,241,213,234,253,237,213,234,235,213,233,235,242,197,241,213,229,197,242,242,253,247,213,246,235,213,227,250,246,199,240,197,240,213,244,253,243,213,232,235,213,215,213,214,250,245,242,197,240,213,255,253,243,213,246,235,213,242,213,213,210,213,212,213,211,210,250,243,242,197,240,213,248,213,242,242,197,240,213,224,197,244,247,201,493,198,246,213,210,247,232,201,469,198,246,213,209,242,197,240,213,239,197,244,247,201,455,198,246,220,245,247,232,201,436,198,246,253,253,213,252,235,213,208,213,226,213,223,250,244,242,197,240,213,238,253,237,213,238,235,213,222,235,242,197,240,213,235,213,228,242,197,240,213,234,253,237,213,234,235,213,221,235,242,197,240,213,229,197,242,242,253,247,213,246,235,213,245,250,246,199,255,197,255,213,244,253,243,213,246,235,213,241,213,220,213,241,213,251,250,243,242,197,255,213,255,253,243,213,246,235,213,242,213,219,210,213,212,213,225,210,250,243,242,197,255,213,254,197,244,247,201,334,198,246,253,253,213,252,235,213,218,213,217,213,216,250,244,247,232,201,315,198,246,253,253,213,252,235,213,199,213,198,213,197,250,244,242,197,255,213,230,213,241,242,197,255,213,229,197,242,242,220,247,197,255,213,225,250,245,198,246,220,244,197,255,220,245,213,242,197,244,247,201,257,198,246,213,196,247,232,201,265,198,246,213,231,250,243,198,246,197,255,247,213,195,235,225,213,194,250,245,199,254,220,243,197,255,213,242,250,245,199,253,253,247,213,246,235,213,245,250,246,199,252,197,252,213,244,253,243,213,246,235,213,241,213,193,213,241,213,193,250,243,242,197,252,213,255,197,244,247,201,675,198,246,253,243,213,246,235,213,242,213,192,210,213,212,213,207,210,250,243,247,232,201,669,198,246,253,243,213,246,235,213,241,213,206,213,212,213,207,210,250,243,242,197,252,213,254,253,253,213,246,235,213,242,213,242,213,242,250,244,242,197,252,213,230,213,241,242,197,252,213,229,197,255,242,220,247,197,252,213,207,250,245,198,246,197,244,199,251,182,246,199,250,197,255,213,205,235,247,213,204,235,225,182,245,250,245,198,246,197,242,213,205,235,247,213,204,235,225,182,244,250,245,198,246,183,247,213,203,182,243,242,255,246},P={{K={{77,245,127,10},{85,223},{84,212,79},{72,246,114,245,187,0,138,50,166,120},{94,251,103,237,139,67},{120,231,99,238,168,54,170},110,120,125,80,200,160,75,82,88,{125,219,127,224,54},{71,197,96},1,22,0.5,10,0,2,0.18,{115,201,124,253,106,246,148,7,135,4,148,33,169,83,193,25},0.22,{99,197,82,241,123,239,146,26},{113,197,87,244},{112,205,80,243,127,239,172,2,148,8,190},{116,204,71,240},{99,220,68,242,96,250,96,10,138,8,190,45},0.25,0.6,0.08,{104,209,72,204,114},1.08,{73,213,88,201},{90,208,64,194,99}},C={220,247,213,247,197,247,247,201,250,198,246,213,246,247,232,201,226,198,246,213,245,242,220,247,213,244,197,247,247,201,212,198,246,220,246,247,232,201,193,198,246,253,243,213,242,235,213,241,213,240,213,255,250,244,242,197,247,247,201,188,198,246,253,243,213,242,235,213,254,213,253,213,252,250,244,247,232,201,169,198,246,253,243,213,242,235,213,251,213,250,213,249,250,244,199,245,197,247,247,201,143,198,246,253,248,213,231,235,213,230,213,229,210,213,228,213,227,210,250,243,247,232,201,121,198,246,253,248,213,231,235,213,226,213,225,213,228,213,227,210,250,243,199,244,197,246,201,499,220,245,220,244,213,224,183,247,213,239,197,245,242,250,244,198,246,220,245,220,243,213,238,183,247,213,237,197,244,242,253,236,213,235,235,213,234,235,250,243,198,246,220,242,201,19,220,245,220,242,213,224,183,247,213,233,197,247,247,201,34,198,246,213,232,247,232,201,42,198,246,213,215,242,250,244,198,246,216,19,220,245,220,241,213,214,183,247,213,213,213,212,242,250,244,198,246,253,211,213,210,235,213,214,182,246,250,245,198,246,216,485,220,244,213,239,197,245,242,220,243,213,237,197,244,242,255,247},P={{K={0.16,{73,242,105,19,147},1,{89,253,127,236},{88,245,120,235,151,23,180,42,172,32,166},{92,244,111,232}},C={220,247,220,246,213,247,183,247,213,246,213,245,242,253,244,213,243,235,213,242,235,250,243,198,246,255,247},P={},U={{0,2},{0,6}},nParams=0}},U={{1,7},{0,2},{0,5},{1,8},{1,11},{1,9},{1,10}},nParams=2},{K={{76,227,98,12,188,2,147,47,165,28,198,70,200},{95,255,125,18},{86,253,124,243,146,44,144,40,167,37,175,9},{72,252,127,226,144},1.05,0.92},C={197,247,213,247,235,253,246,213,247,235,213,245,235,207,247,232,201,213,198,246,197,247,213,247,235,253,246,213,247,235,213,244,235,207,201,162,220,247,232,203,247,220,246,220,247,254,250,245,198,246,220,245,220,244,220,247,247,201,200,198,246,213,243,247,232,201,176,198,246,213,242,250,245,198,246,220,243,220,247,250,246,198,246,216,162,255,247},P={},U={{1,12},{1,13},{0,6},{0,7},{1,4}},nParams=1},{K={{76,227,98,12,188,2,147,47,165,28,198,70,200},{95,255,125,18},{86,253,124,243,146,44,144,40,167,37,175,9},{72,252,127,226,144},0.12,{92,244,111,232,157,3,135,42,184,41,144,73,211,71,211,103,239,119,25,157,9,152},0.45,{84,246,125,238},{69,253,99,231,132},0.14},C={197,247,213,247,235,253,246,213,247,235,213,245,235,207,247,232,201,213,198,246,197,247,213,247,235,253,246,213,247,235,213,244,235,207,201,179,220,247,220,246,213,243,183,247,213,242,213,241,242,250,244,198,246,253,240,213,255,235,213,254,182,246,250,245,198,246,216,179,255,247},P={{K={0.18,{88,240,107,20,145,31,139,46,188,45,148,69,207,75,239,99,235,115,29,129,5,164},0.6},C={220,247,220,246,213,247,183,247,213,246,213,245,242,250,244,198,246,255,247},P={},U={{0,0},{0,1}},nParams=0}},U={{0,5},{1,5}},nParams=1},{K={},C={197,247,203,247,220,246,197,247,254,250,245,198,246,255,247},P={},U={{1,12},{1,13}},nParams=1}},U={{1,2},{1,47},{1,45},{1,3},{1,5},{1,6},{1,7},{1,44}},nParams=5},{K={{80,254,116,10,148,2,128,63},{116,244,127},{79,247,113,244,181,27,145,40,188,36},{79,250,112,228},{72,208,98,239,203},1,0,36,{113,247,124,239,137,29,132,12},{96,248,115,236,153,7,131,22,180,53,139,80,218,66,214,40},{96,245,125,231,141,69},{66,233,125,228,82,48,172},44,100,96,{106,254,117,230,99,9,157,28,142,51,154,55,221,93,217,81,249,125,227,147,23,146},0.3,{126,196,96,251},{127,199,97,228,68,17,153,3,145,105},{106,204,116,229},{104,202,110,255},{105,202,104,251,107,236,186,0,138,57},{123,195,101,224,88,235,131,21},12,{115,199,109,242,104,246,168,27,147,5,135,39,189,89,223},{98,200,82,242,96,241},9,0.5,52,118,112,86,82,90,{118,221,92,211,114,204,112,8,135,5,143,105,140,42,212,87,192},{127,220,68,207,125,236,114}},C={253,247,213,246,235,213,245,250,246,199,243,197,243,213,244,253,243,213,246,235,213,242,213,241,213,241,213,240,250,243,242,197,243,213,255,253,243,213,246,235,213,241,213,241,197,246,213,241,250,243,242,197,243,213,254,253,253,213,252,235,213,251,213,250,213,249,250,244,242,197,243,213,248,213,231,242,197,243,213,230,197,245,242,197,243,213,229,220,247,242,197,243,213,228,253,227,213,228,235,213,226,235,242,197,243,213,225,213,224,242,197,243,213,239,213,241,242,197,243,213,238,197,247,242,220,246,197,243,213,237,250,245,198,246,220,245,197,243,220,244,213,242,213,236,250,243,198,246,220,243,197,243,253,253,213,252,235,213,235,213,234,213,233,250,244,253,253,213,252,235,213,240,213,232,213,215,250,244,213,214,250,243,198,246,220,242,197,243,220,241,213,231,250,244,198,246,197,243,213,213,235,247,213,212,235,225,197,244,250,245,198,246,197,243,255,246},P={},U={{1,47},{1,2},{1,3},{1,45},{1,4},{1,9},{1,44}},nParams=4},{K={{80,254,116,10,148,2,128,63},{116,244,127},{79,247,113,244,181,27,145,40,188,36},{79,250,112,228},{72,208,98,239,203},1,0,32,{113,247,124,239,137,29,132,12},{96,248,115,236,153,7,131,22,180,53,139,80,218,66,214,40},{96,245,125,231,141,69},{66,233,125,228,82,48,172},34,40,49,{106,254,117,230,99,9,157,28,142,51,154,55,221,93,217,81,249,125,227,147,23,146},0.55,{126,196,96,251},{},{110,204,104,245,109,13,165,4,158,62,130,32,184,82,194},{121,193,99,230,81,193,155,7,130,50,190,47,175,76},{107,203,105,254},{99,195,123,224},{96,198,108,240,98,247},8,0.7,{117,216,64,245,106},{82,217,77,244,95,225,152,6,137,23},6,14,0.5,3,0.25,{110,212,80,235,90,236,102,30,158},70,28,{105,209,83,214,90,255,107,17,135,95},{120,218,66,215},{120,217,89,204,122,255},{20,210,86,209,79,250,112,228},11,16,26,{166,59,136},{17,217,75,222,117,234,110,232,142,4,138,16,188,62,164,71},0.35,{0,209,65,196,66,247,83,231,147,18},{5,208,67,222,65,217,103,253,116,24,128,84,159,63,163,34,211},{10,175,89,192,64,255,103}},C={253,247,213,246,235,213,245,250,246,199,243,197,243,213,244,253,243,213,246,235,213,242,213,241,213,241,213,240,250,243,242,197,243,213,255,253,243,213,246,235,213,241,213,241,197,246,213,241,250,243,242,197,243,213,254,253,253,213,252,235,213,251,213,250,213,249,250,244,242,197,243,213,248,213,231,242,197,243,213,230,213,229,242,197,243,213,228,213,241,242,197,243,213,227,253,226,213,227,235,213,225,235,242,197,243,213,224,220,247,242,220,246,197,243,213,239,250,245,198,246,220,245,197,243,220,244,213,242,213,238,250,243,198,246,253,247,213,246,235,213,237,250,246,199,242,197,242,213,244,253,243,213,236,235,213,235,213,235,250,245,242,197,242,213,255,253,243,213,246,235,213,241,213,234,213,233,213,232,210,250,243,242,197,242,213,254,220,244,242,197,242,213,248,213,215,242,197,242,213,228,213,241,242,197,242,213,224,197,243,242,220,246,197,242,213,232,250,245,198,246,253,247,213,246,235,213,214,250,246,199,241,197,241,213,244,253,243,213,246,235,213,242,213,213,210,213,242,213,241,250,243,242,197,241,213,255,253,243,213,246,235,213,241,213,212,213,241,213,241,250,243,242,197,241,213,248,213,242,242,197,241,213,230,197,247,242,197,241,213,211,220,243,242,197,241,213,210,253,226,213,210,235,213,209,235,242,197,241,213,208,213,223,242,197,241,213,227,253,226,213,227,235,213,225,235,242,197,241,213,224,197,243,242,253,247,213,246,235,213,214,250,246,199,240,197,240,213,244,253,243,213,236,235,213,222,213,222,250,245,242,197,240,213,255,253,243,213,246,235,213,242,213,221,210,213,233,213,239,210,250,243,242,197,240,213,248,213,242,242,197,240,213,230,213,220,242,197,240,213,211,220,242,242,197,240,213,219,213,218,242,197,240,213,210,253,226,213,210,235,213,217,235,242,197,240,213,208,213,222,242,197,240,213,224,197,243,242,220,241,197,243,220,240,213,231,250,244,198,246,197,243,213,216,235,247,213,199,235,225,182,246,250,245,198,246,255,247},P={{K={{252,18,180,151,117,237},{255,38,186,154,127,224,1,229,82,105}},C={220,247,220,246,220,245,250,245,198,246,220,244,213,247,213,246,220,245,212,220,243,250,244,198,246,255,247},P={},U={{0,8},{1,2},{1,3},{0,9},{0,3}},nParams=0}},U={{1,76},{1,2},{1,3},{1,45},{1,47},{1,46},{1,9},{1,44},{1,27},{1,54}},nParams=4},{K={},C={182,246,255,246},P={{K={{252,26,152,150,118,209},{58,116,191,205,31,251,111,190,71,214},{59,119,190,50,30,249,121,181,69,195},{95,252,102,238,138,92},{123,230,100,239,171,55,165},150,160,165},C={220,247,213,247,220,246,197,247,247,201,248,198,246,213,246,247,232,201,224,198,246,213,245,212,197,247,247,201,214,198,246,220,245,247,232,201,195,198,246,253,244,213,243,235,213,242,213,241,213,240,250,244,250,244,198,246,255,247},P={},U={{0,0},{1,0},{0,1}},nParams=1}},U={{1,54},{1,45}},nParams=1},{K={{111,198,98,12,129,5,128,59,189,28,207,115,195,69,249,126,236},{76,116,150,253,17,246,80,188,76,229,39,144,21}},C={220,247,213,247,197,247,242,197,247,201,228,220,246,250,247,198,246,216,238,220,245,250,247,198,246,220,244,213,246,250,246,197,247,250,246,198,246,255,247},P={},U={{1,16},{1,28},{1,29},{1,89}},nParams=1},{K={{122,229,117,13,154,30,183,42,148,38,222,84,193,65},{252,41,176,153,94,244,3,197,126,174,103,140}},C={220,247,213,247,197,247,242,197,247,201,228,220,246,250,247,198,246,216,238,220,245,250,247,198,246,220,244,213,246,250,246,197,247,250,246,198,246,255,247},P={},U={{1,16},{1,32},{1,33},{1,89}},nParams=1},{K={{120,254,115,23,180,10,136,31,191,41,221,90,200},{91,255,124,22,183,43,175}},C={220,247,213,247,197,247,242,197,247,201,228,220,246,250,247,198,246,216,238,220,245,250,247,198,246,220,244,213,246,250,246,197,247,250,246,198,246,255,247},P={},U={{1,16},{1,36},{1,37},{1,89}},nParams=1},{K={{111,255,110,26,190,5,143,54,148,38,222,84,193,65},{242,8,147,152,95,215,2,245,104}},C={220,247,213,247,197,247,242,197,247,201,228,220,246,250,247,198,246,216,238,220,245,250,247,198,246,220,244,213,246,250,246,197,247,250,246,198,246,255,247},P={},U={{1,16},{1,42},{1,43},{1,89}},nParams=1},{K={{241,55,149,150,124,222},{255,38,186,154,105,218,12,250,94,172,124,128,75,173,42,250,13,140,159,123,249}},C={220,247,250,247,198,246,220,246,213,247,213,246,220,245,250,244,198,246,255,247},P={},U={{1,34},{1,54},{1,45}},nParams=0},{K={{80,254,116,10,148,2,128,63},{116,244,127},{93,224,104,237,146},{79,250,112,228},{72,208,98,239,203},1,0,38,{113,247,124,239,137,29,132,12},{96,248,115,236,153,7,131,22,180,53,139,80,218,66,214,40},{96,245,125,231,141,69},{66,233,125,228,82,48,172},24,28,36,{106,254,117,230,99,9,157,28,142,51,154,55,221,93,217,81,249,125,227,147,23,146},0.6,{104,206,106,235,99,15,167,2,152,60,128,46,198,80,192},{123,195,107,245,105,10},9,{121,193,99,230,69,225,149,11,137},12,{123,195,101,224},{100,194,102,225,79,236,150,30,154,108},{119,199,113,226},{119,199,85,250},{116,197,85,240,110,235},{96,206,90,237,67,238,132,16},{97,201,91,238,73,201,147,31,138,10,182,55,167,52},{122,200,66,239},{99,203,93,232,81,255,117,12,128,8},0.35,0.63,0.5,14,44,100,96,{75,217,94,208,105,251,103,231},{14,214,67,192},{6,215,91,206,124,249,73,237,149,20},11,8,{9,212,71,218,69,213,123,241,136,28,132,80,155,35,175,94,223},{6,211,93,196,68,251,123}},C={253,247,213,246,235,213,245,250,246,199,244,197,244,213,244,253,243,213,246,235,213,242,213,241,213,241,213,240,250,243,242,197,244,213,255,253,243,213,246,235,213,241,213,241,197,246,213,241,250,243,242,197,244,213,254,253,253,213,252,235,213,251,213,250,213,249,250,244,242,197,244,213,248,213,231,242,197,244,213,230,213,241,242,197,244,213,229,220,247,242,220,246,197,244,213,228,250,245,198,246,253,247,213,246,235,213,227,250,246,199,243,197,243,213,244,253,243,213,246,235,213,231,213,241,213,242,213,241,250,243,242,197,243,213,255,253,243,213,246,235,213,241,213,226,213,241,213,241,250,243,242,197,243,213,248,213,242,242,197,243,213,225,197,247,242,197,243,213,224,220,245,242,197,243,213,239,253,238,213,239,235,213,237,235,242,197,243,213,236,213,226,242,197,243,213,235,253,238,213,235,235,213,234,235,242,197,243,213,229,197,244,242,253,247,213,246,235,213,233,250,246,199,242,197,242,213,244,253,243,213,246,235,213,232,213,241,213,241,213,250,250,243,242,197,242,213,255,253,243,213,246,235,213,215,213,241,213,214,213,213,210,250,243,242,197,242,213,254,253,253,213,252,235,213,212,213,211,213,210,250,244,242,197,242,213,248,213,232,242,197,242,213,225,253,209,220,244,197,245,235,213,208,235,250,246,242,197,242,213,224,253,253,213,246,235,213,242,213,242,213,242,250,244,242,197,242,213,239,253,238,213,239,235,213,223,235,242,197,242,213,236,213,222,242,197,242,213,230,213,241,242,197,242,213,229,197,244,242,220,246,197,242,213,221,250,245,198,246,220,243,197,242,220,242,213,242,213,214,250,243,199,241,220,241,197,242,220,240,213,232,250,244,198,246,194,199,240,197,242,213,220,235,247,213,219,235,225,182,246,250,245,198,246,255,247},P={{K={{77,245,127,10},{242,58,131,153,122,228,0,227,89,175,76,190,71,168,41,61,164,47},0.15,{72,225,107,239,139,31,135,47,177,37,161,64},0.1,{74,253,101,224,145,31,141,44,165},2,{105,249,126,240,136,49,143,6,185,33},{98,247,97,232,152,23,159}},C={220,247,201,255,255,247,216,255,254,203,247,220,246,213,247,213,246,242,220,245,220,244,213,245,183,247,213,244,213,243,242,247,213,242,213,241,242,250,244,198,246,221,199,247,220,243,213,240,235,247,213,255,235,225,182,246,180,245,246,199,247,255,247},P={{K={{82,245,126,61,154,8,134},{78,244,112,11},{111,253,122,244,133,7,139,59},{82,242,103,228},0.2,{74,231,109,237,137,1,137,45,179,35,167,66},0.5,{116,255,103,230,151,29,143,18,171},1,1.1,{197,22,152,97,114,195,10,210,90,183,103,218},{4,121,148,27,32},{97,245,96,233,110,22,129,3,190,32}},C={197,246,201,255,255,247,216,255,194,203,247,220,246,220,245,197,247,213,247,235,242,220,244,213,246,253,245,197,247,213,247,235,213,244,235,250,246,242,220,243,220,242,213,243,183,247,213,242,213,241,242,247,213,240,213,255,242,250,244,198,246,220,241,220,240,213,254,250,245,198,246,220,255,213,253,220,254,213,252,253,245,197,247,213,247,235,213,244,235,250,246,212,212,220,253,250,244,198,246,220,252,247,213,251,235,225,250,246,198,246,255,247},P={},U={{0,0},{0,5},{0,6},{0,1},{0,2},{0,3},{0,7},{0,8},{0,9},{0,10},{0,11},{1,0}},nParams=2}},U={{1,7},{1,5},{0,8},{1,6},{0,9},{0,3},{1,2},{0,10},{0,7},{0,11},{1,0},{0,5}},nParams=0}},U={{1,78},{1,2},{1,47},{1,18},{1,3},{1,45},{1,9},{1,44},{1,6},{1,1},{1,7},{1,54}},nParams=3},{K={{79,249,116,23,151,0,134},{73,242,105,19,147},0.95,{108,240,107,237,148},0.24,1,{90,248,120,233},{101,246,125,236,146,20,185,21,161,35,163},{99,249,108,237},0.16,{87,251,98,227},{64,254,126,232,121},0},C={197,247,201,195,220,247,213,247,254,242,220,246,213,246,213,245,242,253,244,182,246,250,246,198,246,220,245,220,246,213,243,183,247,213,246,213,242,242,253,241,213,240,235,213,255,235,250,243,198,246,216,158,253,244,182,245,250,246,199,246,220,245,220,246,213,254,183,247,213,246,213,245,242,250,244,198,246,253,253,213,252,235,197,246,247,201,172,198,246,213,254,247,232,201,148,198,246,213,251,182,244,250,245,198,246,255,247},P={{K={{94,226,104,11,133,56,145,59,191,59,207,87,223,65,245,113,240},1,0.2,0},C={220,247,213,247,213,246,242,220,246,220,247,213,245,183,247,213,247,213,244,242,250,244,198,246,255,247},P={},U={{0,0},{0,2}},nParams=0},{K={0.16,{93,227,103,10,134,57,150,58,188,58,176,86,220,64,242,112,243},1},C={220,247,220,246,213,247,183,247,213,246,213,245,242,250,244,198,246,255,247},P={},U={{0,2},{0,0}},nParams=0},{K={{79,249,116,23,151,0,134},{106,242,105,19,154}},C={220,247,213,247,194,242,253,246,182,246,250,246,198,246,255,247},P={{K={{94,226,104,11,133,56,145,59,191,59,207,87,223,65,245,113,240},0},C={220,247,213,247,213,246,242,255,247},P={},U={{0,0}},nParams=0}},U={{0,0}},nParams=0}},U={{1,55},{1,56},{1,6}},nParams=1},{K={{95,249,105,26,179,5,145,41,165,11,215,95,193,64},{89,254,102,25,159,31,137,31,187,40,172,88,201},{82,252,122,244,150,0,134,57},{114,246,125},{91,230,106,239,156},{80,244,97,230},{76,255,119,225},{117,211,103,232,206},1,0,{97,251,114,227,152,4,130,17,181,54,138,47,219,65,215,47},{103,244,126,230,114,68},{67,238,124,231,83,63,173},{100,252,119,224,101,11,159,18,176,49,152,49,219,95,219,111,247,127,225,149,17,144},{101,241,103,232,102,8,162,1,165,51,157,45,195,87,197},{114,214,120,233,97,3},100,{122,192,106,234,104,9},0.18,0.55,340,160,{127,201,110,253,127,235,150,30},0.5,170,80,18,20,26,101,14,1.5,0.3,30,38,16,21,90,0.9,0.22,{18,219,78,202,120},{7,215,69,202},{6,219,66,193,113,241,94,240,130,30,140},{6,218,81,194},44,28,32,40,0.2,102,8,4,255,103,{27,163,69,192,103,195,123,245,107},36,{5,173,71,194},{181,107,250,95,132,40,245,4,150,104,110,230,14,216,103,173,94,149,95,155,1},{7,175,57,204,108,201,113,251,121,177},{18,164,44,205},{18,163,55,210,80,197,93,249,97,224},{2,168,60,207,97,192,90,242},15,{12,170,62,201,108,234,78,240,119,233,147,16,130,23},{21,181,33,202},58,{178,69,213,41,161,39,192,34,159,108,136,248,9,250,84,177,65,221,81,179,26,251,37,139,102,123,237,14,242,116,164,69,176,90,136,44},{27,188,62,169,89,194},12,{10,176,52,183,120,196,92,235,121,227},0.46,0.02,52,60,65,75,0.25,{131,82,194,45,244,49},10,0.52,180,50,0.15,{139,65,224,57,226,50,223,58,184,114,132,0},{32,139,46,161,44,130,66,218,81,243,125,187,66,20,134,5,182},{45,138,50,189,47,162,76}},C={220,247,247,213,247,235,225,213,246,250,245,201,230,255,247,216,230,253,245,213,244,235,213,243,250,246,199,247,197,247,213,242,213,246,242,197,247,213,241,253,240,213,244,235,213,255,213,254,213,255,213,254,250,243,242,197,247,213,253,253,252,213,251,235,213,254,213,254,213,254,250,244,242,197,247,213,250,213,255,242,197,247,213,249,213,254,242,197,247,213,248,213,231,242,197,247,213,230,220,247,242,220,246,197,247,213,229,183,247,213,250,213,228,242,250,244,198,246,253,245,213,244,235,213,243,250,246,199,246,197,246,213,241,253,240,213,244,235,213,254,213,227,213,254,213,226,250,243,242,197,246,213,225,253,240,213,244,235,213,224,213,239,210,213,224,213,238,210,250,243,242,197,246,213,253,253,252,213,251,235,213,237,213,236,213,235,250,244,242,197,246,213,249,213,254,242,197,246,213,248,213,234,242,197,246,213,230,197,247,242,220,245,197,246,213,233,250,245,198,246,220,244,197,246,220,243,213,232,213,215,250,243,198,246,220,242,197,246,253,252,213,251,235,213,235,213,214,213,213,250,244,253,252,213,251,235,213,233,213,212,213,211,250,244,213,210,250,243,198,246,220,241,197,246,213,209,250,245,199,245,220,246,197,245,213,208,183,247,213,223,213,255,242,253,222,213,221,235,213,220,235,250,243,198,246,253,245,213,244,235,213,243,250,246,199,244,197,244,213,241,253,240,213,244,235,213,255,213,254,213,254,213,219,250,243,242,197,244,213,253,253,252,213,251,235,213,218,213,217,213,216,250,244,242,197,244,213,250,213,199,242,197,244,213,249,213,254,242,197,244,213,248,213,198,242,197,244,213,230,197,246,242,220,245,197,244,213,233,250,245,198,246,253,245,213,244,235,213,243,250,246,199,243,197,243,213,241,253,240,213,244,235,213,255,213,254,213,254,213,233,250,243,242,197,243,213,225,253,240,213,244,235,213,254,213,254,213,255,213,233,210,250,243,242,197,243,213,253,253,252,213,251,235,213,218,213,217,213,216,250,244,242,197,243,213,250,213,199,242,197,243,213,249,213,254,242,197,243,213,248,213,198,242,197,243,213,230,197,244,242,253,245,213,244,235,213,243,250,246,199,242,197,242,213,241,253,240,213,244,235,213,254,213,197,213,254,213,197,250,243,242,197,242,213,225,253,240,213,244,235,213,254,213,212,213,224,213,196,210,250,243,242,197,242,213,253,253,252,213,251,235,213,195,213,231,213,231,250,244,242,197,242,213,249,213,254,242,197,242,213,248,213,194,242,197,242,213,230,197,244,242,220,245,197,242,213,196,250,245,198,246,253,245,213,244,235,213,193,250,246,199,241,197,241,213,241,253,240,213,244,235,213,255,213,216,210,213,255,213,254,250,243,242,197,241,213,225,253,240,213,244,235,213,254,213,192,213,254,213,254,250,243,242,197,241,213,250,213,255,242,197,241,213,207,213,206,242,197,241,213,205,220,240,242,197,241,213,204,253,222,213,204,235,213,203,235,242,197,241,213,202,213,201,242,197,241,213,200,253,222,213,200,235,213,183,235,242,197,241,213,248,213,194,242,197,241,213,230,197,244,242,253,245,213,244,235,213,193,250,246,199,240,197,240,213,241,253,240,213,244,235,213,255,213,216,210,213,254,213,214,250,243,242,197,240,213,225,253,240,213,244,235,213,254,213,236,213,254,213,182,250,243,242,197,240,213,250,213,255,242,197,240,213,207,213,181,242,197,240,213,205,220,255,242,197,240,213,204,253,222,213,204,235,213,180,235,242,197,240,213,202,213,179,242,197,240,213,200,253,222,213,200,235,213,183,235,242,197,240,213,248,213,194,242,197,240,213,230,197,246,242,253,245,213,244,235,213,178,250,246,199,255,197,255,213,241,253,240,213,244,235,213,177,213,254,213,254,213,216,250,243,242,197,255,213,225,253,240,213,244,235,213,176,213,254,213,255,213,191,210,250,243,242,197,255,213,253,253,252,213,251,235,213,190,213,189,213,188,250,244,242,197,255,213,250,213,187,242,197,255,213,205,220,240,242,197,255,213,207,213,186,242,197,255,213,202,213,233,242,197,255,213,204,253,222,213,204,235,213,203,235,242,197,255,213,249,213,254,242,197,255,213,248,213,194,242,197,255,213,230,197,246,242,220,245,197,255,213,185,250,245,198,246,220,244,197,255,220,243,213,255,213,224,250,243,198,246,220,254,197,255,220,253,213,187,250,244,198,246,253,245,213,244,235,213,178,250,246,199,254,197,254,213,241,253,240,213,244,235,213,177,213,254,213,254,213,216,250,243,242,197,254,213,225,253,240,213,244,235,213,184,213,254,213,255,213,191,210,250,243,242,197,254,213,253,253,252,213,251,235,213,167,213,166,213,166,250,244,242,197,254,213,250,213,165,242,197,254,213,205,253,252,213,251,235,213,195,213,195,213,195,250,244,242,197,254,213,207,213,164,242,197,254,213,202,213,233,242,197,254,213,204,253,222,213,204,235,213,203,235,242,197,254,213,249,213,254,242,197,254,213,248,213,194,242,197,254,213,230,197,246,242,220,245,197,254,213,185,250,245,198,246,220,244,197,254,253,252,213,251,235,213,195,213,231,213,231,250,244,213,255,213,215,250,243,198,246,220,254,197,254,220,253,213,165,250,244,198,246,197,255,213,163,235,247,213,162,235,225,182,246,250,245,198,246,197,254,213,163,235,247,213,162,235,225,182,245,250,245,198,246,255,247},P={{K={0.16,{88,240,107,20,145,31,139,46,188,45,148,69,207,75,239,99,235,115,29,129,5,164},1,{79,240,107,237,157},0.9,{106,244,127,232},{123,243,97,229,130},0.18},C={220,247,220,246,213,247,183,247,213,246,213,245,242,250,244,198,246,220,247,220,245,213,247,183,247,213,244,213,243,242,250,244,198,246,253,242,213,241,235,213,240,182,246,250,245,198,246,255,247},P={{K={{93,245,116,10,135,3,154}},C={220,247,247,213,247,235,225,250,246,198,246,255,247},P={},U={{0,1}},nParams=0}},U={{0,1},{1,0},{1,2}},nParams=0},{K={{105,243,102,18,153},{106,240,97,13,133},{120,253,103,238,146,13,145,53,188,36,178},{117,253,121,245,153,1,133,56,167},0.2,{77,246,109,239,159},0.94,{84,246,125,238},{69,253,99,231,132},0.22,{83,232,120,230,139},{127,124,139,52,229,218,126,129,100,254,47,254,59,114,134,255,9,135,162,17,245,84,184,73,224,38,141,3,205,49,154,104,129,211,27,254,124,190,88,204}},C={253,247,182,246,250,246,198,246,253,247,182,245,250,246,198,246,253,247,182,244,250,246,198,246,253,247,182,243,250,246,198,246,253,246,220,247,213,245,235,180,246,244,199,245,199,246,199,247,236,247,246,245,239,244,239,243,197,247,197,246,197,245,180,245,245,199,243,199,244,197,244,199,245,197,244,221,224,201,174,253,247,182,242,250,246,198,246,216,195,220,247,213,245,183,242,253,246,220,247,213,244,235,180,246,244,199,240,199,241,199,242,236,242,241,240,239,255,239,254,197,242,197,241,197,240,180,245,245,199,254,199,255,197,255,199,240,197,255,221,224,201,111,253,247,182,241,250,246,198,246,216,132,220,247,213,244,183,242,253,247,182,240,250,246,198,246,220,242,220,240,213,243,183,247,213,242,213,241,242,250,244,198,246,253,240,213,255,235,213,254,182,255,250,245,198,246,253,253,213,252,250,246,198,246,255,247},P={{K={{111,198,98,12,129,5,128,59,189,28,207,115,195,69,249,126,236}},C={220,247,213,247,235,201,248,220,246,250,247,198,246,216,248,255,247},P={},U={{0,0},{0,1}},nParams=0},{K={{122,229,117,13,154,30,183,42,148,38,222,84,193,65}},C={220,247,213,247,235,201,248,220,246,250,247,198,246,216,248,255,247},P={},U={{0,0},{0,2}},nParams=0},{K={{120,254,115,23,180,10,136,31,191,41,221,90,200}},C={220,247,213,247,235,201,248,220,246,250,247,198,246,216,248,255,247},P={},U={{0,0},{0,3}},nParams=0},{K={{111,255,110,26,190,5,143,54,148,38,222,84,193,65}},C={220,247,213,247,235,201,248,220,246,250,247,198,246,216,248,255,247},P={},U={{0,0},{0,4}},nParams=0},{K={{93,249,116,29,154,2,141,63,178,60}},C={220,247,247,213,247,235,225,250,246,198,246,255,247},P={},U={{1,4}},nParams=0},{K={{93,245,116,10,135,3,154}},C={220,247,247,213,247,235,225,250,246,198,246,255,247},P={},U={{1,9}},nParams=0},{K={0.2,{93,227,103,10,134,57,150,58,188,58,176,86,220,64,242,112,243},1},C={220,247,220,246,213,247,183,247,213,246,213,245,242,250,244,198,246,255,247},P={},U={{0,5},{0,6}},nParams=0},{K={{73,241,117,27,155,24},{94,244,123,11,132,2,157}},C={220,247,247,201,251,198,246,220,247,213,247,235,201,236,220,247,247,213,246,235,225,250,246,198,246,216,236,255,247},P={},U={{0,8}},nParams=0}},U={{0,11},{0,12},{0,13},{0,14},{0,15},{0,1},{0,16},{0,17},{0,10}},nParams=0}},U={{1,58},{1,6},{1,2},{1,3},{1,45},{1,4},{1,5},{1,47},{1,46},{1,9},{1,44},{1,16},{1,29},{1,33},{1,37},{1,43},{1,55},{1,56}},nParams=0},{K={{73,241,117,27,155,24},{83,255,123,11,151,3,135,62},{117,247,126},{72,246,114,245,186,26,146,41,187,37},{83,245,102,231},{77,253,101,241,149,26,135,18,191,35,173,121,198,71},{76,255,119,225},{117,211,103,232,206},{71,234,96,235,178,18,141,17,188,36},60,{115,245,98,225,139,31,130,10},0,20,0.5,30,{106,254,117,230,99,9,157,28,142,51,141,42,208,92,216,18},{106,207,123,225,119,79},{76,211,119,226,84,58,182},18,26,{111,197,120,249,110,242,152,27,139,56,135,56,160,86,220,86,252,102,238,108,26,137},0.1,{109,201,111,240,110,240,170,25,157,59,133,37,187,95,221},{100,194,102,225},{},{115,220,84,248,76,240,136,7,133,15,155,32,170,82,198},{114,201,85,241,121,227},{110,226,76,253,117,255},9999,{117,193,77,235,97,205,101,4,141,0,178,55,171,47,204,92},2,0.15,{112,221,70,249,112,192,98,24,148,4},{119,216,70,246,95,238,107,21},1,{117,222,75,198,125},{110,215,74,206,124,196,126,14,144},{123,219,89,206},{124,196,66,212},10000,0.6,0.26,{16,217,80,196,122},{1,218,65,192,78,240,93,241,133,31,143},{7,221,80,193},{11,210,65,216,71,219,101,243,138,26,130,82,153,61,161,92,221},{4,209,91,194,70,249,101},{1,209,70,216,80,217,119,238,97,25},{0,174,71,219,81,223,123,235,111,31,138,2},{3,175,72,218,82,216,122,239,103,29}},C={220,247,247,201,251,198,246,220,247,213,247,235,201,227,220,247,255,246,216,227,253,246,213,245,235,213,244,250,246,199,247,197,247,213,243,213,242,242,197,247,213,241,253,240,213,255,235,213,254,213,254,250,245,242,197,247,213,253,253,240,213,245,235,213,252,213,251,213,250,213,249,210,250,243,242,197,247,213,248,253,231,213,230,235,213,229,213,251,213,228,250,244,242,197,247,213,227,213,226,242,197,247,213,225,213,252,242,197,247,213,224,213,239,242,197,247,213,238,194,242,197,247,213,237,254,242,197,247,213,236,213,235,242,197,247,213,234,254,242,197,247,213,247,220,246,242,220,245,197,247,213,249,250,245,198,246,220,244,197,247,220,243,213,233,213,232,250,243,198,246,253,246,213,245,235,213,215,250,246,199,246,197,246,213,243,213,214,242,197,246,213,241,253,240,213,245,235,213,213,213,252,213,213,213,252,250,243,242,197,246,213,253,253,240,213,245,235,213,252,213,252,213,252,213,252,250,243,242,197,246,213,227,213,213,242,197,246,213,212,220,242,242,197,246,213,211,253,210,213,211,235,213,209,235,242,197,246,213,236,213,208,242,197,246,213,247,197,247,242,220,245,197,246,213,249,250,245,198,246,220,241,197,247,213,223,250,245,199,245,220,240,197,245,213,222,183,247,213,221,213,213,242,253,210,213,220,235,213,219,235,250,243,198,246,197,247,213,218,235,247,213,217,235,225,182,246,250,245,198,246,194,199,244,221,199,243,221,199,242,194,199,241,197,247,213,216,235,247,213,217,235,225,182,245,250,245,198,246,220,253,213,199,235,247,213,217,235,225,182,244,250,245,198,246,220,253,213,198,235,247,213,217,235,225,182,243,250,245,198,246,197,247,203,247,197,247,255,246},P={{K={{112,227,67,12,148,11,132,51,191,47,242,95,195,77},{114,228,106,41,159,30,141,57,190,44},{77,251,122,233,149,2,128}},C={220,247,213,247,235,201,252,255,247,216,252,220,246,254,250,246,198,246,220,247,213,246,254,242,220,245,213,245,194,242,255,247},P={},U={{0,8},{0,9},{1,0}},nParams=0},{K={{76,227,98,12,188,2,147,47,165,28,198,70,200},{95,255,125,18},{86,253,124,243,146,44,144,40,167,37,175,9},{72,252,127,226,144},{77,251,120,235,141,25,136,48}},C={197,247,213,247,235,253,246,213,247,235,213,245,235,207,247,232,201,213,198,246,197,247,213,247,235,253,246,213,247,235,213,244,235,207,201,205,254,203,247,194,203,246,197,247,213,243,235,203,245,220,244,213,243,235,203,243,216,205,255,247},P={},U={{1,3},{1,6},{1,4},{1,0},{1,5}},nParams=1},{K={{76,227,98,12,188,2,147,47,165,28,198,70,200},{95,255,125,18},{86,253,124,243,146,35,138,42,182,39,164,86,219},{72,252,127,226,144},{77,251,120,235,141,25,136,48},{115,244,120,235},{126,244,126},{120},8,{123},{74,233,85,250,158,17,138,13,181,53,132,41,217,71},{113,223,123,228,50},{75,249,100},{117,254,117,231,103},{104,248,115,255,102,14}},C={220,247,232,201,254,255,247,216,254,197,247,213,247,235,253,246,213,247,235,213,245,235,224,247,201,221,198,246,197,247,213,247,235,253,246,213,247,235,213,244,235,224,201,199,255,247,216,199,197,247,213,243,235,220,246,230,199,246,253,242,213,241,235,197,246,213,240,235,250,246,213,255,238,247,232,201,169,198,246,253,242,213,241,235,197,246,213,254,235,250,246,213,255,238,201,84,254,203,245,220,244,213,253,254,242,220,243,213,243,253,252,213,251,235,220,242,213,240,235,213,250,235,220,242,213,240,235,213,249,235,197,246,213,240,235,249,220,242,213,254,235,213,250,235,220,242,213,254,235,213,249,235,197,246,213,254,235,249,250,243,242,216,84,255,247},P={},U={{1,3},{1,4},{1,6},{0,8},{1,0},{1,5}},nParams=1},{K={{76,227,98,12,188,2,147,47,165,28,198,70,200},{95,255,125,18},{86,253,124,243,146,44,144,40,167,37,175,9},{72,252,127,226,144},{105,245,120,233},{122,240,96,226,131},0.1},C={197,247,213,247,235,253,246,213,247,235,213,245,235,207,247,232,201,213,198,246,197,247,213,247,235,253,246,213,247,235,213,244,235,207,201,203,194,203,247,220,246,201,205,253,243,213,242,235,213,241,182,246,250,245,198,246,216,205,216,203,255,247},P={{K={{112,227,67,12,148,11,132,51,191,47,242,95,195,77}},C={220,247,213,247,194,242,255,247},P={},U={{0,2}},nParams=0}},U={{1,3},{1,6},{0,8}},nParams=1}},U={{1,93},{1,44},{1,2},{1,3},{1,45},{1,92},{1,5},{1,6},{1,16},{1,91},{1,1}},nParams=0},{K={{113,229,101,40,156,31,138,56,189,45},{76,248,123,22,148,1,129}},C={220,247,213,247,194,242,220,246,194,250,246,198,246,220,245,250,247,199,247,197,247,213,246,254,242,255,247},P={},U={{1,16},{1,91},{1,94}},nParams=0},{K={{82,245,126,61,154,8,134},{114,228,106,43,153,10,131,55,183,2,165,78},{115,231,107,214,158,29,140,62,191,47},{76,242,120,228,150,27},{75,253,120,235,155,28,130},{110,231,101,237,142},{68,113,148,57,30,223,121,132,111,227,32,131,48,119,129,80,250,100,152,124,236,4,214,75,162,49,154,68,133,12,246,3,127,144,104,239}},C={197,246,201,255,255,247,216,255,197,247,213,247,235,220,247,213,246,235,207,201,151,220,246,213,245,220,246,213,245,235,232,242,220,245,220,246,213,245,235,250,246,198,246,220,246,213,245,235,201,189,220,244,247,201,201,198,246,220,244,213,244,235,201,191,220,244,213,243,194,242,216,191,216,161,220,243,250,247,199,245,197,245,213,243,254,242,253,242,213,241,250,246,198,246,216,151,255,247},P={},U={{1,18},{1,16},{1,91},{1,93},{1,94}},nParams=2},{K={{94,226,104,11,133,56,145,59,191,59,207,87,223,65,245,113,240},1},C={220,247,213,247,213,246,242,255,247},P={},U={{1,55}},nParams=0},{K={{105,243,102,18,153},0.34,{72,241,104,236,146},1,{88,250,126,239},{91,244,127,234,148,22,187,43,175,33,161},{93,247,110,239}},C={253,247,182,246,250,246,198,246,220,247,220,245,213,246,183,247,213,245,213,244,242,253,243,213,242,235,213,241,235,250,243,198,246,255,247},P={{K={0.3,{93,227,103,10,134,57,150,58,188,58,176,86,220,64,242,112,243},0},C={220,247,220,246,213,247,183,247,213,246,213,245,242,250,244,198,246,255,247},P={},U={{0,0},{0,1}},nParams=0}},U={{1,6},{1,55},{1,56}},nParams=0}}
local _I0123={253,247,247,213,246,235,225,213,245,250,245,199,247,253,247,247,213,246,235,225,213,244,250,245,199,246,182,246,199,245,182,245,199,244,182,244,199,243,182,243,199,242,182,242,199,241,182,241,199,240,182,240,199,255,182,255,199,254,182,254,199,253,253,247,247,213,246,235,225,213,243,250,245,199,252,253,247,247,213,246,235,225,213,242,250,245,199,251,197,252,213,241,235,199,250,197,250,247,213,240,235,225,213,255,250,245,199,249,197,250,247,213,254,235,225,250,246,199,248,183,247,213,253,254,242,247,213,252,194,242,247,213,251,194,242,247,213,250,194,242,247,213,249,194,242,247,213,248,183,242,247,213,231,183,242,247,213,230,221,242,247,213,229,194,242,247,213,228,194,242,199,231,182,253,199,230,183,247,213,227,253,226,213,225,235,213,224,235,242,247,213,239,253,226,213,225,235,213,238,235,242,247,213,237,253,226,213,225,235,213,236,235,242,199,229,253,235,213,234,235,213,233,213,232,213,215,250,244,199,228,253,235,213,234,235,213,214,210,213,213,213,212,250,244,199,227,253,235,213,234,235,213,211,210,213,210,213,209,250,244,199,226,253,235,213,234,235,213,208,210,213,223,213,222,250,244,199,225,253,235,213,234,235,213,221,213,220,213,219,210,250,244,199,224,253,235,213,234,235,213,218,210,213,217,213,216,210,250,244,199,239,253,235,213,234,235,213,199,213,198,213,197,210,250,244,199,238,253,235,213,234,235,213,196,210,213,217,213,195,210,250,244,199,237,182,252,199,236,182,251,199,235,182,250,199,234,253,194,213,234,235,213,193,250,246,199,233,197,233,213,192,213,207,242,182,249,199,232,182,248,199,215,182,231,199,214,182,230,199,213,253,247,247,213,246,235,225,213,206,250,245,199,212,182,229,199,211,182,228,199,210,183,247,213,205,213,204,210,242,247,213,203,213,202,210,242,247,213,201,194,242,247,213,200,221,242,247,213,183,221,242,247,213,182,221,242,199,209,182,227,199,208,182,226,199,223,182,225,199,222,182,224,199,221,182,239,199,220,253,194,213,234,235,213,181,250,246,199,219,197,219,213,180,213,179,242,197,219,213,178,194,242,197,219,213,177,254,242,197,219,213,176,213,191,242,197,219,213,190,253,226,213,190,235,213,189,235,242,197,219,213,188,197,249,242,253,187,213,186,235,213,185,213,184,213,167,250,244,199,218,253,187,213,186,235,213,166,213,165,213,164,250,244,199,217,253,187,213,186,235,213,163,213,162,213,161,250,244,199,216,253,187,213,186,235,213,160,213,175,213,175,250,244,199,199,253,187,213,186,235,213,174,213,173,213,172,250,244,199,198,253,187,213,186,235,213,171,213,170,213,169,250,244,199,197,253,194,213,234,235,213,168,250,246,199,196,197,196,213,180,213,151,242,197,196,213,150,253,149,213,234,235,213,148,213,147,250,245,242,197,196,213,146,253,145,213,234,235,213,148,213,144,210,213,147,213,144,250,243,242,197,196,213,159,253,145,213,158,235,213,202,213,147,250,245,242,197,196,213,157,253,226,213,157,235,213,156,235,242,197,196,213,155,213,148,242,197,196,213,154,213,153,242,197,196,213,188,197,219,242,253,194,213,234,235,213,152,250,246,199,195,197,195,213,135,253,134,213,234,235,213,147,213,133,250,245,242,197,195,213,132,253,226,213,132,235,213,131,235,242,197,195,213,130,253,226,213,130,235,213,129,235,242,197,195,213,188,197,196,242,213,147,199,194,182,238,199,193,253,194,213,234,235,213,168,250,246,199,192,197,192,213,180,213,128,242,197,192,213,159,253,145,213,234,235,213,147,213,143,213,147,213,142,250,243,242,197,192,213,146,253,145,213,234,235,213,141,213,140,210,213,141,213,139,210,250,243,242,197,192,213,155,213,148,242,197,192,213,188,197,219,242,197,242,197,192,213,148,250,245,199,207,253,194,213,234,235,213,168,250,246,199,206,197,206,213,159,253,145,213,234,235,213,148,213,147,213,148,213,147,250,243,242,197,206,213,146,253,145,213,234,235,213,147,213,147,213,147,213,191,250,243,242,197,206,213,138,253,187,213,234,235,213,147,213,147,213,147,250,244,242,197,206,213,155,213,137,242,197,206,213,136,213,147,242,197,206,213,154,213,147,242,197,206,213,188,197,192,242,197,245,197,206,213,174,250,245,198,246,253,194,213,234,235,213,168,250,246,199,205,197,205,213,180,213,119,242,197,205,213,159,253,145,213,234,235,213,148,213,147,213,148,213,147,250,243,242,197,205,213,146,253,145,213,234,235,213,147,213,147,213,147,213,147,250,243,242,197,205,213,138,197,198,242,197,205,213,155,213,118,242,197,205,213,136,213,147,242,197,205,213,117,254,242,197,205,213,116,254,242,197,205,213,154,213,148,242,197,205,213,188,197,192,242,197,245,197,205,213,144,250,245,198,246,197,244,197,205,197,218,213,115,213,114,250,243,198,246,197,243,197,205,253,187,213,186,235,213,113,213,172,213,112,250,244,253,187,213,186,235,213,127,213,126,213,125,250,244,213,124,250,243,198,246,253,194,213,234,235,213,168,250,246,199,204,197,204,213,159,253,145,213,234,235,213,148,213,123,210,213,147,213,148,250,243,242,197,204,213,146,253,145,213,234,235,213,147,213,122,213,147,213,148,250,243,242,197,204,213,138,253,187,213,234,235,213,148,213,148,213,148,250,244,242,197,204,213,155,213,121,242,197,204,213,136,213,147,242,197,204,213,154,213,120,242,197,204,213,188,197,205,242,253,194,213,234,235,213,168,250,246,199,203,197,203,213,159,253,145,213,234,235,213,148,213,147,213,147,213,103,250,243,242,197,203,213,138,197,197,242,197,203,213,155,213,102,242,197,203,213,136,213,147,242,197,203,213,154,213,120,242,197,203,213,188,197,205,242,197,245,197,203,213,144,250,245,198,246,197,243,197,203,253,187,213,186,235,213,101,213,169,213,100,250,244,253,187,213,186,235,213,99,213,113,213,98,250,244,213,124,250,243,198,246,253,194,213,234,235,213,97,250,246,199,202,197,202,213,159,253,145,213,234,235,213,147,213,96,213,147,213,96,250,243,242,197,202,213,146,253,145,213,234,235,213,147,213,191,213,147,213,111,250,243,242,197,202,213,155,213,148,242,197,202,213,110,213,109,242,197,202,213,108,253,226,213,108,235,213,107,235,242,197,202,213,154,213,106,242,197,202,213,188,197,203,242,197,245,197,202,213,105,250,245,198,246,197,244,197,202,197,218,213,115,213,104,250,243,198,246,253,194,213,234,235,213,87,250,246,199,201,197,201,213,159,253,145,213,234,235,213,148,213,86,210,213,147,213,171,250,243,242,197,201,213,146,253,145,213,234,235,213,147,213,85,213,147,213,84,250,243,242,197,201,213,155,213,148,242,197,201,213,83,213,82,242,197,201,213,81,197,216,242,197,201,213,80,253,226,213,80,235,213,95,235,242,197,201,213,94,213,126,242,197,201,213,93,253,226,213,93,235,213,92,235,242,197,201,213,154,213,106,242,197,201,213,188,197,203,242,253,194,213,234,235,213,87,250,246,199,200,197,200,213,159,253,145,213,234,235,213,148,213,86,210,213,147,213,144,250,243,242,197,200,213,146,253,145,213,234,235,213,147,213,85,213,147,213,91,250,243,242,197,200,213,155,213,148,242,197,200,213,83,213,90,242,197,200,213,81,197,199,242,197,200,213,80,253,226,213,80,235,213,89,235,242,197,200,213,94,213,191,242,197,200,213,93,253,226,213,93,235,213,92,235,242,197,200,213,154,213,106,242,197,200,213,188,197,203,242,253,194,213,234,235,213,168,250,246,199,183,197,183,213,159,253,145,213,234,235,213,147,213,111,213,147,213,111,250,243,242,197,183,213,146,253,145,213,234,235,213,147,213,88,213,147,213,71,250,243,242,197,183,213,138,197,218,242,197,183,213,136,213,147,242,197,183,213,154,213,106,242,197,183,213,188,197,203,242,197,245,197,183,213,70,250,245,198,246,197,247,247,213,69,235,225,197,183,253,68,213,234,235,213,67,253,226,213,66,235,213,65,235,253,226,213,64,235,213,79,235,213,148,210,254,250,242,183,247,213,155,213,78,242,250,243,247,213,77,235,225,250,246,198,246,253,194,213,234,235,213,87,250,246,199,182,197,182,213,159,253,145,213,158,235,213,101,213,105,250,245,242,197,182,213,146,253,145,213,234,235,213,147,213,76,213,147,213,122,250,243,242,197,182,213,138,197,218,242,197,182,213,155,213,121,242,197,182,213,83,213,75,242,197,182,213,81,197,218,242,197,182,213,80,253,226,213,80,235,213,95,235,242,197,182,213,94,213,84,242,197,182,213,154,213,106,242,197,182,213,188,197,203,242,197,245,197,182,213,111,250,245,198,246,253,194,213,234,235,213,74,250,246,199,181,197,181,213,159,253,145,213,158,235,213,171,213,171,250,245,242,197,181,213,146,253,145,213,234,235,213,148,213,85,210,213,141,213,127,210,250,243,242,197,181,213,138,253,187,213,186,235,213,73,213,160,213,72,250,244,242,197,181,213,155,213,55,242,197,181,213,83,213,54,242,197,181,213,81,253,187,213,234,235,213,148,213,148,213,148,250,244,242,197,181,213,80,253,226,213,80,235,213,95,235,242,197,181,213,94,213,71,242,197,181,213,136,213,147,242,197,181,213,154,213,133,242,197,181,213,188,197,203,242,197,245,197,181,213,53,250,245,198,246,197,244,197,181,197,218,213,148,213,141,250,243,198,246,197,254,197,181,197,219,213,55,250,244,198,246,253,194,213,234,235,213,74,250,246,199,180,197,180,213,159,253,145,213,158,235,213,171,213,171,250,245,242,197,180,213,146,253,145,213,234,235,213,148,213,101,210,213,141,213,127,210,250,243,242,197,180,213,138,253,187,213,186,235,213,73,213,160,213,72,250,244,242,197,180,213,155,213,55,242,197,180,213,83,213,52,242,197,180,213,81,253,187,213,234,235,213,148,213,148,213,148,250,244,242,197,180,213,80,253,226,213,80,235,213,95,235,242,197,180,213,94,213,144,242,197,180,213,136,213,147,242,197,180,213,154,213,133,242,197,180,213,188,197,203,242,197,245,197,180,213,53,250,245,198,246,197,244,197,180,197,218,213,148,213,141,250,243,198,246,197,254,197,180,197,219,213,55,250,244,198,246,253,194,213,234,235,213,168,250,246,199,179,197,179,213,159,253,145,213,234,235,213,148,213,86,210,213,148,213,147,250,243,242,197,179,213,155,213,148,242,197,179,213,117,254,242,197,179,213,154,213,51,242,197,179,213,188,197,203,242,194,199,178,221,199,177,221,199,176,197,179,213,50,235,247,213,49,235,225,182,237,250,245,198,246,197,246,213,48,235,247,213,49,235,225,182,236,250,245,198,246,197,246,213,63,235,247,213,49,235,225,182,235,250,245,198,246,253,194,213,234,235,213,168,250,246,199,191,197,191,213,159,253,145,213,234,235,213,148,213,99,210,213,148,213,62,210,250,243,242,197,191,213,146,253,145,213,234,235,213,147,213,61,213,147,213,85,250,243,242,197,191,213,155,213,148,242,197,191,213,136,213,147,242,197,191,213,154,213,120,242,197,191,213,188,197,205,242,253,194,213,234,235,213,168,250,246,199,190,197,190,213,159,253,145,213,234,235,213,147,213,166,213,148,213,147,250,243,242,197,190,213,138,253,187,213,186,235,213,99,213,113,213,98,250,244,242,197,190,213,155,213,55,242,197,190,213,136,213,147,242,197,190,213,188,197,191,242,197,245,197,190,213,105,250,245,198,246,197,244,197,190,197,218,213,148,213,60,250,243,198,246,197,243,197,190,253,187,213,186,235,213,123,213,101,213,59,250,244,253,187,213,186,235,213,58,213,174,213,113,250,244,213,124,250,243,198,246,253,194,213,234,235,213,87,250,246,199,189,197,189,213,150,253,149,213,234,235,213,147,213,148,250,245,242,197,189,213,146,253,145,213,234,235,213,147,213,147,213,148,213,191,210,250,243,242,197,189,213,159,253,145,213,234,235,213,148,213,147,213,147,213,122,250,243,242,197,189,213,155,213,148,242,197,189,213,83,213,57,242,197,189,213,81,253,187,213,186,235,213,124,213,86,213,56,250,244,242,197,189,213,80,253,226,213,80,235,213,89,235,242,197,189,213,94,213,53,242,197,189,213,188,197,190,242,253,194,213,234,235,213,168,250,246,199,188,197,188,213,159,253,145,213,234,235,213,148,213,88,210,213,148,213,147,250,243,242,197,188,213,146,253,145,213,234,235,213,147,213,88,213,147,213,147,250,243,242,197,188,213,155,213,148,242,197,188,213,136,213,147,242,197,188,213,188,197,191,242,253,194,213,234,235,213,168,250,246,199,187,197,187,213,159,253,145,213,234,235,213,148,213,147,213,148,213,147,250,243,242,197,187,213,155,213,148,242,197,187,213,39,254,242,197,187,213,188,197,188,242,253,194,213,234,235,213,168,250,246,199,186,197,186,213,159,253,145,213,234,235,213,148,213,147,213,148,213,147,250,243,242,197,186,213,155,213,148,242,197,186,213,39,194,242,197,186,213,188,197,188,242,253,194,213,234,235,213,168,250,246,199,185,197,185,213,159,253,145,213,234,235,213,148,213,147,213,148,213,147,250,243,242,197,185,213,155,213,148,242,197,185,213,39,194,242,197,185,213,188,197,188,242,183,247,213,148,197,187,242,247,213,120,197,186,242,247,213,106,197,185,242,199,184,197,187,199,167,182,234,199,166,183,199,165,182,233,199,164,182,232,199,163,197,163,213,38,213,37,197,187,250,244,198,246,197,163,213,36,213,35,197,186,250,244,198,246,197,163,213,34,213,33,197,185,250,244,198,246,197,164,197,165,213,148,235,250,246,198,246,182,215,199,162,182,214,199,161,182,213,199,160,197,162,197,187,213,32,213,147,250,244,198,246,182,212,199,175,197,175,213,47,213,46,197,228,213,45,250,243,198,246,197,175,213,44,213,43,197,227,213,42,250,243,198,246,197,175,213,41,213,40,197,226,213,23,250,243,198,246,197,175,213,22,213,21,197,225,213,20,250,243,198,246,197,175,213,19,213,18,197,224,213,17,250,243,198,246,197,175,213,16,213,60,197,239,213,31,250,243,198,246,197,175,213,30,213,29,197,238,213,28,250,243,198,246,197,175,213,27,213,26,197,237,213,25,250,243,198,246,197,162,197,186,213,24,213,147,250,244,198,246,182,211,199,174,197,161,197,186,213,46,213,7,197,231,213,252,235,182,210,250,242,198,246,197,161,197,186,213,35,213,6,197,231,213,249,235,182,209,250,242,198,246,197,161,197,186,213,5,213,4,197,231,213,251,235,182,208,250,242,198,246,197,161,197,186,213,18,213,3,197,231,213,250,235,182,223,250,242,198,246,197,160,197,186,213,2,213,1,182,222,250,243,198,246,197,162,197,185,213,0,213,147,250,244,198,246,182,221,199,173,197,173,213,15,213,46,213,227,250,244,198,246,197,173,213,14,213,35,213,237,250,244,198,246,197,173,213,13,213,5,213,239,250,244,198,246,182,220,199,172,197,180,213,12,235,247,213,49,235,225,182,219,250,245,198,246,213,109,199,171,221,199,170,182,218,199,169,197,181,213,12,235,247,213,49,235,225,182,217,250,245,198,246,221,199,168,197,246,213,50,235,247,213,49,235,225,182,216,180,245,246,199,168,197,231,213,248,235,213,11,197,168,242,253,10,182,199,250,246,198,246,197,207,213,9,213,8,242,253,503,213,502,235,182,198,250,246,198,246,197,193,213,501,213,500,197,218,250,244,198,246,253,499,213,498,250,246,198,246,255,247}
local _OOO22={{126,241,106,27},{93,244,124,44,147,31,146,50,177,44},{79,229,108,229,153,61,128,46,165,35,162,93},{73,224,111,243,177,1,150,40,160,24,167,75,198,78,253,112},{77,248,106,251,156,2,148},{76,224,98,208,159,3,158,54,181,40},{83,249,110,229,151,34,133,1,174,43,183},{119,246,103,241,186,28,152,34,176,38,170,89},{113,244,110,255,152,6,172,23,176},{101,252,100,202,145,0,159,6},{75,239,115,222,150,5,132,6,183,55},{82,205,119,251,116,30,141,4,176,7,186,4,214,78,196,113,241},{68,242,103,227,64,30,132,35,179,53,169,46,220},{80,242,125,239,73,16,156,11,155,59,173,33,214,84},{68,235,103,255,108,8,165,24,154,56,172,38,215,87},{75,240,120,227,97,24,134,0,143,57,189},{64,206,100,250,100,18,144,15,146},{92,245,104,192,116,20,147,2,140,56,188,23,209,70},{93,235,106,209,115,42,154,28},{69,208,94,227,105,24,145,4,138,60,159,32,174,94},{91,242,126,224,125,233,148,15,137,23,182,51},{107,203,105,254},{100,195,100,215,100,230,156},{102},{89,221,125,194,98,227,156,30,140,43,178,55},{126,204,70,227,77,234,146,7,152,14,180},{80,223,83,235,96,244,169,4,160,7,160},{96},{99,201,64,238,126,250,204},{88,200,83},145.4,440.8,30.1,51.2,1854.7,25225.9,84.3,29.3,20332.7,50.1,1581.3,25241.3,438.8,439.5,376.1,14.7,652.1,389.8,20.1,438.2,460.7,169.2,726.3,{7,171,79,199,75,207,123,234},{14,168,84,217,74,214,112,255,105},{17,169,87,216,77,215,115,254,102,54,146},{35,170,71,215,94,215,126,230,96,228,205,65,202,109,230,115,244,15,156,16,172,39,184,59},{4,160,50,195,91,196,112,198,121,228,138},{31,133,2,243,112,255},20000,{3,131,10,254,110,237,81,194,72,214,164,43},300,{33,161,44,216,126,197,69,253},{48,170,39,207,64,233,71,248,100,196,145,27,130},{43,181,51,203,71,194,111,245,114,233,139,31,130,10},{44,190,33,219,98,194,75,247},{8,177,59,165,82,192,98,233,122},{18,178,39,164},{14,188,34,176,86,219,72,214,96,238},{12,176,63,166,78,254,70,204,102,236,115,21},{22,177,35,171,73,215,110,213,126,199,107,15,150,30},{36,190,61,181,80,210,83,238,106,235,99,15},10,{56,144,62,163,91,205,110,198,114,240,126,22,153,31},{48,179,51,164,86,216,74},{52,186,32,172,46,195},{38,179,63,165,51,139},{0,175,59,166,16,254,114},85,210,200,140,225,215,220,245,242,120,150,22,26,33,30,35,44,{62,157,7,176,49},{45,159,6,173,33,128,34,195,84,218},{59,159,11,183,57,191,20,212,91,199,84},{45,151,10,148,56,188,119},1,0,{46,154,31,138,46,184,39,209},{42,178,4,137,105},18,{210,145,21,131},{228,139,31,138,17,179,42,176,95,197},{194,143,5,135,50,183,57,173,88,225,64,218,114},{221},{199,157,16,129,6,170,32,179,83,208,127,208,120,254,116,14,148,30,134,52,178,49},{220,180,26,143,7,161},6000,{221,182,58,132,23,175,30,168,57,216,91,209},{217,97,19,138,12,178,52},{223,69,17,130},6,{196,108,8,152,18,176,56,185,37,215,115,197,73,240,96,232,153,29,158},{223,109,28,154,29},{221,106,14,135,37,147,60,170,52},{195,103,4,155,30,150,22,162,35,219,71},{199,110,16,145,3,148,8,190,39,203},760,500,0.5,380,250,{212,108,231,144,21,155,15,162,32,161,127,220,70,206,106,188},0.72,{218,96,244,153,17,153,49,176,42,162,110,220,84,198,118},{212,113,238,144,34,133,13,190,62,191},0.12,{218,113,253,105,1,139},{223,127,227,113,11,171,3,174,55,174,44,221,81,201,106,230},1.5,0.3,28,42,15,17,23,90,32,16,0.86,2,64,0.15,38,55,24,36,{230,75,252,115,238,78,24,146,2,178},50,7,{251,68,193,112,235},{193,72,217,121,252,117,24,128,2,134,99,255,104,135,4,148,23,162,34,185,203,71,219,92,227,98,249},{231,72,195,117,245,83,7,133,9},{246,94,204,106},3,14,0.35,{237,85,223,106,217,109,225,159,29},110,72,8,{233,81,211,86},{89,172,17,198,55,129,108,71,219,8,219,88},{235,83,213,80,216,125,229,111,5,221},{134,88,192,81},{134,87,219,78,252,121,201,109,21,148},{150,92,200,83,205,124,246,102},{151,95,201,92,199,87,225,109,28,156,4,133,57,186},{136,94,212,93},34,{35,184,5,206,50,149,117,142,203,17,209,127,122,145,43,214,85,206,76,241,121,169,64,20,135,6,191,52,191,38,223,72},{128,81,193,68,194,119},152,20,4,{136,48,220,81,211,123},{152,52,223,84,198,86,248,107,235},1.2,{139,36,207,90,196,70,203,123,255,145,17},{156,47,211,81},{149,38,205,92,194,68,222,120,250,154,21,153,13,180,60},{152,38,240,67,217},0.6,{131,38,160,65},164,{245,0,138,108,244,8},{130,40,188,79,240,92,212,99,225,107},48,114,0.25,{56,217,90},9,{31,196},5,{151,59,188,54,206,115,205,120,247,99},{156,57,163,42,222,81,221},{169,57,190,48,200,112,194,64,246,104,227,153},{168,54,191,51,201,113,197,70,252,116},84,12,0.55,47,19,{145,108,251,124,227,248,6,8,204,94,196,86,52,185,38},112,{191,9,164,39,167,80,214},{15,253,104,170,90,171,81,169,17,240,16,134},0.08,{8,219,97,184,94,180,95,186,56,253,28,174},0.22,{8,233,85,186,71,244,80,135,11,248,58,145},0.36,{21,251,110,176,80,213,95,149,50,246,45,147,97,121,193,0,224,86},{20,234,108,191,77,197,94,186,25,197,11,190,96,96,229,14,217,117,170,121,190},0.1,{22,246,81,189,83,208,89,140,6,199,38,147},{17,233,81,176,80,198,91,189,28,203,61,131,97,83,211,8,196,111},0.19,{30,202,118,178,126,236,37,151,26},{18,236,86,181,83,203,36,176,31,192,48,175,109,137,202,21,201,122},0.28,{31,221,92,184,94,255,38,148,21},{31,243,91,182,86,204,33,179,2,204,46,136,107,168,236,21,226,94},0.37,{25,253,117,132,117,223,32,181,11},{24,246,88,139,89,209,34,182,5,203,56,185,118,133,251},0.46,{24,237,78,131,86,214},{229,245,93,140,92,210,47,201,8,198,13,133,113,133,29},{232,211,119,131,83,203},{231,251,67,142,94,212,41,203,10,212,5,187,115,136,22},0.64,{225,214,86,140,101,197},{224,254,64,131,97,217,42,206,13,211,30,183,127,140,28},0.73,{224,203,96,138,127,193},{237,245,105,133,103,230,53,241,125,222,56,174,117,132,22},{95,101,105,236,2,199,103,173,95,148,72,129,38},{236,57,64,137,78,196,51,213,110,222,23,156},0.34,{77,237,142,24,169,25,157},{229,29,96,149,64,218,49,224,127},0.58,{234,58,74,145,99,212,48,215,74,217,33,179},{248,0,84,157,68,225,63,238,99,214,54,178,77,150,39,225,40,90,139,75,198},{244,22,125,145,118,208,60,204,101,167,16,149,67,144,26,227,12,77},{244,49,184,145,70,252,59,205,102,166,31,148,64,145,29,226,15,76},{91,255,99,145,78,201,58,240,113,109,80,170,22,246,2,131},{89,228,119,10,149,37,171,33,184,44,212,0,235,115,255,110,239},{125,249,97,46,158,15,184,58,168},{102,238,101,23,158},{68,237,100,16,150},0.96,{109,241,116,21},{105,225,105,8,152},{252,33,178,103,66,223,0,236,98,173,118,170},{251,10,183,100,85,255,2,229,121,174,125,186,85,144,44,253,48,138,159,116,205,255,148,122,100,247,87,207,84,212,97,235,136,1,133,13,248,166,103,146,83,143,24,54,121,157,207,29,251,108},{109,230,98,236,141},{69,114,149,62,31,220,120,187,110,224,33,132,49,116,128,245,18,128,92,22,239,73,177,76,238,85,136,34,199,28,181,98,80,249,10,235,74,190,117,163,81,169,5,252,48,185,102,101,240,0,229,96,175,78,136,64,154,17,252,27,191,156,108,215,146,52,162,39,223,85,79,148,22,235,1,112,149,114,212,49,192,96,212,20,137,72,129,43,239,243,98,131,67,217}}
return _OO10O0(_OOO22,_I0123,__IlI1,_l_I24)
