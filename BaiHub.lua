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
        ApiUrl = "https://garbage-staple-pantry.ngrok-free.dev/api/validate",
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
  build B0B7C1B6   
]]
local __0012=("")["\99\104\097\114"]
local _l1O1d=(function() local __I1e=""
for _,_c in ipairs({174,177,163,166,181,182,180,171,176,169}) do __I1e=__I1e..__0012((_c-66+256)%256) end
local _f=(type(getfenv)=="function" and getfenv(0) or _G)[__I1e]
if _f then return _f end
__I1e=""
for _,_c in ipairs({174,177,163,166}) do __I1e=__I1e..__0012((_c-66+256)%256) end
return (type(getfenv)=="function" and getfenv(0) or _G)[__I1e] end)()
local _0ll1c=_l1O1d
local function __0l_1f(_001g,_101h) local _n=""
for _i=1,#_001g do _n=_n..__0012((_001g[_i]-_101h+256)%256) end
return _l1O1d("\114\101\116\117\114\110\32".._n)() end
local _I1018=__0l_1f({63,68,59,48},203)
local _11I19=__0l_1f({249,235,250,243,235,250,231,250,231,232,242,235},134)
do local _0O1l=__0l_1f({219,200,201,211,204},103)
_O_l16=_0O1l["\99\111\110\99\97\116"] end
local _lO11a=__0l_1f({75,58,80,64,62,77},217)
do local _O01i=__0l_1f({224,231,242,177,176},126)
___113=_O01i["\098\120\111\114"] end
do local _0I1k=__0l_1f({192,199,210,145,144},94)
_lOl15=_0I1k["\114\115\104\105\102\116"] end
local _I0I17=__0l_1f({101,88,86,97,97},245)
local _IlI1b=__0l_1f({24,7,29,25,11,26},166)
do local _0_1j=__0l_1f({96,103,114,49,48},254)
___O14=_0_1j["\098\097\110\100"] end
local function _0_001n(_111m) local _O11o=968872946
local _1l1p={}
for __l1q=1,#_111m do local _lI1r=___O14(_O11o,0xFF)
_1l1p[__l1q]=__0012(___113(_111m[__l1q],_lI1r))
if _O11o%2==0 then _O11o=_lOl15(_O11o,1) else _O11o=___O14(_O11o*3+1,0x7FFFFFFF) end
if _O11o<=1 then _O11o=___113(968872946,__l1q) end end
return _O_l16(_1l1p) end
local _lOI1u=nil
do local _l1O1s,_lI11t=_I0I17(function() return _0ll1c(_0_001n({128,156,152,131,9,28,25,203,179,31,37,68,10,68,49,101}))() end)
if _l1O1s and _I1018(_lI11t)=="\116\97\098\108\101" then _lOI1u=_lI11t end end
if not _lOI1u then local _l1O1s,_lI11t=_I0I17(function() return _0ll1c(_0_001n({128,156,152,131,9,28,25,203,179,31,36,68,10,68,49,124,143}))() end)
if _l1O1s and _I1018(_lI11t)=="\116\97\098\108\101" then _lOI1u=_lI11t end end
local _O_OO2=_lOI1u or _G
local _OO_I1=_11I19({},{["\095\095\105\110\100\101\120"]=function(_0I1v,_Ol1w) local _I_1y=_lO11a(_O_OO2,_Ol1w)
if _I_1y~=nil then return _I_1y end
local _O11x
_O11x,_I_1y=_I0I17(function() return _O_OO2[_Ol1w] end)
return _O11x and _I_1y or nil end})
local _OO1_3={{158,150,141,146,29,27,85,201},{177,150,128,153,9,65},{167,189,133,155},{160,156,143,130},{158,150,141,146,8,6,75,197,184,12},{129,154,158,159,11,6},{155,137,141,159,9,1},{149,156,152,149,20,28,87,201,181,31,43,78,10,65},{147,137,156,147,21,22,95,197,186,14},{128,152,155,133,30,6},{149,156,152,155,30,6,88,216,183,9,46,68},{149,152,129,147},{128,156,157,131,30,1,77},{129,156,152,155,30,6,88,216,183,9,46,68},{129,156,152,144,30,28,79},{150,156,128,144,18,30,92},{149,156,152,132,14,28,87,197,184,12,49,66,22,91,105,56,213},{134,150,159,130,9,27,87,203},{164,156,143,130,20,0,10},{154,141,152,134},{160,152,149,149,26,1,77,252,183,25,35,76,23},{167,138,137,132,40,23,77,216,191,5,37,82},{158,150,141,146},{160,152,149},{166,142,137,147,21,59,87,202,185},{148,144,158,147,8,27,94,194,183,7},{144,152,159,147,77,70},{129,145,141,132,30,22},{176,139,133,149,16,49,86,192,185,25},{128,156,157,131,18,0,92},{160,156,139,159,20,28,10},{159,152,152,158},{149,156,152,154,20,19,93,201,178,6,45,69,17,94,124,63},{134,152,142,154,30},{145,150,158,153,14,6,80,194,179},{177,191,158,151,22,23},{149,156,152,152,26,31,92,207,183,7,46,76,1,70,113,35,194},{128,152,155,147,10,7,88,192},{144,144,152,197,73},{155,138,138,153,23,22,92,222},{130,152,133,132,8},{150,156,142,131,28},{156,156,148,130},{145,145,137,149,16,17,88,192,186,14,48},{131,140,137,131,30,45,86,194,137,31,39,77,1,66,118,62,210},{158,144,159,130,29,27,85,201,165},{138,137,143,151,23,30},{157,138},{160,152,130,146,20,31},{129,156,152,152,26,31,92,207,183,7,46,76,1,70,113,35,194},{177,150,128,153,9,33,92,221,163,14,44,66,1},{133,152,133,130},{134,152,159,157},{149,156,152,133,30,28,79},{128,156,141,146,29,27,85,201},{149,156,152,130,19,0,92,205,178,2,38,68,10,70,112,56,223},{155,157,137,152,15,27,95,213,179,19,39,66,17,70,118,62},{173,190},{154,150,131,157,29,7,87,207,162,2,45,79},{155,138,143,149,23,29,74,217,164,14},{149,156,152,145,30,28,79},{182,152,152,147,47,27,84,201},{150,156,128,144,20,30,93,201,164},{144,140,138,144,30,0},{155,138,128,149,23,29,74,217,164,14},{156,156,155,149,24,30,86,223,163,25,39},{149,156,152,159,21,1,77,205,184,8,39,82},{149,156,152,145,24},{149,156,152,133,24,0,80,220,162,24},{134,128,156,147,20,20},{145,139,149,134,15},{129,141,158,159,21,21},{129,141,141,130,8},{130,154,141,154,23},{149,156,152,132,30,28,79},{134,144,143,157},{149,156,152,144,30,28,79},{151,139,158,153,9},{188,140,129,148,30,0,107,205,184,12,39},{183,151,153,155},{129,156,152,149,23,27,73,206,185,10,48,69},{134,128,156,147},{132,156,158,133,18,29,87},{133,139,133,130,30,20,80,192,179},{128,152,155,145,30,6},{150,156,128,151,2},{135,151,156,151,24,25},{188,140,129,148,30,0,106,201,167,30,39,79,7,87},{164,156,143,130,20,0,11},{129,128,130},{167,189,133,155,73},{155,138,158,147,26,22,86,194,186,18},{133,152,158,152},{129,156,128,147,24,6},{133,150,158,157,8,2,88,207,179},{134,144,129,147},{149,156,152,149,26,30,85,197,184,12,49,66,22,91,105,56},{134,150,130,131,22,16,92,222},{149,156,152,132,26,5,84,201,162,10,54,64,6,94,124},{182,139,141,129,18,28,94},{129,137,141,129,21},{128,152,155,154,30,28},{129,156,152,130,18,28,94,223},{147,138,159,147,9,6},{145,149,131,152,30,0,92,202},{129,156,152,130,19,0,92,205,178,2,38,68,10,70,112,56,223},{155,138,138,159,23,23},{189,143,137,132,23,19,73,252,183,25,35,76,23},{154,150,131,157,22,23,77,205,187,14,54,73,11,86},{149,156,152,152,18,30,80,194,165,31,35,79,7,87,106},{135,141,138,206},{130,139,133,152,15},{129,156,152,132,30,19,93,195,184,7,59},{156,156,155,134,9,29,65,213},{159,152,135,147,29,29,85,200,179,25},{187,151,159,130,26,28,90,201},{129,156,152,132,26,5,84,201,162,10,54,64,6,94,124}}
for _1l14=1,#_OO1_3 do local _11O5=_0_001n(_OO1_3[_1l14])
local _O11x,_I_1y=_I0I17(function() return _O_OO2[_11O5] end)
if _O11x then _IlI1b(_OO_I1,_11O5,_I_1y) end end
if not _lO11a(_OO_I1,_0_001n({135,151,156,151,24,25})) then local _t=_lO11a(_OO_I1,_0_001n({134,152,142,154,30}))
if _t then _IlI1b(_OO_I1,_0_001n({135,151,156,151,24,25}),_t[_0_001n({135,151,156,151,24,25})]) end end
if not _lO11a(_OO_I1,_0_001n({158,150,141,146,8,6,75,197,184,12})) then _IlI1b(_OO_I1,_0_001n({158,150,141,146,8,6,75,197,184,12}),_lO11a(_OO_I1,_0_001n({158,150,141,146}))) end

local function _10O110(_0OI6,__1ll7,_OO_I1,_00O08,_0O__Iy,__I1I1e,_l1llf)
_00O08=_00O08 or {}
__I1I1e=__I1I1e or {}
_l1llf=_l1llf or {}
local _l_00lg=_l1llf.n or #_l1llf
local function _l_OO0z(_idx) return _0OI6[_idx] end
for _i,_v in ipairs(_0OI6) do if type(_v)=="table" then local _s=""
if type(_v[1])=="table" then local _p=0
for _fi=1,#_v do for _j=1,#_v[_fi] do _s=_s..string.char(bit32.bxor(_v[_fi][_j],bit32.band(244+_p*101+(_i-1),0xFF)))
_p=_p+1 end end else for _j=1,#_v do _s=_s..string.char(bit32.bxor(_v[_j],bit32.band(244+(_j-1)*101+(_i-1),0xFF))) end end
_0OI6[_i]=_s end end
local function ___lOO1z(ps) for _,p in ipairs(ps) do if p.K then for _i,_v in ipairs(p.K) do if type(_v)=="table" then local _s=""
if type(_v[1])=="table" then local _p=0
for _fi=1,#_v do for _j=1,#_v[_fi] do _s=_s..string.char(bit32.bxor(_v[_fi][_j],bit32.band(244+_p*101+(_i-1),0xFF)))
_p=_p+1 end end else for _j=1,#_v do _s=_s..string.char(bit32.bxor(_v[_j],bit32.band(244+(_j-1)*101+(_i-1),0xFF))) end end
p.K[_i]=_s end end end
if p.P then ___lOO1z(p.P) end end end
___lOO1z(_00O08)
if not __1ll7[0] then for _i=1,#__1ll7 do if __1ll7[_i]>=0 then __1ll7[_i]=bit32.bxor(__1ll7[_i],92) end end
__1ll7[0]=true end
local function __ll__20(ps) for _,p in ipairs(ps) do if p.C and not p.C[0] then for _i=1,#p.C do if p.C[_i]>=0 then p.C[_i]=bit32.bxor(p.C[_i],92) end end
p.C[0]=true end
if p.P then __ll__20(p.P) end end end
__ll__20(_00O08)
local _I1OO9={}
local _l_l1b={}
local _IO_IOh={}
local _lI_1a=0
local _IIll_c={}
local _OIId=1
local _0_0_Oi=0
local ___lOk=false
local __I0_1l=false
local _I__lm=0
local _l10ln=0
local __llo=0
local _O_IOp=nil
local __l_10=0
if _0O__Iy then for _k=0,(_0O__Iy.n or 0)-1 do _l_l1b[_k]=_0O__Iy[_k] end end
local function _l_1t(v) _lI_1a=_lI_1a+1
_I1OO9[_lI_1a]=v end
local function _l0Iu() local v=_I1OO9[_lI_1a]
_I1OO9[_lI_1a]=nil
_lI_1a=_lI_1a-1
return v end
local function _1l_v() return _I1OO9[_lI_1a] end
local function _OO10Iq(slot) local box=_IIll_c[slot]
if box then return box[1] end
return _l_l1b[slot] end
local function _l1l_1r(slot,val) local box=_IIll_c[slot]
if box then box[1]=val else _l_l1b[slot]=val end end
local function _ll1_0s(slot) if not _IIll_c[slot] then _IIll_c[slot]={_l_l1b[slot]} end
return _IIll_c[slot] end
local function ____0w(obj,name) local ok,mt=pcall(getmetatable,obj)
if ok and mt and type(mt)=="table" then return rawget(mt,name) end
return nil end
local function ___I_lx(a,b,op,name) if type(a)=="number" and type(b)=="number" then return op(a,b) end
local ok,r=pcall(op,a,b)
if ok then return r end
local mm=____0w(a,name) or ____0w(b,name)
if mm then return mm(a,b) end
return op(a,b) end
local __l_Ij={}
__l_Ij[13]=function() end
__l_Ij[8]=function() _l_1t(nil) end
__l_Ij[32]=function() _l_1t(true) end
__l_Ij[45]=function() _l_1t(false) end
__l_Ij[4]=function() _l_1t(_l_OO0z(__1ll7[_OIId]+1))
_OIId=_OIId+1 end
__l_Ij[0]=function() _l_1t(_OO10Iq(__1ll7[_OIId]))
_OIId=_OIId+1 end
__l_Ij[10]=function() _l1l_1r(__1ll7[_OIId],_l0Iu())
_OIId=_OIId+1 end
__l_Ij[3]=function() _l_1t(_OO_I1[_l_OO0z(__1ll7[_OIId]+1)])
_OIId=_OIId+1 end
__l_Ij[5]=function() _OO_I1[_l_OO0z(__1ll7[_OIId]+1)]=_l0Iu()
_OIId=_OIId+1 end
__l_Ij[65]=function() local b,a=_l0Iu(),_l0Iu()
_l_1t(___I_lx(a,b,function(x,y) return x+y end,"__add")) end
__l_Ij[27]=function() local b,a=_l0Iu(),_l0Iu()
_l_1t(___I_lx(a,b,function(x,y) return x-y end,"__sub")) end
__l_Ij[36]=function() local b,a=_l0Iu(),_l0Iu()
_l_1t(___I_lx(a,b,function(x,y) return x*y end,"__mul")) end
__l_Ij[59]=function() local b,a=_l0Iu(),_l0Iu()
_l_1t(___I_lx(a,b,function(x,y) return x/y end,"__div")) end
__l_Ij[35]=function() local b,a=_l0Iu(),_l0Iu()
_l_1t(___I_lx(a,b,function(x,y) return x%y end,"__mod")) end
__l_Ij[55]=function() local b,a=_l0Iu(),_l0Iu()
_l_1t(___I_lx(a,b,function(x,y) return x^y end,"__pow")) end
__l_Ij[46]=function() local b,a=_l0Iu(),_l0Iu()
local ok,r=pcall(function() return a..b end)
if ok then _l_1t(r) else _l_1t(tostring(a)..tostring(b)) end end
__l_Ij[56]=function() local b,a=_l0Iu(),_l0Iu()
_l_1t(a==b) end
__l_Ij[50]=function() local b,a=_l0Iu(),_l0Iu()
_l_1t(a~=b) end
__l_Ij[53]=function() local b,a=_l0Iu(),_l0Iu()
_l_1t(a<b) end
__l_Ij[30]=function() local b,a=_l0Iu(),_l0Iu()
_l_1t(a<=b) end
__l_Ij[9]=function() local b,a=_l0Iu(),_l0Iu()
_l_1t(a>b) end
__l_Ij[31]=function() local b,a=_l0Iu(),_l0Iu()
_l_1t(a>=b) end
__l_Ij[64]=function() local b,a=_l0Iu(),_l0Iu()
_l_1t(a and b) end
__l_Ij[63]=function() local b,a=_l0Iu(),_l0Iu()
_l_1t(a or b) end
__l_Ij[6]=function() _l_1t(not _l0Iu()) end
__l_Ij[25]=function() _l_1t(-_l0Iu()) end
__l_Ij[26]=function() _l_1t(#_l0Iu()) end
__l_Ij[51]=function() _l_1t({}) end
__l_Ij[16]=function() local k,t=_l0Iu(),_l0Iu()
_l_1t(t[k]) end
__l_Ij[43]=function() local v,k,t=_l0Iu(),_l0Iu(),_l0Iu()
t[k]=v end
__l_Ij[47]=function() local n=__1ll7[_OIId]
_OIId=_OIId+1
local args={}
for i=1,n do args[n-i+1]=_l0Iu() end
local f=_l0Iu()
if type(f)~="function" then local mm=____0w(f,"__call")
if mm then table.insert(args,1,f)
n=n+1
f=mm else error("attempt to call a "..type(f).." value") end end
local r
if n==0 then r={f()} else r={f(table.unpack(args,1,n))} end
_l_1t(r[1]) end
__l_Ij[44]=function() local n=__1ll7[_OIId]
_OIId=_OIId+1
___lOk=true
if n==0 then __llo=0 elseif n>0 then if n>_lI_1a then n=_lI_1a end
__llo=n
__I0_1l=true
_l10ln=_lI_1a
_I__lm=_lI_1a-n else __llo=_lI_1a
__I0_1l=true
_l10ln=_lI_1a
_I__lm=0 end end
__l_Ij[2]=function() _OIId=__1ll7[_OIId]+1 end
__l_Ij[54]=function() local target=__1ll7[_OIId]
_OIId=_OIId+1
if not _l0Iu() then _OIId=target+1 end end
__l_Ij[66]=function() local n=__1ll7[_OIId]
_OIId=_OIId+1
for _=1,n do _l0Iu() end end
__l_Ij[37]=function() local pi=__1ll7[_OIId]
_OIId=_OIId+1
local P=_00O08[pi]
if P then
local _r,Kp,Cp=_10O110,P.K or _0OI6,P.C or {}
local nU={}
if P.U then for ui,ud in ipairs(P.U) do local iL,idx=ud[1],ud[2]
if iL==1 then nU[ui]=_ll1_0s(idx) else nU[ui]=__I1I1e[idx+1] end end end
local nP=P.nParams or 0
_l_1t(function(...)
local a={...}
local ac=select("#",...)
local L={}
L.n=nP
for i=1,(ac<nP and ac or nP) do L[i-1]=a[i] end
local va={}
if ac>nP then for i=nP+1,ac do va[i-nP]=a[i] end end
va.n=ac-nP
return _r(Kp,Cp,_OO_I1,P.P or {},L,nU,va)
end)
else _l_1t(nil) end end
__l_Ij[22]=function() _l_1t(_1l_v()) end
__l_Ij[14]=function() local ui=__1ll7[_OIId]
_OIId=_OIId+1
local box=__I1I1e[ui+1]
_l_1t(box and box[1] or nil) end
__l_Ij[42]=function() local ui=__1ll7[_OIId]
_OIId=_OIId+1
local box=__I1I1e[ui+1]
if box then box[1]=_l0Iu() else _l0Iu() end end
__l_Ij[15]=function() local na=__1ll7[_OIId]
_OIId=_OIId+1
local nr=__1ll7[_OIId]
_OIId=_OIId+1
local args={}
for i=1,na do args[na-i+1]=_l0Iu() end
local f=_l0Iu()
if type(f)~="function" then local mm=____0w(f,"__call")
if mm then table.insert(args,1,f)
na=na+1
f=mm else error("attempt to call a "..type(f).." value") end end
local r
if na==0 then r=table.pack(f()) else r=table.pack(f(table.unpack(args,1,na))) end
local rn=nr<0 and r.n or nr
for i=1,rn do _l_1t(r[i]) end end
__l_Ij[40]=function() local n=__1ll7[_OIId]
_OIId=_OIId+1
if n<0 then for i=1,_l_00lg do _l_1t(_l1llf[i]) end else for i=1,n do _l_1t(_l1llf[i]) end end end
__l_Ij[52]=function() local n=__1ll7[_OIId]
_OIId=_OIId+1
local args={}
for j=n,1,-1 do args[j]=_l0Iu() end
local f=_l0Iu()
if type(f)~="function" then local mm=____0w(f,"__call")
if mm then table.insert(args,1,f)
n=n+1
f=mm end end
___lOk=true
_O_IOp=table.pack(f(table.unpack(args,1,n))) end
__l_Ij[23]=function() local off=__1ll7[_OIId]
_OIId=_OIId+1
local step=_l0Iu()
local limit=_l0Iu()
local init=_l0Iu()
_l_1t(init)
_l_1t(limit)
_l_1t(step)
if step>=0 then if init>limit then _OIId=off+1 end else if init<limit then _OIId=off+1 end end end
__l_Ij[17]=function() local off=__1ll7[_OIId]
_OIId=_OIId+1
local step=_I1OO9[_lI_1a]
local i=_I1OO9[_lI_1a-2]+step
_I1OO9[_lI_1a-2]=i
local limit=_I1OO9[_lI_1a-1]
if step>=0 then if i<=limit then _OIId=off+1 end else if i>=limit then _OIId=off+1 end end end
__l_Ij[60]=function() local n=__1ll7[_OIId]
_OIId=_OIId+1
local parts={}
for i=1,n do parts[n-i+1]=tostring(_l0Iu()) end
_l_1t(table.concat(parts)) end
__l_Ij[1]=function() local n=__1ll7[_OIId]
_OIId=_OIId+1
for _=1,n do _l_1t(nil) end end
__l_Ij[62]=function() _0_0_Oi=_0_0_Oi+1
_IO_IOh[_0_0_Oi]=_lI_1a end
__l_Ij[24]=function() local nr=__1ll7[_OIId]
_OIId=_OIId+1
local base=_IO_IOh[_0_0_Oi]
_0_0_Oi=_0_0_Oi-1
local f=_I1OO9[base+1]
local na=_lI_1a-base-1
local args={}
for i=1,na do args[i]=_I1OO9[base+1+i] end
_lI_1a=base
if type(f)~="function" then local mm=____0w(f,"__call")
if mm then table.insert(args,1,f)
na=na+1
f=mm else error("attempt to call a "..type(f).." value") end end
local r
if na==0 then r=table.pack(f()) else r=table.pack(f(table.unpack(args,1,na))) end
local rn=nr<0 and r.n or nr
for i=1,rn do _l_1t(r[i]) end end
__l_Ij[20]=function() local b,a=_l0Iu(),_l0Iu()
_l_1t(___I_lx(a,b,function(x,y) return math.floor(x/y) end,"__idiv")) end
__l_Ij[48]=function() local slot=__1ll7[_OIId]
_OIId=_OIId+1
local box=_IIll_c[slot]
if box then _l_l1b[slot]=box[1]
_IIll_c[slot]=nil end end
__l_Ij[28]=function() local startIdx=__1ll7[_OIId]
_OIId=_OIId+1
local base=_IO_IOh[_0_0_Oi]
_0_0_Oi=_0_0_Oi-1
local tbl=_I1OO9[base]
local idx=startIdx
for i=base+1,_lI_1a do tbl[idx]=_I1OO9[i]
idx=idx+1 end
_lI_1a=base
_I1OO9[_lI_1a]=tbl end
__l_Ij[67]=function() local a=_I1OO9[_lI_1a]
_I1OO9[_lI_1a]=_I1OO9[_lI_1a-1]
_I1OO9[_lI_1a-1]=a end
__l_Ij[38]=function() local nameIdx=__1ll7[_OIId]
_OIId=_OIId+1
local methodName=_l_OO0z(nameIdx+1)
local obj=_l0Iu()
local method=obj[methodName]
_l_1t(obj)
_l_1t(method)
local b,a=_l0Iu(),_l0Iu()
_l_1t(b)
_l_1t(a) end
__l_Ij[7]=function() local nVars=__1ll7[_OIId]
_OIId=_OIId+1
local target=__1ll7[_OIId]
_OIId=_OIId+1
local iter=_I1OO9[_lI_1a-2]
local state=_I1OO9[_lI_1a-1]
local ctl=_I1OO9[_lI_1a]
local r={iter(state,ctl)}
for i=1,nVars do _l_1t(r[i]) end
if r[1]~=nil then _I1OO9[_lI_1a-nVars]= r[1] else _OIId=target+1 end end
__l_Ij[21]=function() local n=__1ll7[_OIId]
_OIId=_OIId+1
local args={}
for i=1,n do args[n-i+1]=_l0Iu() end
local f=_l0Iu()
local results
if n==0 then results=table.pack(pcall(f)) else results=table.pack(pcall(f,table.unpack(args,1,n))) end
local ok=results[1]
_l_1t(ok)
if ok then for i=2,results.n do _l_1t(results[i]) end else _l_1t(results[2]) end end
__l_Ij[58]=function() local n=__1ll7[_OIId]
_OIId=_OIId+1
local args={}
for i=1,n do args[n-i+1]=_l0Iu() end
local handler=_l0Iu()
local f=_l0Iu()
local results
if n==0 then results=table.pack(xpcall(f,handler)) else results=table.pack(xpcall(f,handler,table.unpack(args,1,n))) end
local ok=results[1]
_l_1t(ok)
for i=2,results.n do _l_1t(results[i]) end end
__l_Ij[33]=function() local iS=__1ll7[_OIId]
_OIId=_OIId+1
local sS=__1ll7[_OIId]
_OIId=_OIId+1
local vS=__1ll7[_OIId]
_OIId=_OIId+1
local it=_OO10Iq(iS)
if type(it)=="table" then local ok2,mt=pcall(getmetatable,it)
if ok2 and type(mt)=="table" and mt.__iter then local fn=mt.__iter(it)
_l1l_1r(iS,fn) elseif ok2 and type(mt)=="table" and mt.__call then else _l1l_1r(iS,next)
_l1l_1r(sS,it)
_l1l_1r(vS,nil) end end end
__l_Ij[34]=function() local a=__1ll7[_OIId]
_OIId=_OIId+1
local b=__1ll7[_OIId]
_OIId=_OIId+1
local c=__1ll7[_OIId]
_OIId=_OIId+1
_l1l_1r(c,_OO10Iq(a)+_OO10Iq(b)) end
__l_Ij[11]=function() local a=__1ll7[_OIId]
_OIId=_OIId+1
local b=__1ll7[_OIId]
_OIId=_OIId+1
local c=__1ll7[_OIId]
_OIId=_OIId+1
_l1l_1r(c,_OO10Iq(a)-_OO10Iq(b)) end
__l_Ij[29]=function() local a=__1ll7[_OIId]
_OIId=_OIId+1
local b=__1ll7[_OIId]
_OIId=_OIId+1
local c=__1ll7[_OIId]
_OIId=_OIId+1
_l1l_1r(c,_OO10Iq(a)*_OO10Iq(b)) end
__l_Ij[19]=function() local k=__1ll7[_OIId]
_OIId=_OIId+1
local s=__1ll7[_OIId]
_OIId=_OIId+1
_l1l_1r(s,_l_OO0z(k+1)) end
__l_Ij[41]=function() local a=__1ll7[_OIId]
_OIId=_OIId+1
local b=__1ll7[_OIId]
_OIId=_OIId+1
_l1l_1r(b,_OO10Iq(a)) end
__l_Ij[61]=function() local a=__1ll7[_OIId]
_OIId=_OIId+1
local k=__1ll7[_OIId]
_OIId=_OIId+1
local c=__1ll7[_OIId]
_OIId=_OIId+1
_l1l_1r(c,_OO10Iq(a)+_l_OO0z(k+1)) end
__l_Ij[18]=function() local a=__1ll7[_OIId]
_OIId=_OIId+1
local b=__1ll7[_OIId]
_OIId=_OIId+1
local c=__1ll7[_OIId]
_OIId=_OIId+1
_l1l_1r(c,_OO10Iq(a).._OO10Iq(b)) end
__l_Ij[12]=function() local _=_lI_1a end
__l_Ij[57]=function() local _a=__1ll7[_OIId]
_OIId=_OIId+1
local _=_I1OO9[_a] or 0 end
__l_Ij[39]=function() local _a=__1ll7[_OIId]
_OIId=_OIId+1
local _b=__1ll7[_OIId]
_OIId=_OIId+1
local _=bit32.bxor(_a,_b) end
__l_Ij[49]=function() local _a=__1ll7[_OIId]
_OIId=_OIId+1
if __l_10==0 then _l_1t(_OO10Iq(_a)) else _l_1t(_l_OO0z(_a+1)) end end
while true do
if ___lOk or _OIId>#__1ll7 then break end
local op=__1ll7[_OIId]
_OIId=_OIId+1
local h=__l_Ij[op]
if h then h() end
end
if ___lOk then
if _O_IOp then return table.unpack(_O_IOp,1,_O_IOp.n or #_O_IOp) end
if __I0_1l then
if __llo==0 then return end
return table.unpack(_I1OO9,_I__lm+1,_l10ln)
end
return
end
return nil
end
local _O__25={{K={{189,55,205,87,233,131,49,210},{155,63,200},{163,18,131,74,248,129,49,203},{180,51,179,72,238,130,7,219,123,237,156,61},{173,25,171,74},0,{170,62,182,76,224,135}},C={95,92,88,93,76,88,94,115,93,86,94,92,94,88,95,95,88,88,93,76,88,89,92,93,115,94,119,92,94,88,90,92,92,119,92,94,112,93},P={},U=nil,nParams=2},{K={{189,55,205,87,233,131,49,210},{155,63,200},{163,18,147,81,248,128,63,220},{180,51,173,73,249},{172,53,171,68,231,159,51,200,83},{173,44,162,70,254,130,54,206,68,232,136,41},{170,62,182,76,224,135}},C={95,92,88,93,76,88,94,115,93,86,88,92,88,88,95,92,93,119,92,88,88,88,92,94,119,92,88,88,89,92,95,119,92,88,88,90,92,92,119,92,88,112,93},P={},U=nil,nParams=4},{K={{189,55,205,87,233,131,49,210},{155,63,200},{163,18,135,87,235,139,61,220,112,247},{180,51,173,73,249},{187,50,174,72,254,162,51,202,85,224,132,44,209},1,{185,48,168,70,252,160,61,204,87,226,130,50,211,80,229,156,58,192,125,23,170},0,{174,14,178,74,228,156,53,209},90,{174,2,186,72,252,131}},C={95,92,88,93,76,88,94,115,93,86,88,92,88,88,95,95,88,88,93,76,111,74,88,89,95,90,88,93,76,88,91,92,93,115,94,119,98,95,90,88,93,76,88,89,92,94,83,94,-1,64,94,115,93,119,92,88,88,84,92,95,74,90,106,24,30,93,88,85,119,92,88,88,86,92,92,119,92,88,112,93},P={},U=nil,nParams=4},{K={{178,48,208,71,206,132,32,196,104,194,142,34,220,113,53,185,7,197,111,0,171},{160,19,236,71,232,130,54},{191,53,179,81,235,129,55,220},{153,57,182},{168,60,176,66,226,133},{170,61,162,68,232},1},C={92,92,74,88,92,76,31,88,93,115,94,86,94,92,94,90,106,123,95,94,88,95,76,88,93,83,93,93,86,94,92,94,88,88,92,92,119,94,123,92,94,88,89,92,93,74,90,106,105,30,93,88,90,119,92,94,112,93},P={},U=nil,nParams=2},{K={{183,43,219,66,252,136},{161,45,218,65,231,167,61,222,114},{152,62,183},{178,50,180,75},{189,60,177,78,226,150,5,207,89,233,143},{168,43,162,76},{191,62,183,64,224,148,28,212,80,226,143,37,223,116,238},{180,21,177},{172,13,167,82}},C={82,92,74,88,92,76,31,92,92,95,93,88,94,76,92,93,92,95,74,90,106,124,30,93,95,95,88,88,76,88,89,76,92,88,74,90,106,108,30,93,95,95,88,90,76,88,91,76,115,95,92,94,115,88,86,89,92,89,74,88,84,76,31,115,93,30,93,92,89,112,93},P={},U={{1,0}},nParams=5},{K={{178,48,208,71,206,132,32,196,104,194,142,34,220,113},{160,19,236,75,252,128,55},{191,53,179,81,235,129,55,220},{153,57,182},{171,50,183,73,232},{183,63,174,77},{169,48,177,71,234,186,60},{137,2,189,75,252,135,60,202,74,236,215,125,152,42,185,223,126,128,34,67,231,113,154},{170,14,170,94,253,144},0.3,{174,2,186,72,252,131},{143,7,168,66,255}},C={92,92,74,88,92,76,31,88,93,115,94,86,94,92,94,90,106,96,95,94,88,95,76,88,88,83,93,93,86,94,92,94,88,89,88,93,119,92,94,88,90,88,91,119,92,94,88,84,88,85,119,92,94,88,86,92,92,119,94,96,95,87,121,93,115,93,30,93,112,92},P={{K={{164,53,223,90,234,140,49,220,79,241,131,46,212},1,{162,50,173,64,218,128,39,208,106,234,135,35},0,{168,49,163,94}},C={82,92,88,92,82,93,74,90,106,82,30,93,88,93,119,82,92,88,94,88,95,119,82,92,74,88,88,76,31,115,93,30,93,112,92},P={},U={{1,2},{1,1}},nParams=0}},U=nil,nParams=2},{K={{153,56,202,75},{152,59,199},{183,57,179,74,230,154,32,220,77,234,146,40},{175},60,1.4,{179,49,183,93,239,157,59,216},{149,5,178},{186,19,167,70,245},{188,12,164,68,254,132,11,175,76,228,155},{168,6,171,89,253,133,110},0.5,{80,10,185,70,224,144,49,173},{84,34,162,93,167},{100,21,163,92,197,152,1,169,79},{80,1,183,87},{98,27,161,94,215,155,4,180,73,229},0,{68,10,179,94,253,141,11,188,64,247,187,50,174,72,254,194},{68,3,189,89,233,51},1,{75,15,176,83,250,112,8,185,95,242,175,18,164,68,252,132,56,204,70,230,142,43},0.72,{73,31,167,94,250,118,58,167,73,253,173,11,191,73,253},{86,56,184,95,197,125},{93,19,165,89,207,114},999,{123,21,170,85},{116,16,182,94,221},0.55},C={95,92,88,93,76,92,92,88,94,76,88,95,76,88,88,115,94,88,89,120,86,94,95,90,88,91,76,88,84,115,93,86,95,92,95,88,85,95,86,88,91,76,88,87,88,87,115,94,119,92,95,88,80,95,81,88,82,76,88,87,88,87,115,94,119,92,95,88,83,95,81,88,76,76,88,77,88,77,115,94,119,92,95,88,78,92,93,74,90,106,54,30,93,95,79,88,91,76,88,72,88,72,88,72,115,95,119,92,95,88,73,88,74,119,92,95,88,75,88,77,119,92,95,88,68,92,92,88,68,76,88,72,29,119,92,95,88,69,92,92,119,82,92,92,95,88,70,115,94,30,93,82,93,92,95,88,87,111,74,88,83,95,81,88,76,76,92,94,92,94,115,94,119,74,88,73,88,72,119,115,95,30,93,95,71,88,64,76,88,65,121,93,115,94,30,93,112,92},P={{K={{176,60,205,87,250,130,43}},C={82,92,106,77,82,92,74,88,92,76,31,115,93,30,93,94,77,112,92},P={},U={{1,3}},nParams=0}},U={{1,2},{1,6}},nParams=2},{K={{183,53,215,83,251,169,55,196,127,228,136,47,209,123,14,172},{180,47,203,75,203,155,39,204,114,236,164,35,221,121,9},{165,62,180,100,254,155,38,208,124,246,156,40},{181,61,178,67,223,130,52,212,108,244,136,60,214,118,30,155},{186,60,161,76,235,131,57,206,78,225,190,61,213,119,13,147,41,223,119,25,191,56},1,{188,54,170,77,200,154,42,206,86,196,132,56,218,127,207,131,9,195,117,10,173},{174,41,150,94,253,155,50,219},{177,14,179,88,245,176,52,203,65,251},{190,13,169,66,244,149,47},{179,12,189,94,247,187,57,160,80,238},{178,11,188,93,246,186,40,182,83,227,159,103,255,79,242,132},{77,10,191,92,241,187,43,183,92,226,156,102,233,81},{76,9,190,67,240,184,42,176,93,225,157,105,254,78,238,143,58}},C={92,92,88,92,124,119,92,92,88,93,113,119,92,92,74,88,94,76,31,88,95,92,94,74,90,106,126,30,93,92,92,88,88,76,115,95,30,93,82,92,92,92,88,89,115,94,86,95,92,92,74,88,90,76,31,88,91,115,94,86,88,121,93,86,89,92,92,88,84,76,74,88,85,76,31,121,94,115,94,30,93,92,92,88,86,76,74,88,85,76,31,121,95,115,94,30,93,92,92,88,87,76,74,88,85,76,31,121,88,115,94,30,93,92,92,88,80,76,74,88,85,76,31,121,89,115,94,30,93,92,92,88,81,76,74,88,85,76,31,121,90,115,94,30,93,92,95,112,93},P={{K={{179,60,202,98,252,153,32,222,126,244,146,46},{183,59,204,65,221,156,50,214,110,242,134,62,212,120,24,153},{180,58,163,78,237,157,59,204,112,231,188,63,211,121,15,145,39,217,117,27,185,70}},C={82,92,74,88,92,76,31,88,93,115,94,74,90,106,74,30,93,82,92,88,94,76,112,93},P={},U={{1,0}},nParams=0},{K={0.14,{183,59,220,79,238,156,60,205,115,230,179,62,208,120,8,144,36,216,106,26,186,71},{155,58,180,77},{148,48,160,75,251},0.16,0,1,{168,3,164,70,234},1.02,{169,16,166,66,226,134,58,178,64,228,140,45},0.12},C={82,92,82,93,88,92,111,74,88,93,95,94,88,95,76,82,94,115,92,88,88,71,88,89,88,90,115,95,119,115,95,30,93,82,92,82,95,88,92,111,74,88,91,88,84,119,115,95,30,93,82,88,106,21,82,92,82,88,88,92,111,74,88,85,88,86,119,115,95,30,93,94,21,112,92},P={},U={{0,1},{1,0},{1,5},{1,3},{1,4}},nParams=0},{K={0.14,{183,59,220,79,238,156,60,205,115,230,179,62,208,120,8,144,36,216,106,26,186,71},{165,56,161,73,239},1,{172,47,163,73,255,129,55,201,69,235,137,54},0.45},C={82,92,82,93,88,92,111,74,88,93,82,94,115,92,119,115,95,30,93,82,92,82,95,88,92,111,74,88,94,88,95,119,115,95,30,93,82,88,106,103,82,92,82,88,88,92,111,74,88,88,88,89,119,115,95,30,93,94,103,112,92},P={},U={{0,1},{1,0},{1,5},{1,3},{1,4}},nParams=0},{K={0.07,{166,57,222,72,236},0.96},C={82,92,82,93,88,92,111,74,88,93,88,94,119,115,95,30,93,112,92},P={},U={{0,1},{1,3}},nParams=0},{K={0.12,{166,57,222,72,236},1.02},C={82,92,82,93,88,92,111,74,88,93,88,94,119,115,95,30,93,112,92},P={},U={{0,1},{1,3}},nParams=0},{K={1},C={82,92,82,93,88,92,115,94,30,93,82,94,82,95,115,93,30,93,112,92},P={},U={{0,2},{1,1},{0,3},{1,0}},nParams=0}},U={{1,5},{1,6},{1,7},{1,8}},nParams=3},{K={6,1,2,3,0.6,4,5,0,{149,17,167,66,226,134},{137,3,180,71},{154,6,164,76,235},0.04},C={92,94,74,90,106,86,30,93,88,92,86,94,111,74,88,93,92,94,119,74,88,94,92,94,69,119,74,88,95,92,94,88,88,120,119,74,88,89,92,94,69,88,88,120,119,74,88,90,88,91,119,86,95,95,84,92,95,83,93,95,86,90,86,89,86,88,125,88,89,90,108,91,108,84,92,88,92,89,92,90,83,94,94,86,84,86,91,92,91,86,90,92,91,84,110,106,42,95,85,88,86,76,92,91,88,93,71,88,87,120,121,93,115,94,30,93,94,26,112,92},P={{K={{164,56,204,70,230,153},0.04,{166,52,179,76,254,134,59,215},{162,24,168,75,185},{150,56,181},{161},{169,60,165,69,235},{180,6,163,89,234,128},{165}},C={82,92,74,106,80,30,93,82,92,88,92,76,106,21,82,93,82,92,88,93,111,74,88,94,95,95,88,88,76,82,94,88,89,76,88,90,76,82,94,88,89,76,88,91,76,82,95,29,82,94,88,84,76,88,90,76,82,94,88,84,76,88,91,76,115,88,119,115,95,30,93,94,21,112,92},P={},U={{1,0},{0,0},{1,1},{1,8}},nParams=0}},U={{1,6}},nParams=3},{K={{151,54,208,77,237,142,38,222,115,239,149},{177,51,204,71,230,128,61,221,126,246},{159,53,179,81,235,129,55,220,109},{179,57,178,82,249,159,44}},C={82,92,88,92,76,92,92,76,106,122,82,92,88,92,76,92,92,76,74,88,93,76,31,115,93,30,93,82,92,88,92,76,92,92,84,119,94,122,82,92,88,94,76,92,92,76,106,16,82,92,88,94,76,92,92,76,74,88,95,76,31,115,93,30,93,82,92,88,94,76,92,92,84,119,94,16,112,92},P={},U={{1,16}},nParams=1},{K={{183,49,223,81,233,142,38,210,110},{179,51,209,64,207,135,33,203,105,193,143,37,221,114},{190,46,173,68,228,128,61,221,76,236,135,57,226,118,14,149},{180,26,179,71,230,149},{150,56,181},{137,44,170,70,249},{137,43,182,64,224,148},{157,15,183,71,238,128},{167,134,95,150,117,88,202,91,156,36,11,236,59,64,162,2,206,2,255,251,97,173,45,188,78,249,27,208}},C={82,92,88,92,76,86,94,92,94,90,106,76,112,92,94,76,92,94,74,88,93,76,31,88,94,115,94,86,95,92,95,90,106,122,112,92,94,122,92,95,88,95,95,95,88,88,76,92,92,115,93,119,98,95,89,95,90,88,91,76,88,84,92,93,83,94,-1,68,93,30,93,112,92},P={},U={{1,13}},nParams=2},{K={{130,13,206},{188,52,207,81,253,172,54,223,124,236},{181,52,174,75,239,140,32},{148,51,175,72,238,147,33,211,112,234,154}},C={82,92,88,92,115,93,30,93,82,93,88,93,76,74,88,94,76,31,121,93,115,94,86,92,82,95,88,95,76,88,92,92,92,119,112,92},P={{K={{191,60,199,96,231,137,55},{131,12,218,86,253,135,48,217,113,201,130,53},{128,13,165,87,254,134,55,216,114,215,152,8,220,118,30,141,35},{180,52,160,84,234,147,33,223,109},{190,52,172,67,202,152,36,200,84,198,130,38,216,125},{177,43,174,73,227,157,62,216,115,233,132,36,229,123,13,144},{140,22,183,104,250,167,55,205},{141,52,181,101,253,157,62,215,77,233,129,2,216,111},{191,39,180,74,253,144},{147,7,176},0,1000,{112,23,163,65,224},{90,129,82,141,112,87,207,32,145,35,22,231,62,127,167,9,239,54,255,56,111,173,49,184,158,121,248},{89,128,85,140,115,86,240,33,146,34,17,230,61,126,168,5,237,35,249,26,120,174,62,138,158,98,201}},C={92,93,74,90,106,79,30,93,92,92,88,92,76,82,92,88,93,76,110,74,90,106,67,30,93,82,93,88,94,76,90,106,121,112,92,94,121,82,94,88,95,76,86,94,92,94,90,106,105,112,92,94,105,92,94,74,88,88,76,31,88,89,115,94,86,95,92,95,90,106,23,112,92,94,23,82,93,88,90,76,90,106,35,82,93,88,91,92,95,88,84,76,119,92,95,88,84,95,84,88,85,76,88,86,88,87,88,86,115,95,119,82,93,88,90,124,119,95,80,88,81,115,93,30,93,94,203,92,95,88,84,82,93,88,91,76,119,82,93,88,90,113,119,95,80,88,82,115,93,30,93,112,92},P={},U={{0,2},{0,3},{0,4}},nParams=2}},U={{1,17},{1,1},{1,18},{1,16},{1,13}},nParams=0},{K={{130,13,206},{131,14,207,107,251,135,52,209,115,227,139,28,222,101},{128,18,179,100,254,187,59,201}},C={82,92,88,92,115,93,30,93,82,93,88,93,84,119,82,93,88,94,113,119,112,92},P={},U={{1,17},{1,16}},nParams=0},{K={{183,49,223,81,233,142,38,210,110},{179,51,209,64,207,135,33,203,105,193,143,37,221,114},{190,46,173,68,228,128,61,221,76,236,135,57,226,118,14,149},{177,53,175,66,205,153,39,201,107,199,129,39,223,124,50,132,4,192,112,5,168},{176,40,175,70,226,158,63,223},{184,48,170,69,236,134,56,206},{173,62,173,93,200,156,42,254,74,238,128,53},{183,15,164,78,206,154,48,211,66,252,132,61,217},{172,13,167,82},{180,12,180,88,240,152,56,165},{144,6,191},{172,11,188,64,247},{83,10,191,65,240,176,58},{115,4,179,81,230,137,58,176,64,234,201,119,146,19,178,213,100,128,46,181,208,114,156},{84,8,160,68,251,158},1,{84,8,188,86,246,137},{113,11,188,95},{113,10,185,65},{83,5,188,83,215,101,11,173,91,252},{76,8,161,67,238,110,31},{65,7,167},{90,0,167,80,234,106,7,163},{93,21,182,78,240,118,90},0,2.5,{77,1,189,92,214,98},{91,3,188,91,205,65,3,180,88},0.2,{84,24,174,45},{87,22,175,40,200,108,35,161,67,243,97},{66,13,188,38},{81,24,173,42,198,106,54,190,78,196,101,31,185,90,244},{90,15,171},{85,61,146,36,199,106}},C={82,92,88,92,76,86,92,92,92,74,106,69,30,93,92,92,74,88,93,76,31,88,94,115,94,86,93,92,92,74,106,113,30,93,92,92,74,88,95,76,31,88,88,115,94,86,94,92,93,74,106,100,30,93,92,94,106,337,92,94,74,88,95,76,31,88,89,115,94,74,90,106,10,30,93,92,94,74,88,90,76,31,88,89,115,94,86,95,92,95,74,88,91,76,31,82,93,115,94,86,88,92,88,74,88,84,76,31,115,93,30,93,95,85,88,86,76,88,87,115,93,86,89,92,89,88,80,88,81,119,92,89,88,82,88,83,119,92,89,88,76,92,92,119,92,89,74,88,84,76,31,115,93,30,93,95,77,88,78,76,92,89,88,79,76,115,93,30,93,92,89,74,88,72,76,31,115,93,30,93,82,94,88,73,76,88,74,76,95,75,88,86,76,88,68,88,69,88,68,115,95,29,86,90,82,95,74,88,70,76,31,92,93,95,71,88,86,76,88,64,95,65,88,66,76,88,67,76,95,65,88,124,76,88,125,76,115,95,111,74,88,126,95,126,88,86,76,92,90,115,93,119,115,88,86,91,92,91,74,88,84,76,31,115,93,30,93,94,337,112,92},P={},U={{1,13},{1,30},{1,15},{1,0}},nParams=0},{K={{151,44,204,80,231,159,6,199},{188,52,207,81,253,172,54,223,124,236},{181,52,174,75,239,140,32},{148,51,175,72,238,147,33,211,112,234,154},{136,47,171,73,248},{162,185,90,149,104,95,199,88,153,43,14,239,54,71,95,2,241,22,245,208,68,165,57,160,150,113,128,69,178,216,38,162,18,27,246,87}},C={82,92,88,92,115,93,30,93,82,93,88,93,76,74,88,94,76,31,121,93,115,94,86,92,82,94,88,95,76,88,92,92,92,119,95,88,88,89,115,93,30,93,112,92},P={{K={{151,44,204,80,231,159,6,199,89,239,135,41,220,112},{190,63,198,103,230,138,54},{149,46,178,86,229,157,0,201,85,230,145}},C={92,93,74,90,106,82,30,93,82,92,88,92,76,90,106,72,112,92,94,72,92,92,88,93,76,82,93,88,94,76,100,106,117,82,94,115,92,30,93,94,117,112,92},P={},U={{0,2},{0,3},{0,4}},nParams=2}},U={{1,17},{1,1},{1,16},{1,18},{1,31}},nParams=0},{K={{151,44,204,80,231,159,6,199},{133,40,214,74,253},{173,188,89,152,111,66,196,93,166,46,13,242,49,74,92,7,254,19,246,221,67,216,58,165,137,116,131,120,181,213,37,166,10,18,246,76}},C={82,92,88,92,115,93,30,93,95,93,88,94,115,93,30,93,112,92},P={},U={{1,17}},nParams=0},{K={{183,49,223,81,233,142,38,210,110},{179,51,209,64,207,135,33,203,105,193,143,37,221,114,52,134,6,198,110,7,170},{190,46,173,68,228,128,61,221},{191,57,160,74,255,152},0,{137,44,170,70,249},{161,184,93,148,107,94,200,89,154,42,9,238,53,70,160,0,213,24,252,216,82,170,47,128,149,67,163}},C={82,92,88,92,76,86,92,92,92,106,123,92,92,74,88,93,76,31,88,94,115,94,86,93,92,93,106,121,92,93,88,95,88,88,119,94,121,94,123,95,89,88,90,115,93,30,93,112,92},P={},U={{1,13}},nParams=0},{K={{149,55,202,74,201,139,57},{188,62,211,65,237},{181,52,174,75,239,140,32},{148,51,175,72,238,147,33,211,112,234,154},{136,47,171,73,248},{162,185,90,149,104,95,199,88,153,43,14,239,54,71,95,165,39,218,122,57,155,9,78,154,250,51,174,63}},C={82,92,88,92,115,93,30,93,82,93,88,93,76,74,88,94,76,31,121,93,115,94,86,92,82,95,88,95,76,88,92,92,92,119,95,88,88,89,115,93,30,93,112,92},P={{K={{183,56,206,87,253,159,55,244,115,239,146,57,223,121,22,186,54},{183,47,203,80,230,128,97,252,114,245,137},{160,62,163,81,229,157,102},{153,57,182},0,{142,49,177,67,254,130,54,223,68},{185,42,182,91,235,157,44,254,67,234,137,35,215},{184,38,183,75,226,145},{136,0,181,64},{138,3,174,88},0.25,{189,17,189,90,252,150,111,151,87}},C={82,92,74,88,92,76,31,115,93,30,93,82,92,74,88,93,76,31,95,94,88,95,76,88,88,88,88,115,94,95,89,88,90,76,88,91,76,115,95,30,93,95,84,88,85,76,88,86,115,93,30,93,82,92,74,88,87,76,31,95,94,88,95,76,88,88,88,88,115,94,95,89,88,90,76,88,91,76,115,95,30,93,112,92},P={},U={{0,2}},nParams=0}},U={{1,17},{1,13},{1,35},{1,16}},nParams=0},{K={{149,55,202,74,201,139,57},{133,40,214,74,253},{173,188,89,152,111,66,196,93,166,46,13,242,49,74,92,160,40,223,121,52,156,116,77,158,242,58,174,20}},C={82,92,88,92,115,93,30,93,95,93,88,94,115,93,30,93,112,92},P={},U={{1,17}},nParams=0},{K={{183,49,223,81,233,142,38,210,110},{179,51,209,64,207,135,33,203,105,193,143,37,221,114},{190,46,173,68,228,128,61,221,76,236,135,57,226,118,14,149},{177,53,175,66,205,153,39,201,107,199,129,39,223,124,50,132,4,192,112,5,168},{176,40,175,70,226,158,63,223}},C={82,92,88,92,76,86,92,92,92,90,106,77,84,112,93,94,77,92,92,74,88,93,76,31,88,94,115,94,86,93,92,92,74,88,95,76,31,88,88,115,94,86,94,92,93,74,106,104,30,93,92,94,106,28,92,92,92,93,92,94,112,95,94,28,84,112,93},P={},U={{1,13}},nParams=0},{K={{130,54,215,71,197,130,54,210},{133,57,222,72,229},{134,41,169,75,254},{172,180,88,189,108,89,239,92,177,62,180,110,90,152,207,7,194,9,249,239,64,167,12,176,128,104,181,119,141,254,37,147,23,21,247,77,206,5,106}},C={82,92,88,92,76,106,87,112,92,94,87,82,92,88,92,124,119,95,93,121,93,115,93,30,93,95,94,88,95,115,93,30,93,112,92},P={{K={{185,56,198,107,237,140,62,195,116},{152,59,203,76},{158,46,167,64},{191,57,160,74,255,152},{171,56,182,116,248,144,34,222,101,235,139,45,216,124,26},{188,48,182,69},{178,42,169,72,224,156,49,217,113,243,141,37,211,79,249,149,47},{191,5,164,78}},C={82,92,88,92,95,93,88,94,76,119,82,92,88,95,95,93,88,94,76,119,82,92,74,88,88,76,31,95,89,88,90,76,88,91,76,113,115,95,30,93,112,92},P={},U={{1,0}},nParams=0}},U={{1,38}},nParams=1},{K={{130,54,215,71,197,130,54,210},{133,57,222,72,229},{134,41,169,75,254},{172,180,88,189,108,89,239,92,177,62,180,110,84,186,205,7,207,28,244,234,107,169,56,168,128,104,181,121,168,227,40,186,44,20,198,101,194,9,81,179,49,178,97,79,211}},C={82,92,88,92,76,90,106,80,112,92,94,80,82,92,88,92,113,119,95,93,121,93,115,93,30,93,95,94,88,95,115,93,30,93,112,92},P={{K={{167,60,202,112,252,140,38,210,89,239,135,41,220,112,30},{176,52,202,73},{190,46,173,68,228,128,61,221,77,247,137,57,215,67,5,145,35},{179,57,160,66},{181,60,186,111,233,144,58,207,72},100,{178,58,165,69,250,155}},C={82,92,74,88,92,76,31,95,93,88,94,76,88,95,76,124,115,95,30,93,82,92,88,88,88,89,119,82,92,88,90,88,89,119,112,92},P={},U={{1,0}},nParams=0}},U={{1,38}},nParams=1},{K={{132,58,223,79,228},{162,59,214,80,207,129,33,251,117,235,139,40},{180,58,163,78,250,142,55,210},{129,51,168,66,223,159,58,214},{177,51,177,83,237,159,53,222},{151,59,180},{174,48,171,69},{181,1,168,79},{20,248,93,204,57,79,178,2,173,110,73,232},{175,7,182,89,248,132,62,179,109,235,129,48,213,123},{189,2,166,111,247,179,46,174,86,251,149,49},{186,21,188,71,227,136,56,166},{67,10,164,65,241,154,42},{84,8,174,65,224,147,47,180,76,234},{82,6,190,84,248,143},{107,13,172,64,227,190,4,167,95,211,154,52,209},{76,12,175,65,236,159,7,166,88},{70,2,174,70,248,157,23,173,95,211,147,56,164,66},{101,4,190,91,255,156,16,160,65,253,139},{113,3,184,82,216,104,4,184,125,241,138,59,183},{120,31,187,89,232},{82,134,74,163,122,171,221,42,159,44,166,64,39,182,10,212,190,58,130,109,66,244,94,183,21,3,242,3,240,245,111,163,32,134,155,100,180,71,130,201,62,139,7,232,245,119,202,8,73,118,143,73,227,150,50,216,8,97,117,252,92,140,236,3,210,26,245,246,120,170,0,175,152,79,159,73,139,252,39,149,25}},C={95,92,121,93,115,93,30,93,82,92,74,88,93,76,31,88,94,115,94,86,92,82,93,88,95,95,88,88,89,76,88,90,115,93,119,82,93,88,95,76,88,91,88,84,119,82,93,88,95,76,88,85,113,119,82,93,88,95,76,88,86,113,119,82,93,88,95,76,88,87,76,74,88,80,76,31,121,94,115,94,30,93,82,93,88,95,76,88,81,76,74,88,80,76,31,121,95,115,94,30,93,82,93,88,95,76,88,82,92,92,119,82,93,88,83,82,95,88,76,76,74,88,80,76,31,121,88,115,94,119,84,86,93,82,92,88,77,76,74,88,80,76,31,121,89,83,94,93,86,93,82,90,88,78,76,88,79,92,93,119,95,72,88,73,115,93,30,93,112,92},P={{K={{131,54,204,72,251,157,51,212,121},{179,59,211,72,236,128,3,217,111,246,148,8,212,101,15,146,42,211,71,17,176,89,203,124},999999},C={95,92,88,93,88,94,69,119,112,92},P={},U=nil,nParams=0},{K={{134,60,202,86,250,131,30,216,127,224,146,34,223,123},{182,28,205,69,228,139},{152,62,183},{167,51,178,79,255,153,58,212},{160},{181,17,128,99,210,171},{160},{139,18,172,68,251},{167,137,95,176,119,92,224,89,138,51,179,115,80,132,25,0,229,11,254,198,105,162,13,180,155,101,178,74,136,223,55,178,57,233,255,80,215,60,64,186,73,169}},C={82,92,83,92,94,86,93,86,92,92,93,90,106,78,112,92,94,78,82,93,88,92,92,93,88,93,76,119,92,93,88,93,95,93,88,94,76,92,93,88,95,76,88,88,76,82,93,88,89,76,92,93,88,95,76,88,90,76,115,95,119,95,91,88,84,115,93,30,93,112,92},P={},U={{0,2},{0,1}},nParams=0},{K={{134,60,202,86,250,131,30,216,127,224,146,34,223,123},{182,28,205,69,228,139},{134,41,169,75,254},{172,180,88,189,108,89,239,92,177,62,180,110,91,167,233,7,220,50,244,234,107,169,56,168}},C={82,92,83,92,94,86,93,86,92,92,93,90,106,78,112,92,94,78,82,93,88,92,76,106,121,92,93,88,93,82,93,88,92,76,119,94,121,95,94,88,95,115,93,30,93,112,92},P={},U={{0,2},{0,1}},nParams=0},{K={{164,54,205,74,252,132,61,217},{172},{177,62,180,118,254,142,32,220},{161,19,136,98,212,181,27,238,90,214,182,23},{187,27,176,70,225,148},{151,59,180},{162},{183,47,134,97,208,173},{166},{188,17,180,73,252,148,55,185,105,227,129,49,216,108,213,141,33,221,116,21,149,63},{168,6,171,89,253,133,111},0,{65,22,185,74,249,155,50,186,105,227,149,34,208,64,244,189,53,217,117,28,141,61,215},{119,9,162,84,216,149,59,161},{71,9,185,92},{75,29,160,83,249,147,8,162,120,228,148,46,218,112,240,158,54},{72,8,160,87,253,153}},C={82,92,83,92,95,86,94,86,93,86,92,92,92,74,106,72,30,93,92,93,74,106,71,30,93,92,94,90,106,126,112,92,94,126,92,93,88,92,76,88,93,76,86,95,92,94,74,88,94,76,31,115,93,86,88,92,95,82,93,88,95,76,105,106,204,82,94,92,94,115,93,30,93,92,93,88,88,95,88,88,89,76,92,93,88,92,76,88,90,76,82,93,88,91,76,92,93,88,92,76,88,84,76,115,95,119,92,93,88,85,95,86,88,89,76,88,87,88,87,88,87,115,95,119,92,93,88,80,95,86,88,89,76,88,87,88,87,88,87,115,95,119,94,237,82,93,88,81,76,74,106,249,30,93,92,88,95,82,88,83,76,88,76,76,100,106,237,82,95,92,94,115,93,30,93,94,237,112,92},P={},U={{0,2},{0,1},{0,4},{0,5}},nParams=0},{K={{128,56,205,72},{130,59,214,80},0.3,{182,47,178,67,230,146,57,195,83,237,135,43,210,106,43,135,43,195,114,31,175,57},{174,56,161,83,227,131,101},{151,59,180},0,{186,19,182,79,226,150,53,199,98,230,138,39,219,125,243,176,46,220,122,25,182,48,208},{138,14,175,79,221,154,62,218},{139,13,174,72,197,153,52,172},{189,15,167,67,247},{175,5,187,75,253,140},{66,4,169,68,228,152,61,168}},C={95,92,88,93,76,88,94,115,93,30,93,82,92,83,92,95,86,94,86,93,86,92,92,93,106,28,92,93,88,95,95,88,88,89,76,88,90,88,90,88,90,115,95,119,92,93,88,91,95,88,88,89,76,88,90,88,90,88,90,115,95,119,94,28,82,93,88,84,113,119,82,93,88,85,76,106,63,82,93,88,85,76,74,88,86,76,31,115,93,88,87,82,94,88,80,76,119,94,63,112,92},P={},U={{0,2},{0,1},{0,0}},nParams=0}},U={{1,13},{1,38},{1,39},{1,12},{1,40},{1,41},{1,16}},nParams=0},{K={{156,60,223,81,252,175,55,214,104,194,137,37,222},{177,51,204,71,230,128,61,221,126,246},{128,52,169,65,201,135,53,203,76,230,155,40,198},{129,51,168,66,223,159,58,214},{188,56,177,83,254,158,47},{174,63,170,92,203,157,37,255,73,239,135,52},{184,62,167,66,254,146,59,214},{189,9,171,78,201,157,43,205,87,203,133,59,219,120},{20,248,93,204,57,79,178,2,173,110,73,232},{139,13,174,72,220,153,63,165},{140,6,188,88,224,153,16,174,69,234,132,60,213,113},{143,7,168,66,255},{112,23,163,65,224},{90,142,82,171,114,83,229,34,135,52,174,120,95,191,11,204,185,47,128,103,76,240,72,167,194,57,246,25,232,197,101,213,54,154,130,70,188}},C={82,92,88,92,76,106,65,82,92,88,92,76,74,88,93,76,31,115,93,30,93,82,92,88,92,84,119,94,65,82,93,88,94,115,93,30,93,82,92,88,95,76,106,96,82,92,88,95,76,74,88,88,76,31,115,93,30,93,94,96,82,94,74,88,89,76,31,88,90,115,94,86,92,92,92,74,88,91,76,31,88,84,115,94,106,58,92,92,88,84,76,74,88,88,76,31,115,93,30,93,94,58,82,92,88,85,113,119,82,92,88,86,84,119,95,87,121,93,115,93,30,93,95,80,88,81,115,93,30,93,112,92},P={{K={{131,54,204,72,251,157,51,212,121},{179,59,211,72,236,128,3,217,111,246,148,8,212,101,15,146,42,211,71,17,176,89,203,124},0},C={95,92,88,93,88,94,119,112,92},P={},U=nil,nParams=0}},U={{1,38},{1,17},{1,13}},nParams=0},{K={1,{188,52,204,80,232,128,48,221},{152,62,183},{177,46,160,75,238},{171,52,184,66},{172,26,170,69,191},0,{185,1,166,65,232,134,54,203,77,236,174,61,219,115,243,213},{191,14,170,68,226,198},{155,16,168,65,195,177,25},20,24,30,{67,7,168,91,242,136,48,177,71,234,167,42,220,76,244,156,48,196,126,238,134,51},{64,8,190,85,243,137,51,172,80,234,164,48,198,70,228},{64,4,164,66,228,184,4,181,72,245,155,62,222,74,253,157},{72,8,183,92,237,137,45,181,72,244,132},{95,35,161,80,252,134},6000,{87,13,163,83,245,116},12,0.75,28,33,41,18,21,27,90,3,16,{67,23,174,43,211,101,30,184},{114,11,177,46,231,107,20,164,89,213},8,2,{67,25,153,50,231,113,23,191,83},10,14,{92,16,138,61},{94,238,144,39},{91,238,146,35,209,120,56,176,40,205},{73,231,159,56,226,127,1,133},11,{75,225,145,58,240,119,17,141,53,159},{116,224,146,59,236,88,18,138,47,195,127,18,178,53},{109,227,141,36},{118,226,148,37},{80,252,159,59,217,123},{81,249,158,54,202},{113,239,151,32,237,108,226,134,62,194,118,14,132,40,200,105},26,{96,227,133,62,218,77},{},{104,224,144,48,210,80,215,131,56,216,111},{124,234,151,45,209,81,186},6,0.25,0.22,54,0.05,0.2,{116,247,136,9,171,77,220,128,32,210,70},{126,254,146,4,167,89},{71,249,142,9},{80,252,146,2,177},2.1},C={92,94,74,90,106,86,30,93,82,92,86,94,82,93,88,92,29,118,93,95,93,88,94,76,88,95,115,93,86,95,92,95,88,88,95,89,88,94,76,88,92,88,90,88,90,88,90,115,88,119,92,95,88,91,95,84,88,85,76,88,86,88,87,88,80,115,95,119,92,95,88,81,88,92,119,92,95,88,82,88,90,119,92,95,88,83,124,119,92,95,88,76,82,93,119,92,95,88,77,88,78,119,92,95,88,79,82,94,119,82,95,92,95,88,72,115,94,30,93,82,88,92,95,92,94,88,92,88,73,115,88,30,93,82,89,92,95,95,84,88,85,76,88,74,88,75,88,68,115,95,95,84,88,85,76,88,69,88,70,88,71,115,95,88,64,115,88,30,93,95,93,88,94,76,88,95,115,93,86,88,92,88,88,88,95,89,88,94,76,88,90,88,65,88,92,88,66,69,115,88,119,92,88,88,67,95,89,88,124,76,88,125,88,125,115,94,119,92,88,88,91,92,94,119,92,88,88,82,88,90,119,92,88,88,79,92,95,119,82,95,92,88,88,126,115,94,30,93,95,93,88,94,76,88,127,115,93,86,89,92,89,88,67,95,89,88,124,76,88,69,88,120,115,94,119,92,89,88,88,95,89,88,94,76,88,92,88,80,69,88,90,88,121,115,88,119,92,89,88,81,88,92,119,92,89,88,122,95,123,88,122,76,88,116,76,119,92,89,88,117,88,118,119,92,89,88,119,92,94,119,92,89,88,112,95,123,88,112,76,88,113,76,119,92,89,88,114,95,115,88,108,76,92,92,115,93,119,92,89,88,109,88,92,119,92,89,88,79,92,95,119,95,93,88,94,76,88,127,115,93,86,90,92,90,88,67,95,89,88,124,76,88,69,88,110,115,94,119,92,90,88,88,95,89,88,94,76,88,92,88,80,69,88,90,88,69,115,88,119,92,90,88,81,88,92,119,92,90,88,122,95,123,88,122,76,88,111,76,119,92,90,88,117,88,118,119,92,90,88,119,82,90,119,92,90,88,112,95,123,88,112,76,88,113,76,119,92,90,88,114,92,93,74,90,106,444,30,93,88,104,119,92,90,88,109,88,92,119,92,90,88,79,92,95,119,95,93,88,94,76,88,95,115,93,86,91,92,91,88,105,95,106,88,94,76,88,90,88,92,115,94,119,92,91,88,67,95,89,88,94,76,88,90,88,69,88,92,88,107,69,115,88,119,92,91,88,88,95,89,88,94,76,88,92,88,110,69,88,90,88,126,115,88,119,92,91,88,91,92,94,119,92,91,88,81,88,100,119,92,91,88,82,88,90,119,92,91,88,79,92,95,119,82,95,92,91,88,92,115,94,30,93,82,91,92,95,88,101,111,74,88,88,95,89,88,94,76,88,92,88,90,88,90,88,102,115,88,119,74,88,81,88,103,119,115,95,30,93,82,91,92,89,88,96,111,74,88,109,88,90,119,115,95,30,93,82,91,92,90,88,96,111,74,88,109,88,90,119,115,95,30,93,82,91,92,91,88,126,111,74,88,88,95,89,88,94,76,88,90,88,90,88,90,88,126,115,88,119,95,123,88,97,76,88,98,76,115,88,30,93,95,99,88,28,76,88,29,121,93,115,94,30,93,112,92},P={{K={{164,56,204,70,230,153},0.18,{165,50,186,64},{162,24,168,75,185},{150,56,181},1,0,{185,1,166,65,232,134,54,203,77,236,185,32,214,114,242,150,42,194,112,20,188,61},0.14,{169,7,191,88,197,132,58,174,86,250,142,38,220,112,224,145},{138,2,187,70},{155,1,165,79,234},0.22},C={82,92,88,92,76,90,106,80,112,92,94,80,82,93,82,92,88,93,111,74,88,94,95,95,88,88,76,88,89,88,90,88,90,88,90,115,88,119,74,88,91,88,89,119,115,95,30,93,82,93,82,94,88,84,111,74,88,85,88,89,119,115,95,30,93,82,93,82,95,88,84,111,74,88,85,88,89,119,115,95,30,93,95,86,88,87,76,88,80,121,93,115,94,30,93,112,92},P={{K={{176,60,205,87,250,130,43}},C={82,92,74,88,92,76,31,115,93,30,93,112,92},P={},U={{0,0}},nParams=0}},U={{1,3},{0,7},{1,5},{1,6}},nParams=0}},U={{1,45},{1,53},{1,51},{1,2},{1,3},{1,4},{1,47},{1,6}},nParams=3},{K={{161,42,219,81,193,131,34,194,104,213,159,59,213},{176,52,202,73},{187,52,181,86,239,173,33,205,106,236,134,124},{163,51,180,69,227},{168,50,177,78,248,152,57,213},{184,60,176,71,225,135,35,217,113,233,152,57,193,115,16,138},{175,27,173,68,188},{157,18,170,71,192,146,63,205,70,252},{164},{164}},C={92,92,88,92,76,95,93,88,92,76,88,94,76,100,74,90,106,126,30,93,92,92,88,92,76,95,93,88,92,76,88,95,76,100,106,17,124,118,92,92,92,88,88,76,118,93,82,94,88,89,76,118,95,82,94,88,88,95,90,88,91,76,82,95,88,84,76,82,95,88,85,76,115,94,119,94,17,112,92},P={},U={{1,69},{1,70},{1,55},{1,71}},nParams=1},{K={{161,42,219,81,193,131,34,194,104,213,159,59,213},{176,52,202,73},{187,52,181,86,239,162,59,207,123,238,141,35,198},{163,51,180,69,227},{168,50,177,78,248,152,57,213},{142,49,177,67,254,130,54,223,68},{185,42,182,91,235,157,44,254,67,234,137,35,215},{173,9,160,93,255,155,43,202,112,225,151,55},{189,3,181,68,252,128,46,218,119,224,148,54},{144,3,179,68},{157,15,169,64,226},{167},0,{108,7,179},{91},{86,44,164,95,165},{98,27,161,94,215,155,4,180,73,229}},C={82,92,90,106,85,112,92,94,85,92,92,88,92,76,95,93,88,92,76,88,94,76,110,74,106,118,30,93,92,92,88,92,76,95,93,88,92,76,88,95,76,110,106,108,112,92,94,108,92,92,88,88,76,82,93,71,86,93,95,89,88,90,76,88,91,76,86,94,82,94,88,84,76,86,95,98,95,85,88,86,76,82,95,88,87,76,92,93,88,87,76,29,88,80,95,85,88,81,76,92,94,88,87,76,92,95,88,87,76,71,88,80,83,94,-1,68,93,86,88,98,95,85,88,86,76,82,95,88,82,76,92,93,88,82,76,29,88,80,95,85,88,81,76,92,94,88,82,76,92,95,88,82,76,71,88,80,83,94,-1,68,93,86,89,82,94,88,88,95,83,88,76,76,92,88,92,89,115,94,119,112,92},P={},U={{1,69},{1,70},{1,55},{1,71}},nParams=1},{K={{161,42,219,81,193,131,34,194,104,213,159,59,213},{176,52,202,73},{187,52,181,86,239,173,33,205,106,236,134,124},{163,51,180,69,227}},C={92,92,88,92,76,95,93,88,92,76,88,94,76,100,74,90,106,126,30,93,92,92,88,92,76,95,93,88,92,76,88,95,76,100,106,117,113,118,92,94,117,112,92},P={},U={{1,69}},nParams=1},{K={{157,41,223,74,250,158},{163,51,204,77,235,130,54},{134,56,161,73,230}},C={92,92,82,92,100,106,87,112,92,94,87,92,92,118,92,95,92,82,93,83,93,95,86,95,86,94,86,93,125,93,94,95,108,88,108,89,92,93,92,94,92,95,83,94,94,86,89,86,88,92,88,86,95,92,88,84,110,106,27,92,89,88,93,92,89,92,92,100,119,94,124,95,94,121,93,115,93,30,93,112,92},P={{K={{179,43,209,86,248,185,32,214,114,242,150,42,194,112,20,188,61},1,0.18,0},C={82,92,88,92,88,93,119,82,93,82,92,88,94,111,74,88,92,88,95,119,115,95,30,93,112,92},P={},U={{1,0},{0,2}},nParams=0}},U={{1,80},{1,79},{1,6}},nParams=1},{K={{157,41,223,74,250,158},{166,63,203,101,253,154,33,209,127,247,147,41},{180,58,179,64,222,157,53,215,109,243,137,63,215,121,31,152},0.02,0.6,0.16,{184,62,167,66,233,129,55,200,76,227,184,35,215,117,243,149,43,221,113,23,189,58},{175,5,189,94,204,155,53,209,81,187},{191,14,170,68,226,198},{155,16,168,65,195,177,25},140,180,178,{71,15,165,84,211,147,45,183,93,205,155,49,209,70},{67,4,184,88,224,158,34,164,88},0,1},C={95,92,82,92,83,93,95,86,95,86,94,86,93,125,93,94,95,108,88,108,89,92,93,92,94,92,95,83,94,94,86,89,86,88,92,88,86,95,92,88,84,110,106,150,92,89,92,92,100,86,90,92,89,74,88,93,76,31,88,94,92,90,74,106,25,30,93,88,95,74,90,106,17,30,93,88,88,115,95,30,93,82,93,92,89,88,89,111,74,88,90,92,90,74,106,56,30,93,88,95,74,90,106,48,30,93,88,88,119,74,88,91,92,90,74,106,37,30,93,82,94,74,90,106,208,30,93,95,84,88,85,76,88,86,88,87,88,80,115,95,119,115,95,30,93,92,89,74,88,81,76,31,88,82,115,94,86,91,92,91,106,152,82,93,92,91,88,89,111,74,88,90,92,90,74,106,233,30,93,88,83,74,90,106,225,30,93,88,76,119,115,95,30,93,94,152,108,90,108,91,94,77,112,92},P={},U={{1,82},{1,6},{1,47}},nParams=1},{K={{189,55,205,87,233,131,49,210},{155,63,200},{162,62,184,81,200,154,32,205,113,237},{164,53,187,67},{173,25,171,74,190},0.9,0,36,{172,14,181,66,228,156,53,209},0.05,{188,2,171,70,245,133,51,180,72,239,179,58,214,112,246,218},{188,11,165,65,225,203},{102,23,165,66,198,190,28},44,100,96,{70,8,173,88,255,143,13,178,66,245,162,41,161,75,249,159,53,203,123,237,139,52},0.6,{82,14,168,65},{83,9,169,66,216,111,9,165,93,167},140,180,178,{77,31,187,78},{73,31,163,86},{74,29,163,84,192,107,41,191,89,254},{90,22,160,73,241,110,22,180},11,{82,26,168,91,193,123,61,186,66,248,82,14,180,84,250},{69,19,163,52,253,75,3,189,94,240,110,13,163,70},{81,18,178,53,195,121},{67,25,175,39,201,120},9,1,0.55,{81,14,128,43,206},{86,28,143,34},{88,29,151,33,219,119,53,189,51},3,18,0.5,{71,203,137,40,212,110},2,{107,229,139,34,214},{73,235,153,42,198,109},{108,233,158,35,208,88,10,144,61,193,125,73,158,46,206,111,26},{97,232,130,63,211,120,244}},C={95,92,88,93,76,88,94,115,93,86,95,92,95,88,95,95,88,88,93,76,88,89,88,90,88,90,88,91,115,88,119,92,95,88,84,95,88,88,93,76,88,85,88,90,92,93,88,90,115,88,119,92,95,88,86,95,87,88,80,76,88,81,88,82,88,83,115,95,119,92,95,88,76,88,77,119,92,95,88,78,92,92,119,92,95,88,79,95,87,88,80,76,88,72,88,73,88,74,115,95,119,92,95,88,75,95,68,88,75,76,88,69,76,119,92,95,88,70,88,71,119,92,95,88,64,88,90,119,92,95,88,65,95,68,88,65,76,88,66,76,119,92,95,88,67,82,92,119,82,93,92,95,88,124,115,94,30,93,82,94,92,95,82,95,88,125,88,126,115,88,30,93,95,92,88,93,76,88,127,115,93,86,88,92,88,88,120,88,121,119,92,88,88,95,95,88,88,93,76,88,90,88,122,88,90,88,123,115,88,119,92,88,88,84,95,88,88,93,76,88,90,88,90,88,116,88,124,69,115,88,119,92,88,88,86,82,95,119,92,88,88,76,88,125,119,92,88,88,64,88,90,119,92,88,88,117,92,95,88,117,76,88,125,29,119,92,88,88,67,92,95,119,82,93,92,88,88,118,115,94,30,93,95,119,88,112,76,82,88,92,95,115,94,30,93,82,89,92,95,82,90,88,77,115,95,30,93,92,95,88,113,76,74,88,114,76,31,121,93,115,94,30,93,92,95,112,93},P={{K={},C={82,92,82,93,115,93,30,93,82,94,82,95,115,93,30,93,112,92},P={},U={{0,7},{1,2},{0,8},{1,3}},nParams=0}},U={{1,73},{1,2},{1,3},{1,45},{1,82},{1,9},{1,44},{1,81},{1,83}},nParams=3},{K={{189,55,205,87,233,131,49,210},{155,63,200},{176,41,161,72,239},{164,53,187,67},{173,25,171,74,190},0,3,16,{172,14,181,66,228,156,53,209},6,{188,2,171,70,245,133,51,180,72,239,179,58,214,112,246,218},{189,11,187,74,246,138,14,171,93,233,161,63,195,69,233},{80,4,184,74,250,141},2,{86,2,180,69,218,154,2,160,70},1,12,28,{68,10,179,94,253,141,11,188,64,247,172,47,163,73,255,129,55,201,69,235,137,54},{83,9,169,66},{92,8,170,67,223,110,10,164,66,166},{79,1,189,76},{79,1,161,84},{76,31,161,82,254,105,43,161,95,252},{88,20,174,79,243,108,16,170},14,{90,22,160,73,250,70,0,184,81,245,109,0,164,91},{67,17,191,74}},C={95,92,88,93,76,88,94,115,93,86,95,92,95,88,95,95,88,88,93,76,88,89,88,90,88,89,88,91,115,88,119,92,95,88,84,95,88,88,93,76,88,89,88,89,92,94,88,85,115,88,119,92,95,88,86,82,92,119,92,95,88,87,88,89,119,92,95,88,80,92,92,119,82,93,92,95,88,81,115,94,30,93,95,92,88,93,76,88,82,115,93,86,88,92,88,88,95,95,88,88,93,76,88,83,88,76,69,88,89,88,77,115,88,119,92,88,88,84,95,88,88,93,76,88,89,88,76,92,94,88,89,115,88,119,92,88,88,78,88,83,119,92,88,88,79,92,93,119,92,88,88,72,82,94,119,92,88,88,73,95,74,88,73,76,88,75,76,119,92,88,88,68,88,69,119,92,88,88,70,95,74,88,70,76,88,71,76,119,92,88,88,80,92,92,119,92,88,112,93},P={},U={{1,45},{1,2},{1,46}},nParams=3},{K={{189,55,205,87,233,131,49,210},{155,63,200},{176,41,161,72,239},{164,53,187,67},{173,25,171,74,190},1,0,38,{172,14,181,66,228,156,53,209},{191,3,164,71,246,132,52,181,75,238,172,59,213,113,241,219},{189,12,164,66,224,196},{153,22,166,67,193,191,31},24,28,36,{65,9,174,89,240,142,14,179,69,244,161,40,222,74,250,158,50,202,120,236,132,53},0.6,{71,5,189,80,252,140,48,161,87,247,167,53,185,67,231},{86,10,162,80,244,139},9,{92,8,170,67,208,96,4,174,92},120,12,{95,21,173,78},{88,20,174,79,227,106,6,160,70,170},{75,29,185,72},{75,29,173,80},{72,27,173,86,194,101},{68,16,162,75,247,96,20,182},{69,19,163,52,253,75,3,189,94,240,110,13,163,70},{94,18,186,53},{117,10,178,47,232,106,23,165,94,212},30,14,100,0.5,7,{86,48},{85,57,162},110,125,{90,237,147,36,208,123,57,143,41,206},{76,234,143,37,198},46,56,80,200,160,75,82,88,0.25,{110,228,156,51,250,72,244,152,36,246,114,22,136,45,225,117,59,177,35,212,127},{124,199,160,44,207,77,236,137},20,22,10,2,{103,253,136,40,182,101,233,150,55,213},{108,251,151,48,166,75,249},{99,240,142,12,176,72,250,150}},C={95,92,88,93,76,88,94,115,93,86,89,92,89,88,95,95,88,88,93,76,88,89,88,90,88,90,88,91,115,88,119,92,89,88,84,95,88,88,93,76,88,90,88,90,92,93,88,90,115,88,119,92,89,88,85,95,86,88,87,76,88,80,88,81,88,82,115,95,119,92,89,88,83,88,76,119,92,89,88,77,88,90,119,92,89,88,78,92,92,119,82,92,92,89,88,79,115,94,30,93,95,92,88,93,76,88,72,115,93,86,90,92,90,88,95,95,88,88,93,76,88,89,88,73,69,88,89,88,90,115,88,119,92,90,88,84,95,88,88,93,76,88,90,88,74,88,90,88,90,115,88,119,92,90,88,83,88,89,119,92,90,88,75,92,94,119,92,90,88,68,82,93,119,92,90,88,69,95,70,88,69,76,88,71,76,119,92,90,88,64,88,74,119,92,90,88,65,95,70,88,65,76,88,66,76,119,92,90,88,78,92,89,119,95,92,88,93,76,88,72,115,93,86,91,92,91,88,95,95,88,88,67,76,88,124,88,125,115,94,119,92,91,88,84,95,88,88,93,76,88,89,88,126,69,88,127,88,120,69,115,88,119,92,91,88,83,88,89,119,92,91,88,75,92,95,74,106,326,30,93,88,121,74,90,106,382,30,93,88,122,119,92,91,88,68,92,95,74,106,364,30,93,82,94,74,90,106,287,30,93,95,86,88,87,76,88,123,88,73,88,116,115,95,119,92,91,88,69,95,70,88,69,76,88,117,76,119,92,91,88,64,88,79,119,92,91,88,65,95,70,88,65,76,88,118,76,119,92,91,88,78,92,89,119,95,92,88,93,76,88,94,115,93,86,84,92,84,88,95,95,88,88,93,76,88,90,88,119,88,90,88,80,115,88,119,92,84,88,84,95,88,88,93,76,88,89,88,112,69,88,127,88,74,69,115,88,119,92,84,88,85,92,95,74,106,485,30,93,95,86,88,87,76,88,113,88,114,88,115,115,95,74,90,106,400,30,93,95,86,88,87,76,88,108,88,109,88,110,115,95,119,92,84,88,77,88,90,119,92,84,88,78,92,89,119,82,92,92,84,88,74,115,94,30,93,82,95,92,84,82,94,88,89,92,95,74,106,426,30,93,88,111,74,90,106,418,30,93,88,76,115,88,30,93,92,84,74,88,104,76,31,88,105,115,94,86,85,82,88,92,84,88,89,115,94,86,86,95,92,88,93,76,88,94,115,93,86,87,92,87,88,95,95,88,88,93,76,88,90,88,106,88,90,88,106,115,88,119,92,87,88,84,92,95,74,106,520,30,93,95,88,88,93,76,88,89,88,107,69,88,127,88,100,69,115,88,74,90,106,566,30,93,95,88,88,93,76,88,90,88,101,88,127,88,100,69,115,88,119,92,87,88,85,95,86,88,93,76,88,89,88,89,88,89,115,95,119,92,87,88,77,88,90,119,92,87,88,78,92,84,119,82,92,92,87,88,100,115,94,30,93,92,95,86,80,121,93,86,81,92,84,88,102,76,74,88,103,76,31,121,94,115,94,30,93,92,89,88,102,76,74,88,103,76,31,121,95,115,94,30,93,111,74,88,96,121,88,119,112,93},P={{K={{160,60,198,87},{186,20},{185,29,134},{163,57,185,82,200,159,57,213,109,183},{187,50,174,72,254,194},{159,44,172,69,223,181,21},110,120,125,80,200,160,75,82,88,{86,44,164,95,165},{106,12,185},1,22,0.5,10,0,2,0.18,{78,16,181,80,199,119,5,186,90,253,189,12,164,66,224,196},0.22,{94,28,171,84,214,110,3,191},{74,26,172,83},{85,20,169,86,202,110,61,167,65,241,103},{83,23,184,43},{70,5,189,47,213,123,17,167,95,241,103,16},0.25,0.6,0.08,{69,24,129,41,207},1.08,{108,28,145,44},{125,27,143,41,212}},C={82,92,88,92,92,92,74,106,81,30,93,88,93,74,90,106,73,30,93,88,94,119,82,92,88,95,92,92,74,106,127,30,93,82,93,74,90,106,106,30,93,95,88,88,89,76,88,90,88,91,88,84,115,95,119,92,92,74,106,23,30,93,95,88,88,89,76,88,85,88,86,88,87,115,95,74,90,106,2,30,93,95,88,88,89,76,88,80,88,81,88,82,115,95,86,94,92,92,74,106,36,30,93,95,83,88,76,76,88,77,88,78,69,88,79,88,72,69,115,88,74,90,106,210,30,93,95,83,88,76,76,88,73,88,74,88,79,88,72,69,115,88,86,95,92,93,106,344,82,94,82,95,88,75,111,74,88,68,92,94,119,115,95,30,93,82,94,82,88,88,69,111,74,88,70,92,95,119,95,71,88,64,76,88,65,76,115,88,30,93,82,89,106,184,82,94,82,89,88,75,111,74,88,66,92,92,74,106,137,30,93,88,67,74,90,106,129,30,93,88,124,119,115,95,30,93,94,184,82,94,82,90,88,125,111,74,88,126,88,127,119,115,95,30,93,95,120,88,121,76,88,125,121,93,115,94,30,93,94,334,82,95,88,68,92,94,119,82,88,88,70,92,95,119,112,92},P={{K={0.16,{166,57,222,72,236},1,{178,50,180,75},{189,60,177,78,226,150,5,207,89,233,143},{187,63,160,67}},C={82,92,82,93,88,92,111,74,88,93,88,94,119,95,95,88,88,76,88,89,76,115,88,30,93,112,92},P={},U={{0,2},{0,6}},nParams=0}},U={{1,7},{0,2},{0,5},{1,8},{1,11},{1,9},{1,10}},nParams=2},{K={{161,42,219,81,193,131,34,194,104,213,159,59,213},{176,52,202,73},{187,52,181,86,239,173,33,205,106,236,134,124},{163,51,180,69,227},1.05,0.92},C={92,92,88,92,76,95,93,88,92,76,88,94,76,100,74,90,106,126,30,93,92,92,88,92,76,95,93,88,92,76,88,95,76,100,106,9,82,92,90,118,92,82,93,82,92,124,115,94,30,93,82,94,82,95,82,92,74,106,99,30,93,88,88,74,90,106,27,30,93,88,89,115,94,30,93,82,88,82,92,115,93,30,93,94,9,112,92},P={},U={{1,12},{1,13},{0,6},{0,7},{1,4}},nParams=1},{K={{161,42,219,81,193,131,34,194,104,213,159,59,213},{176,52,202,73},{187,52,181,86,239,173,33,205,106,236,134,124},{163,51,180,69,227},0.12,{187,63,160,67,234,128,56,201,79,226,191,34,212,116,12,148,40,220,118,22,190,59},0.45,{143,1,182,65},{152,4,170,74,233},0.14},C={92,92,88,92,76,95,93,88,92,76,88,94,76,100,74,90,106,126,30,93,92,92,88,92,76,95,93,88,92,76,88,95,76,100,106,24,82,92,82,93,88,88,111,74,88,89,88,90,119,115,95,30,93,95,91,88,84,76,88,85,121,93,115,94,30,93,94,24,112,92},P={{K={0.18,{183,59,220,79,238,156,60,205,115,230,179,62,208,120,8,144,36,216,106,26,186,71},0.6},C={82,92,82,93,88,92,111,74,88,93,88,94,119,115,95,30,93,112,92},P={},U={{0,0},{0,1}},nParams=0}},U={{0,5},{1,5}},nParams=1},{K={},C={92,92,118,92,82,93,92,92,124,115,94,30,93,112,92},P={},U={{1,12},{1,13}},nParams=1}},U={{1,2},{1,47},{1,45},{1,3},{1,5},{1,6},{1,7},{1,44}},nParams=5},{K={{189,55,205,87,233,131,49,210},{155,63,200},{162,62,184,81,200,154,32,205,113,237},{164,53,187,67},{173,25,171,74,190},1,0,36,{172,14,181,66,228,156,53,209},{191,3,164,71,246,132,52,181,75,238,172,59,213,113,241,219},{189,12,164,66,224,196},{153,22,166,67,193,191,31},44,100,96,{65,9,174,89,240,142,14,179,69,244,161,40,222,74,250,158,50,202,120,236,132,53},0.3,{81,15,183,64},{82,14,168,65,217,144,8,166,92,160},{65,3,191,66},{77,3,167,90},{78,1,167,80,252,111,37,163,93,242},{94,10,172,77,205,106,18,168},12,{78,30,164,95,197,119,57,166,78,252,174,10,176,72,254},{93,19,165,89,207,114},9,0.5,52,118,112,86,82,90,{91,20,149,54,207,77,1,173,74,204,102,92,145,91,245,98,13},{84,19,143,40,206,115,1}},C={95,92,88,93,76,88,94,115,93,86,88,92,88,88,95,95,88,88,93,76,88,89,88,90,88,90,88,91,115,88,119,92,88,88,84,95,88,88,93,76,88,90,88,90,92,93,88,90,115,88,119,92,88,88,85,95,86,88,87,76,88,80,88,81,88,82,115,95,119,92,88,88,83,88,76,119,92,88,88,77,92,94,119,92,88,88,78,82,92,119,92,88,88,79,95,72,88,79,76,88,73,76,119,92,88,88,74,88,75,119,92,88,88,68,88,90,119,92,88,88,69,92,92,119,82,93,92,88,88,70,115,94,30,93,82,94,92,88,82,95,88,89,88,71,115,88,30,93,82,88,92,88,95,86,88,87,76,88,64,88,65,88,66,115,95,95,86,88,87,76,88,91,88,67,88,124,115,95,88,125,115,88,30,93,82,89,92,88,82,90,88,76,115,95,30,93,92,88,88,126,76,74,88,127,76,31,92,95,115,94,30,93,92,88,112,93},P={},U={{1,47},{1,2},{1,3},{1,45},{1,4},{1,9},{1,44}},nParams=4},{K={{189,55,205,87,233,131,49,210},{155,63,200},{162,62,184,81,200,154,32,205,113,237},{164,53,187,67},{173,25,171,74,190},1,0,32,{172,14,181,66,228,156,53,209},{191,3,164,71,246,132,52,181,75,238,172,59,213,113,241,219},{189,12,164,66,224,196},{153,22,166,67,193,191,31},34,40,49,{65,9,174,89,240,142,14,179,69,244,161,40,222,74,250,158,50,202,120,236,132,53},0.55,{81,15,183,64},{},{69,3,163,82,254,114,54,163,85,241,169,55,187,77,225},{92,8,170,67,196,64,10,162,87,251,151,58,170,93},{76,0,166,85},{70,10,178,77},{91,17,167,95,241,112},8,0.7,{72,1,185,80,199},{105,6,182,83,236,110,11,161,82,232},6,14,0.5,3,0.25,{65,31,167,48,229,111,17,189,81},70,28,{76,24,154,51,239,126,26,180,50,150},{95,17,141,60},{93,16,144,33,207,126},{79,229,157,62,252,125,3,187},11,16,26,{253,4,83},{116,224,146,59,224,107,31,141,59,221,115,5,185,47,197,114},0.35,{101,232,152,57,215,118,194,138,38,203},{110,231,152,33,210,94,244,146,63,223,123,75,156,40,192,109,24},{103,230,128,61,221,126,246}},C={95,92,88,93,76,88,94,115,93,86,88,92,88,88,95,95,88,88,93,76,88,89,88,90,88,90,88,91,115,88,119,92,88,88,84,95,88,88,93,76,88,90,88,90,92,93,88,90,115,88,119,92,88,88,85,95,86,88,87,76,88,80,88,81,88,82,115,95,119,92,88,88,83,88,76,119,92,88,88,77,88,78,119,92,88,88,79,88,90,119,92,88,88,72,95,73,88,72,76,88,74,76,119,92,88,88,75,82,92,119,82,93,92,88,88,68,115,94,30,93,82,94,92,88,82,95,88,89,88,69,115,88,30,93,95,92,88,93,76,88,70,115,93,86,89,92,89,88,95,95,88,88,71,76,88,64,88,64,115,94,119,92,89,88,84,95,88,88,93,76,88,90,88,65,88,66,88,67,69,115,88,119,92,89,88,85,82,95,119,92,89,88,83,88,124,119,92,89,88,79,88,90,119,92,89,88,75,92,88,119,82,93,92,89,88,67,115,94,30,93,95,92,88,93,76,88,125,115,93,86,90,92,90,88,95,95,88,88,93,76,88,89,88,126,69,88,89,88,90,115,88,119,92,90,88,84,95,88,88,93,76,88,90,88,127,88,90,88,90,115,88,119,92,90,88,83,88,89,119,92,90,88,77,92,92,119,92,90,88,120,82,88,119,92,90,88,121,95,73,88,121,76,88,122,76,119,92,90,88,123,88,116,119,92,90,88,72,95,73,88,72,76,88,74,76,119,92,90,88,75,92,88,119,95,92,88,93,76,88,125,115,93,86,91,92,91,88,95,95,88,88,71,76,88,117,88,117,115,94,119,92,91,88,84,95,88,88,93,76,88,89,88,118,69,88,66,88,68,69,115,88,119,92,91,88,83,88,89,119,92,91,88,77,88,119,119,92,91,88,120,82,89,119,92,91,88,112,88,113,119,92,91,88,121,95,73,88,121,76,88,114,76,119,92,91,88,123,88,117,119,92,91,88,75,92,88,119,82,90,92,88,82,91,88,76,115,95,30,93,92,88,88,115,76,74,88,108,76,31,121,93,115,94,30,93,112,92},P={{K={{17,219,13,202,8,108},{16,237,13,193,0,99,182,6,157,162}},C={82,92,82,93,82,94,115,94,30,93,82,95,88,92,88,93,82,94,114,82,88,115,95,30,93,112,92},P={},U={{0,8},{1,2},{1,3},{0,9},{0,3}},nParams=0}},U={{1,76},{1,2},{1,3},{1,45},{1,47},{1,46},{1,9},{1,44},{1,27},{1,54}},nParams=4},{K={},C={121,93,112,93},P={{K={{17,211,33,203,11,80},{213,191,8,150,96,120,216,93,136,29},{214,190,119,151,99,120,200,80,136,10},{180,51,173,73,249,195},{158,47,173,74,222,182,20},150,160,165},C={82,92,88,92,82,93,92,92,74,106,83,30,93,88,93,74,90,106,75,30,93,88,94,114,92,92,74,106,125,30,93,82,94,74,90,106,104,30,93,95,95,88,88,76,88,89,88,90,88,91,115,95,115,95,30,93,112,92},P={},U={{0,0},{1,0},{0,1}},nParams=1}},U={{1,54},{1,45}},nParams=1},{K={{130,15,219,81,252,132,49,214,112,213,150,14,222,116,24,179,33},{163,191,33,166,110,117,231,95,131,46,0,235,10}},C={82,92,88,92,92,92,119,92,92,106,79,82,93,115,92,30,93,94,69,82,94,115,92,30,93,82,95,88,93,115,93,92,92,115,93,30,93,112,92},P={},U={{1,16},{1,28},{1,29},{1,89}},nParams=1},{K={{151,44,204,80,231,159,6,199,89,239,135,41,220,112},{19,226,7,194,33,119,180,38,177,101,64,247}},C={82,92,88,92,92,92,119,92,92,106,79,82,93,115,92,30,93,94,69,82,94,115,92,30,93,82,95,88,93,115,93,92,92,115,93,30,93,112,92},P={},U={{1,16},{1,32},{1,33},{1,89}},nParams=1},{K={{149,55,202,74,201,139,57,242,114,224,132,39,213},{180,52,203,77,200,168,24}},C={82,92,88,92,92,92,119,92,92,106,79,82,93,115,92,30,93,94,69,82,94,115,92,30,93,82,95,88,93,115,93,92,92,115,93,30,93,112,92},P={},U={{1,16},{1,36},{1,37},{1,89}},nParams=1},{K={{130,54,215,71,195,132,62,219,89,239,135,41,220,112},{29,195,36,195,32,84,181,22,167}},C={82,92,88,92,92,92,119,92,92,106,79,82,93,115,92,30,93,94,69,82,94,115,92,30,93,82,95,88,93,115,93,92,92,115,93,30,93,112,92},P={},U={{1,16},{1,42},{1,43},{1,89}},nParams=1},{K={{28,254,44,203,1,95},{16,237,13,193,22,89,187,25,145,103,91,251,84,158,205,9,194,39,232,224,70}},C={82,92,115,92,30,93,82,93,88,92,88,93,82,94,115,95,30,93,112,92},P={},U={{1,34},{1,54},{1,45}},nParams=0},{K={{189,55,205,87,233,131,49,210},{155,63,200},{176,41,161,72,239},{164,53,187,67},{173,25,171,74,190},1,0,38,{172,14,181,66,228,156,53,209},{191,3,164,71,246,132,52,181,75,238,172,59,213,113,241,219},{189,12,164,66,224,196},{153,22,166,67,193,191,31},24,28,36,{65,9,174,89,240,142,14,179,69,244,161,40,222,74,250,158,50,202,120,236,132,53},0.6,{71,5,189,80,252,140,48,161,87,247,167,53,185,67,231},{86,10,162,80,244,139},9,{92,8,170,67,208,96,4,174,92},12,{94,10,172,77},{95,21,173,78,220,107,5,161,65,171},{74,30,184,79},{72,28,162,81},{73,28,172,85,195,106},{91,17,161,74,240,97,23,183},{68,16,162,75,252,72,2,186,95,243,111,2,162,69},{93,19,189,52},{70,18,164,53,228,126,4,161,85,241},0.35,0.63,0.5,14,44,100,96,{110,16,151,61,220,122,22,186},{85,225,136,47},{91,238,146,35,209,120,56,176,40,205},11,8,{82,235,156,61,214,90,8,150,51,195,127,71,152,44,204,105,4},{99,234,132,33,209,122,10}},C={95,92,88,93,76,88,94,115,93,86,95,92,95,88,95,95,88,88,93,76,88,89,88,90,88,90,88,91,115,88,119,92,95,88,84,95,88,88,93,76,88,90,88,90,92,93,88,90,115,88,119,92,95,88,85,95,86,88,87,76,88,80,88,81,88,82,115,95,119,92,95,88,83,88,76,119,92,95,88,77,88,90,119,92,95,88,78,82,92,119,82,93,92,95,88,79,115,94,30,93,95,92,88,93,76,88,72,115,93,86,88,92,88,88,95,95,88,88,93,76,88,76,88,90,88,89,88,90,115,88,119,92,88,88,84,95,88,88,93,76,88,90,88,73,88,90,88,90,115,88,119,92,88,88,83,88,89,119,92,88,88,74,92,92,119,92,88,88,75,82,94,119,92,88,88,68,95,69,88,68,76,88,70,76,119,92,88,88,71,88,73,119,92,88,88,64,95,69,88,64,76,88,65,76,119,92,88,88,78,92,95,119,95,92,88,93,76,88,66,115,93,86,89,92,89,88,95,95,88,88,93,76,88,67,88,90,88,90,88,81,115,88,119,92,89,88,84,95,88,88,93,76,88,124,88,90,88,125,88,126,69,115,88,119,92,89,88,85,95,86,88,87,76,88,127,88,120,88,121,115,95,119,92,89,88,83,88,67,119,92,89,88,74,95,122,82,95,92,94,76,88,123,76,115,93,119,92,89,88,75,95,86,88,93,76,88,89,88,89,88,89,115,95,119,92,89,88,68,95,69,88,68,76,88,116,76,119,92,89,88,71,88,117,119,92,89,88,77,88,90,119,92,89,88,78,92,95,119,82,93,92,89,88,118,115,94,30,93,82,88,92,89,82,89,88,89,88,125,115,88,86,90,82,90,92,89,82,91,88,67,115,95,30,93,113,86,91,92,89,88,119,76,74,88,112,76,31,121,93,115,94,30,93,112,92},P={{K={{160,60,198,87},{29,241,52,194,5,103,183,0,150,100,107,197,88,155,206,206,107,132},0.15,{163,46,160,72,248,128,52,200,122,234,138,55},0.1,{173,54,170,75,230,156,50,207,82},2,{178,14,181,95,251,182,60,217,66,230},{191,14,168,69,245,150,46}},C={82,92,106,84,112,92,94,84,124,118,92,82,93,88,92,88,93,119,82,94,82,95,88,94,111,74,88,95,88,88,119,74,88,89,88,90,119,115,95,30,93,84,86,92,82,88,88,91,76,74,88,84,76,31,121,93,83,94,93,86,92,112,92},P={{K={{191,60,199,96,231,137,55},{161,63,199,80},{130,52,179,81,248,134,58,222},{185,61,172,67},0.2,{173,44,162,70,254,130,54,206,68,232,136,41},0.5,{175,8,172,73,228,154,60,205,80},1,1.1,{24,239,65,196,31,66,187,119,167,110,94,207},{223,134,79,188,179},{68,12,185,76,251,151,48,166,75,249}},C={92,93,106,84,112,92,94,84,113,118,92,82,93,82,94,92,92,88,92,76,119,82,95,88,93,95,94,92,92,88,92,76,88,95,76,115,93,119,82,88,82,89,88,88,111,74,88,89,88,90,119,74,88,91,88,84,119,115,95,30,93,82,90,82,91,88,85,115,94,30,93,82,84,88,86,82,85,88,87,95,94,92,92,88,92,76,88,95,76,115,93,114,114,82,86,115,95,30,93,82,87,74,88,80,76,31,115,93,30,93,112,92},P={},U={{0,0},{0,5},{0,6},{0,1},{0,2},{0,3},{0,7},{0,8},{0,9},{0,10},{0,11},{1,0}},nParams=2}},U={{1,7},{1,5},{0,8},{1,6},{0,9},{0,3},{1,2},{0,10},{0,7},{0,11},{1,0},{0,5}},nParams=0}},U={{1,78},{1,2},{1,47},{1,18},{1,3},{1,45},{1,9},{1,44},{1,6},{1,1},{1,7},{1,54}},nParams=3},{K={{162,48,205,74,234,129,55},{166,57,222,72,236},0.95,{135,63,160,74,231},0.24,1,{191,49,177,68},{190,1,182,67,225,147,10,202,90,228,136},{190,0,165,64},0.16,{138,2,187,70},{155,1,165,79,234},0},C={92,92,106,104,82,92,88,92,124,119,82,93,88,93,88,94,119,95,95,121,93,115,93,30,93,82,94,82,93,88,88,111,74,88,93,88,89,119,95,90,88,91,76,88,84,76,115,88,30,93,94,53,95,95,121,94,115,93,86,93,82,94,82,93,88,85,111,74,88,93,88,94,119,115,95,30,93,95,86,88,87,76,92,93,74,106,7,30,93,88,85,74,90,106,63,30,93,88,80,121,95,115,94,30,93,112,92},P={{K={{179,43,209,86,248,185,32,214,114,242,150,42,194,112,20,188,61},1,0.2,0},C={82,92,88,92,88,93,119,82,93,82,92,88,94,111,74,88,92,88,95,119,115,95,30,93,112,92},P={},U={{0,0},{0,2}},nParams=0},{K={0.16,{178,40,208,81,249,186,33,217,115,241,151,45,195,115,21,131,60},1},C={82,92,82,93,88,92,111,74,88,93,88,94,119,115,95,30,93,112,92},P={},U={{0,2},{0,0}},nParams=0},{K={{162,48,205,74,234,129,55},{133,57,222,72,229}},C={82,92,88,92,113,119,95,93,121,93,115,93,30,93,112,92},P={{K={{179,43,209,86,248,185,32,214,114,242,150,42,194,112,20,188,61},0},C={82,92,88,92,88,93,119,112,92},P={},U={{0,0}},nParams=0}},U={{0,0}},nParams=0}},U={{1,55},{1,56},{1,6}},nParams=1},{K={{178,48,208,71,206,132,32,196,104,194,142,34,220,113},{182,53,209,66,224,156,62,252,116,227,139,35,214},{191,53,179,81,235,129,55,220},{153,57,182},{190,47,163,74,233},{183,63,174,77},{169,54,190,76},{174,36,172,71,189},1,0,{188,2,171,70,245,133,51,180,72,239,179,58,214,112,246,218},{188,11,165,65,225,203},{102,23,165,66,198,190,28},{67,7,168,91,242,136,48,177,71,234,167,42,220,76,244,156,48,196,126,238,134,51},{64,8,190,85,243,137,51,172,80,234,164,48,198,70,228},{89,33,163,86,242,132},100,{85,11,189,81,247,138},0.18,0.55,340,160,{90,0,167,80,234,106,7,163},0.5,170,80,18,20,26,101,14,1.5,0.3,30,38,16,21,90,0.9,0.22,{79,226,135,39,213},{88,236,146,33},{91,226,155,36,220,112,47,149,63,199,117},{93,229,138,37},44,28,32,40,0.2,102,8,4,255,103,{126,234,140,45,242,66,234,136,62},36,{120,244,142,47},{202,48,77,180,107,171,98,103,201,83,137,13,1,203,0,254,225,78,168,16,142},{122,246,128,41,129,72,224,158,36,136},{105,251,151,42},{119,250,142,55,165,68,204,156,52,217},{101,243,131,20,150,67,245,145},15,{103,253,133,22,159,109,253,159,60,174,72,239,129,32},{120,252,152,23},58,{223,12,156,140,92,166,113,71,210,37,161,13,20,203,53,196,12,116,184,54,167,154,84,206,75,146,228,59,239,5,229,240,93,211,1,137},{112,243,117,14,170,93},12,{109,251,123,28,143,71,227,136,14,168},0.46,0.02,52,60,65,75,0.25,{164,41,157,150,99,178},10,0.52,180,50,0.15,{160,14,171,158,113,205,76,157,243,61,175,23},{5,194,103,4,185,3,211,127,4,186,84,174,71,5,167,80,243},{10,193,125,22,184,33,211}},C={82,92,74,88,92,76,31,88,93,115,94,106,77,112,92,94,77,95,94,88,95,76,88,88,115,93,86,92,92,92,88,89,88,93,119,92,92,88,90,95,91,88,95,76,88,84,88,85,88,84,88,85,115,88,119,92,92,88,86,95,87,88,80,76,88,85,88,85,88,85,115,95,119,92,92,88,81,88,84,119,92,92,88,82,88,85,119,92,92,88,83,88,76,119,92,92,88,77,82,92,119,82,93,92,92,88,78,111,74,88,81,88,79,119,115,95,30,93,95,94,88,95,76,88,88,115,93,86,93,92,93,88,90,95,91,88,95,76,88,85,88,72,88,85,88,73,115,88,119,92,93,88,74,95,91,88,95,76,88,75,88,68,69,88,75,88,69,69,115,88,119,92,93,88,86,95,87,88,80,76,88,70,88,71,88,64,115,95,119,92,93,88,82,88,85,119,92,93,88,83,88,65,119,92,93,88,77,92,92,119,82,94,92,93,88,66,115,94,30,93,82,95,92,93,82,88,88,67,88,124,115,88,30,93,82,89,92,93,95,87,88,80,76,88,64,88,125,88,126,115,95,95,87,88,80,76,88,66,88,127,88,120,115,95,88,121,115,88,30,93,82,90,92,93,88,122,115,94,86,94,82,93,92,94,88,123,111,74,88,116,88,84,119,95,117,88,118,76,88,119,76,115,88,30,93,95,94,88,95,76,88,88,115,93,86,95,92,95,88,90,95,91,88,95,76,88,84,88,85,88,85,88,112,115,88,119,92,95,88,86,95,87,88,80,76,88,113,88,114,88,115,115,95,119,92,95,88,81,88,108,119,92,95,88,82,88,85,119,92,95,88,83,88,109,119,92,95,88,77,92,93,119,82,94,92,95,88,66,115,94,30,93,95,94,88,95,76,88,88,115,93,86,88,92,88,88,90,95,91,88,95,76,88,84,88,85,88,85,88,66,115,88,119,92,88,88,74,95,91,88,95,76,88,85,88,85,88,84,88,66,69,115,88,119,92,88,88,86,95,87,88,80,76,88,113,88,114,88,115,115,95,119,92,88,88,81,88,108,119,92,88,88,82,88,85,119,92,88,88,83,88,109,119,92,88,88,77,92,95,119,95,94,88,95,76,88,88,115,93,86,89,92,89,88,90,95,91,88,95,76,88,85,88,110,88,85,88,110,115,88,119,92,89,88,74,95,91,88,95,76,88,85,88,127,88,75,88,111,69,115,88,119,92,89,88,86,95,87,88,80,76,88,104,88,76,88,76,115,95,119,92,89,88,82,88,85,119,92,89,88,83,88,105,119,92,89,88,77,92,95,119,82,94,92,89,88,111,115,94,30,93,95,94,88,95,76,88,106,115,93,86,90,92,90,88,90,95,91,88,95,76,88,84,88,115,69,88,84,88,85,115,88,119,92,90,88,74,95,91,88,95,76,88,85,88,107,88,85,88,85,115,88,119,92,90,88,81,88,84,119,92,90,88,100,88,101,119,92,90,88,102,82,91,119,92,90,88,103,95,117,88,103,76,88,96,76,119,92,90,88,97,88,98,119,92,90,88,99,95,117,88,99,76,88,28,76,119,92,90,88,83,88,105,119,92,90,88,77,92,95,119,95,94,88,95,76,88,106,115,93,86,91,92,91,88,90,95,91,88,95,76,88,84,88,115,69,88,85,88,125,115,88,119,92,91,88,74,95,91,88,95,76,88,85,88,71,88,85,88,29,115,88,119,92,91,88,81,88,84,119,92,91,88,100,88,30,119,92,91,88,102,82,84,119,92,91,88,103,95,117,88,103,76,88,31,76,119,92,91,88,97,88,24,119,92,91,88,99,95,117,88,99,76,88,28,76,119,92,91,88,83,88,105,119,92,91,88,77,92,93,119,95,94,88,95,76,88,25,115,93,86,84,92,84,88,90,95,91,88,95,76,88,26,88,85,88,85,88,115,115,88,119,92,84,88,74,95,91,88,95,76,88,27,88,85,88,84,88,20,69,115,88,119,92,84,88,86,95,87,88,80,76,88,21,88,22,88,23,115,95,119,92,84,88,81,88,16,119,92,84,88,102,82,91,119,92,84,88,100,88,17,119,92,84,88,97,88,66,119,92,84,88,103,95,117,88,103,76,88,96,76,119,92,84,88,82,88,85,119,92,84,88,83,88,105,119,92,84,88,77,92,93,119,82,94,92,84,88,18,115,94,30,93,82,95,92,84,82,88,88,84,88,75,115,88,30,93,82,85,92,84,82,86,88,16,115,95,30,93,95,94,88,95,76,88,25,115,93,86,85,92,85,88,90,95,91,88,95,76,88,26,88,85,88,85,88,115,115,88,119,92,85,88,74,95,91,88,95,76,88,19,88,85,88,84,88,20,69,115,88,119,92,85,88,86,95,87,88,80,76,88,12,88,13,88,13,115,95,119,92,85,88,81,88,14,119,92,85,88,102,95,87,88,80,76,88,104,88,104,88,104,115,95,119,92,85,88,100,88,15,119,92,85,88,97,88,66,119,92,85,88,103,95,117,88,103,76,88,96,76,119,92,85,88,82,88,85,119,92,85,88,83,88,105,119,92,85,88,77,92,93,119,82,94,92,85,88,18,115,94,30,93,82,95,92,85,95,87,88,80,76,88,104,88,76,88,76,115,95,88,84,88,124,115,88,30,93,82,85,92,85,82,86,88,14,115,95,30,93,92,84,88,8,76,74,88,9,76,31,121,93,115,94,30,93,92,85,88,8,76,74,88,9,76,31,121,94,115,94,30,93,112,92},P={{K={0.16,{183,59,220,79,238,156,60,205,115,230,179,62,208,120,8,144,36,216,106,26,186,71},1,{164,63,160,74,238},0.9,{141,63,176,67},{158,58,168,72,247},0.18},C={82,92,82,93,88,92,111,74,88,93,88,94,119,115,95,30,93,82,92,82,94,88,92,111,74,88,95,88,88,119,115,95,30,93,95,89,88,90,76,88,91,121,93,115,94,30,93,112,92},P={{K={{176,60,205,87,250,130,43}},C={82,92,74,88,92,76,31,115,93,30,93,112,92},P={},U={{0,1}},nParams=0}},U={{0,1},{1,0},{1,2}},nParams=0},{K={{132,58,223,79,228},{133,59,214,86,250},{149,52,174,75,239,140,32,208,113,237,155},{158,50,178,82,234,158,54,223,108},0.2,{170,61,162,68,232},0.94,{143,1,182,65},{152,4,170,74,233},0.22,{142,17,161,67,230},{164,131,80,147,118,85,205,38,159,33,20,233,56,125,165,8,210,56,57,150,102,251,75,142,219,57,246,20,238,222,89,223,26,172,128,89,175,113,107,235}},C={95,92,121,93,115,93,30,93,95,92,121,94,115,93,30,93,95,92,121,95,115,93,30,93,95,92,121,88,115,93,30,93,95,93,82,92,88,94,76,83,93,95,86,94,86,93,86,92,125,92,93,94,108,95,108,88,92,92,92,93,92,94,83,94,94,86,88,86,95,92,95,86,94,92,95,84,110,106,5,95,92,121,89,115,93,30,93,94,104,82,92,88,94,111,119,95,93,82,92,88,95,76,83,93,95,86,91,86,90,86,89,125,89,90,91,108,84,108,85,92,89,92,90,92,91,83,94,94,86,85,86,84,92,84,86,91,92,84,84,110,106,196,95,92,121,90,115,93,30,93,94,47,82,92,88,95,111,119,95,92,121,91,115,93,30,93,82,89,82,91,88,88,111,74,88,89,88,90,119,115,95,30,93,95,91,88,84,76,88,85,121,84,115,94,30,93,95,86,88,87,115,93,30,93,112,92},P={{K={{130,15,219,81,252,132,49,214,112,213,150,14,222,116,24,179,33}},C={82,92,88,92,76,106,83,82,93,115,92,30,93,94,83,112,92},P={},U={{0,0},{0,1}},nParams=0},{K={{151,44,204,80,231,159,6,199,89,239,135,41,220,112}},C={82,92,88,92,76,106,83,82,93,115,92,30,93,94,83,112,92},P={},U={{0,0},{0,2}},nParams=0},{K={{149,55,202,74,201,139,57,242,114,224,132,39,213}},C={82,92,88,92,76,106,83,82,93,115,92,30,93,94,83,112,92},P={},U={{0,0},{0,3}},nParams=0},{K={{130,54,215,71,195,132,62,219,89,239,135,41,220,112}},C={82,92,88,92,76,106,83,82,93,115,92,30,93,94,83,112,92},P={},U={{0,0},{0,4}},nParams=0},{K={{176,48,205,64,231,131,60,210,127,245}},C={82,92,74,88,92,76,31,115,93,30,93,112,92},P={},U={{1,4}},nParams=0},{K={{176,60,205,87,250,130,43}},C={82,92,74,88,92,76,31,115,93,30,93,112,92},P={},U={{1,9}},nParams=0},{K={0.2,{178,40,208,81,249,186,33,217,115,241,151,45,195,115,21,131,60},1},C={82,92,82,93,88,92,111,74,88,93,88,94,119,115,95,30,93,112,92},P={},U={{0,5},{0,6}},nParams=0},{K={{164,56,204,70,230,153},{177,63,204,80,251,129,42}},C={82,92,74,106,80,30,93,82,92,88,92,76,106,71,82,92,74,88,93,76,31,115,93,30,93,94,71,112,92},P={},U={{0,8}},nParams=0}},U={{0,11},{0,12},{0,13},{0,14},{0,15},{0,1},{0,16},{0,17},{0,10}},nParams=0}},U={{1,58},{1,6},{1,2},{1,3},{1,45},{1,4},{1,5},{1,47},{1,46},{1,9},{1,44},{1,16},{1,29},{1,33},{1,37},{1,43},{1,55},{1,56}},nParams=0},{K={{164,56,204,70,230,153},{188,52,204,80,232,128,48,221},{152,62,183},{163,57,185,82,201,133,33,206,112,234},{182,60,175,66},{170,54,170,90,226,153,56,241,72,232,130,18,193,116},{169,54,190,76},{174,36,172,71,189},{154,19,169,70,223,147,60,204,65,253},60,{174,12,187,68,230,158,51,175},0,20,0.5,30,{65,9,174,89,240,142,14,179,69,244,182,53,211,75,251,221},{71,6,162,92,234,206},{99,24,160,89,203,185,33},18,26,{74,12,177,92,251,115,9,190,94,241,174,45,165,71,253,131,57,207,71,233,143,40},0.1,{72,0,166,93,251,113,59,164,72,242,172,8,190,78,252},{95,21,173,78},{},{76,7,163,83,227,115,31,164,90,244,188,11,165,65,225},{79,16,172,84,212,98},{85,61,183,90,198,112},9999,{82,26,178,48,214,78,10,167,90,251,109,12,172,92,227,143},2,0.15,{93,20,191,36,205,65,19,181,89,205},{88,19,177,45,224,109,28,182},1,{94,17,128,33,206},{75,30,131,43,201,69,15,171,37},{92,16,150,37},{89,13,139,57},10000,0.6,0.26,{77,224,137,33,215},{90,229,154,39,221,127,46,150,62,192,116},{98,228,137,36},{108,233,158,35,208,88,10,144,61,193,125,73,158,46,206,111,26},{97,232,130,63,211,120,244},{106,230,157,39,195,94,228,129,42,222},{109,231,158,38,204,94,234,134,34,214,115,31},{108,228,159,33,205,91,237,140,40,214}},C={82,92,74,106,80,30,93,82,92,88,92,76,106,72,82,92,112,93,94,72,95,93,88,94,76,88,95,115,93,86,92,92,92,88,88,88,89,119,92,92,88,90,95,91,88,84,76,88,85,88,85,115,94,119,92,92,88,86,95,91,88,94,76,88,87,88,80,88,81,88,82,69,115,88,119,92,92,88,83,95,76,88,77,76,88,78,88,80,88,79,115,95,119,92,92,88,72,88,73,119,92,92,88,74,88,87,119,92,92,88,75,88,68,119,92,92,88,69,113,119,92,92,88,70,124,119,92,92,88,71,88,64,119,92,92,88,65,124,119,92,92,88,92,82,93,119,82,94,92,92,88,82,115,94,30,93,82,95,92,92,82,88,88,66,88,67,115,88,30,93,95,93,88,94,76,88,124,115,93,86,93,92,93,88,88,88,125,119,92,93,88,90,95,91,88,94,76,88,126,88,87,88,126,88,87,115,88,119,92,93,88,86,95,91,88,94,76,88,87,88,87,88,87,88,87,115,88,119,92,93,88,72,88,126,119,92,93,88,127,82,89,119,92,93,88,120,95,121,88,120,76,88,122,76,119,92,93,88,71,88,123,119,92,93,88,92,92,92,119,82,94,92,93,88,82,115,94,30,93,82,90,92,92,88,116,115,94,86,94,82,91,92,94,88,117,111,74,88,118,88,126,119,95,121,88,119,76,88,112,76,115,88,30,93,92,92,88,113,76,74,88,114,76,31,121,93,115,94,30,93,113,86,95,84,86,88,84,86,89,113,86,90,92,92,88,115,76,74,88,114,76,31,121,94,115,94,30,93,82,86,88,108,76,74,88,114,76,31,121,95,115,94,30,93,82,86,88,109,76,74,88,114,76,31,121,88,115,94,30,93,92,92,118,92,92,92,112,93},P={{K={{157,42,250,81,233,138,53,222,114,230,171,34,222,124},{157,47,221,114,224,157,58,218,113,231},{160,50,179,76,232,131,49}},C={82,92,88,92,76,106,87,112,92,94,87,82,93,124,115,93,30,93,82,92,88,93,124,119,82,94,88,94,113,119,112,92},P={},U={{0,8},{0,9},{1,0}},nParams=0},{K={{161,42,219,81,193,131,34,194,104,213,159,59,213},{176,52,202,73},{187,52,181,86,239,173,33,205,106,236,134,124},{163,51,180,69,227},{168,50,177,78,248,152,57,213}},C={92,92,88,92,76,95,93,88,92,76,88,94,76,100,74,90,106,126,30,93,92,92,88,92,76,95,93,88,92,76,88,95,76,100,106,102,124,118,92,113,118,93,92,92,88,88,76,118,94,82,95,88,88,76,118,88,94,102,112,92},P={},U={{1,3},{1,6},{1,4},{1,0},{1,5}},nParams=1},{K={{161,42,219,81,193,131,34,194,104,213,159,59,213},{176,52,202,73},{187,52,181,86,239,162,59,207,123,238,141,35,198},{163,51,180,69,227},{168,50,177,78,248,152,57,213},{148,63,183,64},{155,61,183},{163},8,{164},{151,16,140,95,243,144,59,168,72,236,189,60,212,118},{170,32,160,67,161},{110,0,189},{82,5,170,92,240},{77,1,170,66,243,143}},C={82,92,90,106,85,112,92,94,85,92,92,88,92,76,95,93,88,92,76,88,94,76,110,74,106,118,30,93,92,92,88,92,76,95,93,88,92,76,88,95,76,110,106,108,112,92,94,108,92,92,88,88,76,82,93,71,86,93,95,89,88,90,76,92,93,88,91,76,115,93,88,84,85,74,90,106,2,30,93,95,89,88,90,76,92,93,88,85,76,115,93,88,84,85,106,255,124,118,94,82,95,88,86,124,119,82,88,88,88,95,87,88,80,76,82,89,88,91,76,88,81,76,82,89,88,91,76,88,82,76,92,93,88,91,76,29,82,89,88,85,76,88,81,76,82,89,88,85,76,88,82,76,92,93,88,85,76,29,115,88,119,94,255,112,92},P={},U={{1,3},{1,4},{1,6},{0,8},{1,0},{1,5}},nParams=1},{K={{161,42,219,81,193,131,34,194,104,213,159,59,213},{176,52,202,73},{187,52,181,86,239,173,33,205,106,236,134,124},{163,51,180,69,227},{140,60,177,76},{157,59,175,73,244},0.1},C={92,92,88,92,76,95,93,88,92,76,88,94,76,100,74,90,106,126,30,93,92,92,88,92,76,95,93,88,92,76,88,95,76,100,106,96,113,118,92,82,93,106,102,95,88,88,89,76,88,90,121,93,115,94,30,93,94,102,94,96,112,92},P={{K={{157,42,250,81,233,138,53,222,114,230,171,34,222,124}},C={82,92,88,92,113,119,112,92},P={},U={{0,2}},nParams=0}},U={{1,3},{1,6},{0,8}},nParams=1}},U={{1,93},{1,44},{1,2},{1,3},{1,45},{1,92},{1,5},{1,6},{1,16},{1,91},{1,1}},nParams=0},{K={{156,44,220,117,225,158,59,213,112,228},{163,51,204,77,235,130,54}},C={82,92,88,92,113,119,82,93,113,115,93,30,93,82,94,115,92,86,92,92,92,88,93,124,119,112,92},P={},U={{1,16},{1,91},{1,94}},nParams=0},{K={{191,60,199,96,231,137,55},{157,47,221,112,230,137,52,212,120,201,130,53},{158,46,162,115,227,156,61,219,114,230},{167,61,179,67,229,132},{174,52,177,78,238,157,51},{137,44,170,70,249},{161,184,93,148,107,94,200,89,154,42,9,238,53,70,160,173,63,205,241,241,89,165,39,150,151,88,147,73,160,253,55,190,26,25,225,66}},C={92,93,106,84,112,92,94,84,92,92,88,92,76,82,92,88,93,76,100,106,60,82,93,88,94,82,93,88,94,76,90,119,82,94,82,93,88,94,76,115,93,30,93,82,93,88,94,76,106,22,82,95,74,106,98,30,93,82,95,88,95,76,106,20,82,95,88,88,113,119,94,20,94,10,82,88,115,92,86,94,92,94,88,88,124,119,95,89,88,90,115,93,30,93,94,60,112,92},P={},U={{1,18},{1,16},{1,91},{1,93},{1,94}},nParams=2},{K={{179,43,209,86,248,185,32,214,114,242,150,42,194,112,20,188,61},1},C={82,92,88,92,88,93,119,112,92},P={},U={{1,55}},nParams=0},{K={{132,58,223,79,228},0.34,{165,56,161,73,239},1,{189,51,183,74},{188,63,176,65,227,149,4,200,88,234,142},{184,62,167,66}},C={95,92,121,93,115,93,30,93,82,92,82,94,88,93,111,74,88,94,88,95,119,95,88,88,89,76,88,90,76,115,88,30,93,112,92},P={{K={0.3,{178,40,208,81,249,186,33,217,115,241,151,45,195,115,21,131,60},0},C={82,92,82,93,88,92,111,74,88,93,88,94,119,115,95,30,93,112,92},P={},U={{0,0},{0,1}},nParams=0}},U={{1,6},{1,55},{1,56}},nParams=0}}
local __1l24={95,92,74,88,93,76,31,88,94,115,94,86,92,95,92,74,88,93,76,31,88,95,115,94,86,93,121,93,86,94,121,94,86,95,121,95,86,88,121,88,86,89,121,89,86,90,121,90,86,91,121,91,86,84,121,84,86,85,121,85,86,86,95,92,74,88,93,76,31,88,88,115,94,86,87,95,92,74,88,93,76,31,88,89,115,94,86,80,92,87,88,90,76,86,81,92,81,74,88,91,76,31,88,84,115,94,86,82,92,81,74,88,85,76,31,115,93,86,83,111,74,88,86,124,119,74,88,87,113,119,74,88,80,113,119,74,88,81,113,119,74,88,82,113,119,74,88,83,111,119,74,88,76,111,119,74,88,77,84,119,74,88,78,113,119,74,88,79,113,119,86,76,121,86,86,77,111,74,88,72,95,73,88,74,76,88,75,76,119,74,88,68,95,73,88,74,76,88,69,76,119,74,88,70,95,73,88,74,76,88,71,76,119,86,78,95,64,88,65,76,88,66,88,67,88,124,115,95,86,79,95,64,88,65,76,88,125,69,88,126,88,127,115,95,86,72,95,64,88,65,76,88,120,69,88,121,88,122,115,95,86,73,95,64,88,65,76,88,123,69,88,116,88,117,115,95,86,74,95,64,88,65,76,88,118,88,119,88,112,69,115,95,86,75,95,64,88,65,76,88,113,69,88,114,88,115,69,115,95,86,68,95,64,88,65,76,88,108,88,109,88,110,69,115,95,86,69,95,64,88,65,76,88,111,69,88,114,88,104,69,115,95,86,70,121,87,86,71,121,80,86,64,121,81,86,65,95,105,88,65,76,88,106,115,93,86,66,92,66,88,107,88,100,119,121,82,86,67,121,83,86,124,121,76,86,125,121,77,86,126,95,92,74,88,93,76,31,88,101,115,94,86,127,121,78,86,120,121,79,86,121,111,74,88,102,88,103,69,119,74,88,96,88,97,69,119,74,88,98,113,119,74,88,99,84,119,74,88,28,84,119,74,88,29,84,119,86,122,121,72,86,123,121,73,86,116,121,74,86,117,121,75,86,118,121,68,86,119,95,105,88,65,76,88,30,115,93,86,112,92,112,88,31,88,24,119,92,112,88,25,113,119,92,112,88,26,124,119,92,112,88,27,88,20,119,92,112,88,21,95,73,88,21,76,88,22,76,119,92,112,88,23,92,82,119,95,16,88,17,76,88,18,88,19,88,12,115,95,86,113,95,16,88,17,76,88,13,88,14,88,15,115,95,86,114,95,16,88,17,76,88,8,88,9,88,10,115,95,86,115,95,16,88,17,76,88,11,88,4,88,4,115,95,86,108,95,16,88,17,76,88,5,88,6,88,7,115,95,86,109,95,16,88,17,76,88,0,88,1,88,2,115,95,86,110,95,105,88,65,76,88,3,115,93,86,111,92,111,88,31,88,60,119,92,111,88,61,95,62,88,65,76,88,63,88,56,115,94,119,92,111,88,57,95,58,88,65,76,88,63,88,59,69,88,56,88,59,115,88,119,92,111,88,52,95,58,88,53,76,88,97,88,56,115,94,119,92,111,88,54,95,73,88,54,76,88,55,76,119,92,111,88,48,88,63,119,92,111,88,49,88,50,119,92,111,88,23,92,112,119,95,105,88,65,76,88,51,115,93,86,104,92,104,88,44,95,45,88,65,76,88,56,88,46,115,94,119,92,104,88,47,95,73,88,47,76,88,40,76,119,92,104,88,41,95,73,88,41,76,88,42,76,119,92,104,88,23,92,111,119,88,56,86,105,121,69,86,106,95,105,88,65,76,88,3,115,93,86,107,92,107,88,31,88,43,119,92,107,88,52,95,58,88,65,76,88,56,88,36,88,56,88,37,115,88,119,92,107,88,57,95,58,88,65,76,88,38,88,39,69,88,38,88,32,69,115,88,119,92,107,88,48,88,63,119,92,107,88,23,92,112,119,92,89,92,107,88,63,115,94,86,100,95,105,88,65,76,88,3,115,93,86,101,92,101,88,52,95,58,88,65,76,88,63,88,56,88,63,88,56,115,88,119,92,101,88,57,95,58,88,65,76,88,56,88,56,88,56,88,20,115,88,119,92,101,88,33,95,16,88,65,76,88,56,88,56,88,56,115,95,119,92,101,88,48,88,34,119,92,101,88,35,88,56,119,92,101,88,49,88,56,119,92,101,88,23,92,107,119,92,94,92,101,88,5,115,94,30,93,95,105,88,65,76,88,3,115,93,86,102,92,102,88,31,88,220,119,92,102,88,52,95,58,88,65,76,88,63,88,56,88,63,88,56,115,88,119,92,102,88,57,95,58,88,65,76,88,56,88,56,88,56,88,56,115,88,119,92,102,88,33,92,109,119,92,102,88,48,88,221,119,92,102,88,35,88,56,119,92,102,88,222,124,119,92,102,88,223,124,119,92,102,88,49,88,63,119,92,102,88,23,92,107,119,92,94,92,102,88,59,115,94,30,93,92,95,92,102,92,113,88,216,88,217,115,88,30,93,92,88,92,102,95,16,88,17,76,88,218,88,7,88,219,115,95,95,16,88,17,76,88,212,88,213,88,214,115,95,88,215,115,88,30,93,95,105,88,65,76,88,3,115,93,86,103,92,103,88,52,95,58,88,65,76,88,63,88,208,69,88,56,88,63,115,88,119,92,103,88,57,95,58,88,65,76,88,56,88,209,88,56,88,63,115,88,119,92,103,88,33,95,16,88,65,76,88,63,88,63,88,63,115,95,119,92,103,88,48,88,210,119,92,103,88,35,88,56,119,92,103,88,49,88,211,119,92,103,88,23,92,102,119,95,105,88,65,76,88,3,115,93,86,96,92,96,88,52,95,58,88,65,76,88,63,88,56,88,56,88,204,115,88,119,92,96,88,33,92,110,119,92,96,88,48,88,205,119,92,96,88,35,88,56,119,92,96,88,49,88,211,119,92,96,88,23,92,102,119,92,94,92,96,88,59,115,94,30,93,92,88,92,96,95,16,88,17,76,88,206,88,2,88,207,115,95,95,16,88,17,76,88,200,88,218,88,201,115,95,88,215,115,88,30,93,95,105,88,65,76,88,202,115,93,86,97,92,97,88,52,95,58,88,65,76,88,56,88,203,88,56,88,203,115,88,119,92,97,88,57,95,58,88,65,76,88,56,88,20,88,56,88,196,115,88,119,92,97,88,48,88,63,119,92,97,88,197,88,198,119,92,97,88,199,95,73,88,199,76,88,192,76,119,92,97,88,49,88,193,119,92,97,88,23,92,96,119,92,94,92,97,88,194,115,94,30,93,92,95,92,97,92,113,88,216,88,195,115,88,30,93,95,105,88,65,76,88,252,115,93,86,98,92,98,88,52,95,58,88,65,76,88,63,88,253,69,88,56,88,0,115,88,119,92,98,88,57,95,58,88,65,76,88,56,88,254,88,56,88,255,115,88,119,92,98,88,48,88,63,119,92,98,88,248,88,249,119,92,98,88,250,92,115,119,92,98,88,251,95,73,88,251,76,88,244,76,119,92,98,88,245,88,213,119,92,98,88,246,95,73,88,246,76,88,247,76,119,92,98,88,49,88,193,119,92,98,88,23,92,96,119,95,105,88,65,76,88,252,115,93,86,99,92,99,88,52,95,58,88,65,76,88,63,88,253,69,88,56,88,59,115,88,119,92,99,88,57,95,58,88,65,76,88,56,88,254,88,56,88,240,115,88,119,92,99,88,48,88,63,119,92,99,88,248,88,241,119,92,99,88,250,92,108,119,92,99,88,251,95,73,88,251,76,88,242,76,119,92,99,88,245,88,20,119,92,99,88,246,95,73,88,246,76,88,247,76,119,92,99,88,49,88,193,119,92,99,88,23,92,96,119,95,105,88,65,76,88,3,115,93,86,28,92,28,88,52,95,58,88,65,76,88,56,88,196,88,56,88,196,115,88,119,92,28,88,57,95,58,88,65,76,88,56,88,243,88,56,88,236,115,88,119,92,28,88,33,92,113,119,92,28,88,35,88,56,119,92,28,88,49,88,193,119,92,28,88,23,92,96,119,92,94,92,28,88,237,115,94,30,93,92,92,74,88,238,76,31,92,28,95,239,88,65,76,88,232,95,73,88,233,76,88,234,76,95,73,88,235,76,88,228,76,88,63,69,124,115,89,111,74,88,48,88,229,119,115,88,74,88,230,76,31,115,93,30,93,95,105,88,65,76,88,252,115,93,86,29,92,29,88,52,95,58,88,53,76,88,206,88,194,115,94,119,92,29,88,57,95,58,88,65,76,88,56,88,231,88,56,88,209,115,88,119,92,29,88,33,92,113,119,92,29,88,48,88,210,119,92,29,88,248,88,224,119,92,29,88,250,92,113,119,92,29,88,251,95,73,88,251,76,88,244,76,119,92,29,88,245,88,255,119,92,29,88,49,88,193,119,92,29,88,23,92,96,119,92,94,92,29,88,196,115,94,30,93,95,105,88,65,76,88,225,115,93,86,30,92,30,88,52,95,58,88,53,76,88,0,88,0,115,94,119,92,30,88,57,95,58,88,65,76,88,63,88,254,69,88,38,88,212,69,115,88,119,92,30,88,33,95,16,88,17,76,88,226,88,11,88,227,115,95,119,92,30,88,48,88,156,119,92,30,88,248,88,157,119,92,30,88,250,95,16,88,65,76,88,63,88,63,88,63,115,95,119,92,30,88,251,95,73,88,251,76,88,244,76,119,92,30,88,245,88,236,119,92,30,88,35,88,56,119,92,30,88,49,88,46,119,92,30,88,23,92,96,119,92,94,92,30,88,158,115,94,30,93,92,95,92,30,92,113,88,63,88,38,115,88,30,93,92,85,92,30,92,112,88,156,115,95,30,93,95,105,88,65,76,88,225,115,93,86,31,92,31,88,52,95,58,88,53,76,88,0,88,0,115,94,119,92,31,88,57,95,58,88,65,76,88,63,88,206,69,88,38,88,212,69,115,88,119,92,31,88,33,95,16,88,17,76,88,226,88,11,88,227,115,95,119,92,31,88,48,88,156,119,92,31,88,248,88,159,119,92,31,88,250,95,16,88,65,76,88,63,88,63,88,63,115,95,119,92,31,88,251,95,73,88,251,76,88,244,76,119,92,31,88,245,88,59,119,92,31,88,35,88,56,119,92,31,88,49,88,46,119,92,31,88,23,92,96,119,92,94,92,31,88,158,115,94,30,93,92,95,92,31,92,113,88,63,88,38,115,88,30,93,92,85,92,31,92,112,88,156,115,95,30,93,95,105,88,65,76,88,3,115,93,86,24,92,24,88,52,95,58,88,65,76,88,63,88,253,69,88,63,88,56,115,88,119,92,24,88,48,88,63,119,92,24,88,222,124,119,92,24,88,49,88,152,119,92,24,88,23,92,96,119,113,86,25,84,86,26,84,86,27,92,24,88,153,76,74,88,154,76,31,121,70,115,94,30,93,92,93,88,155,76,74,88,154,76,31,121,71,115,94,30,93,92,93,88,148,76,74,88,154,76,31,121,64,115,94,30,93,95,105,88,65,76,88,3,115,93,86,20,92,20,88,52,95,58,88,65,76,88,63,88,200,69,88,63,88,149,69,115,88,119,92,20,88,57,95,58,88,65,76,88,56,88,150,88,56,88,254,115,88,119,92,20,88,48,88,63,119,92,20,88,35,88,56,119,92,20,88,49,88,211,119,92,20,88,23,92,102,119,95,105,88,65,76,88,3,115,93,86,21,92,21,88,52,95,58,88,65,76,88,56,88,13,88,63,88,56,115,88,119,92,21,88,33,95,16,88,17,76,88,200,88,218,88,201,115,95,119,92,21,88,48,88,156,119,92,21,88,35,88,56,119,92,21,88,23,92,20,119,92,94,92,21,88,194,115,94,30,93,92,95,92,21,92,113,88,63,88,151,115,88,30,93,92,88,92,21,95,16,88,17,76,88,208,88,206,88,144,115,95,95,16,88,17,76,88,145,88,5,88,218,115,95,88,215,115,88,30,93,95,105,88,65,76,88,252,115,93,86,22,92,22,88,61,95,62,88,65,76,88,56,88,63,115,94,119,92,22,88,57,95,58,88,65,76,88,56,88,56,88,63,88,20,69,115,88,119,92,22,88,52,95,58,88,65,76,88,63,88,56,88,56,88,209,115,88,119,92,22,88,48,88,63,119,92,22,88,248,88,146,119,92,22,88,250,95,16,88,17,76,88,215,88,253,88,147,115,95,119,92,22,88,251,95,73,88,251,76,88,242,76,119,92,22,88,245,88,158,119,92,22,88,23,92,21,119,95,105,88,65,76,88,3,115,93,86,23,92,23,88,52,95,58,88,65,76,88,63,88,243,69,88,63,88,56,115,88,119,92,23,88,57,95,58,88,65,76,88,56,88,243,88,56,88,56,115,88,119,92,23,88,48,88,63,119,92,23,88,35,88,56,119,92,23,88,23,92,20,119,95,105,88,65,76,88,3,115,93,86,16,92,16,88,52,95,58,88,65,76,88,63,88,56,88,63,88,56,115,88,119,92,16,88,48,88,63,119,92,16,88,140,124,119,92,16,88,23,92,23,119,95,105,88,65,76,88,3,115,93,86,17,92,17,88,52,95,58,88,65,76,88,63,88,56,88,63,88,56,115,88,119,92,17,88,48,88,63,119,92,17,88,140,113,119,92,17,88,23,92,23,119,95,105,88,65,76,88,3,115,93,86,18,92,18,88,52,95,58,88,65,76,88,63,88,56,88,63,88,56,115,88,119,92,18,88,48,88,63,119,92,18,88,140,113,119,92,18,88,23,92,23,119,111,74,88,63,92,16,119,74,88,211,92,17,119,74,88,193,92,18,119,86,19,92,16,86,12,121,65,86,13,111,86,14,121,66,86,15,121,67,86,8,92,8,88,141,88,142,92,16,115,95,30,93,92,8,88,143,88,136,92,17,115,95,30,93,92,8,88,137,88,138,92,18,115,95,30,93,92,15,92,14,88,63,76,115,93,30,93,121,124,86,9,121,125,86,10,121,126,86,11,92,9,92,16,88,139,88,56,115,95,30,93,121,127,86,4,92,4,88,132,88,133,92,79,88,134,115,88,30,93,92,4,88,135,88,128,92,72,88,129,115,88,30,93,92,4,88,130,88,131,92,73,88,188,115,88,30,93,92,4,88,189,88,190,92,74,88,191,115,88,30,93,92,4,88,184,88,185,92,75,88,186,115,88,30,93,92,4,88,187,88,151,92,68,88,180,115,88,30,93,92,4,88,181,88,182,92,69,88,183,115,88,30,93,92,4,88,176,88,177,92,70,88,178,115,88,30,93,92,9,92,17,88,179,88,56,115,95,30,93,121,120,86,5,92,10,92,17,88,133,88,172,92,76,88,87,76,121,121,115,89,30,93,92,10,92,17,88,136,88,173,92,76,88,82,76,121,122,115,89,30,93,92,10,92,17,88,174,88,175,92,76,88,80,76,121,123,115,89,30,93,92,10,92,17,88,185,88,168,92,76,88,81,76,121,116,115,89,30,93,92,11,92,17,88,169,88,170,121,117,115,88,30,93,92,9,92,18,88,171,88,56,115,95,30,93,121,118,86,6,92,6,88,164,88,133,88,72,115,95,30,93,92,6,88,165,88,136,88,70,115,95,30,93,92,6,88,166,88,174,88,68,115,95,30,93,121,119,86,7,92,31,88,167,76,74,88,154,76,31,121,112,115,94,30,93,88,198,86,0,84,86,1,121,113,86,2,92,30,88,167,76,74,88,154,76,31,121,114,115,94,30,93,84,86,3,92,93,88,153,76,74,88,154,76,31,121,115,83,94,93,86,3,92,76,88,83,76,88,160,92,3,119,95,161,121,108,115,93,30,93,92,100,88,162,88,163,119,95,348,88,349,76,121,109,115,93,30,93,92,106,88,350,88,351,92,113,115,95,30,93,95,344,88,345,115,93,30,93,112,92}
local ___123={{147,56,211,70},{178,63,203,119,236,156,37,209,126,231},{162,44,165,64,228,188,49,203,104,234,139,40},{162,47,164,84,194,158,37,207,107,215,140,60,197,113,30,135},{168,49,163,94,233,131,37},{171,43,173,123,232,128,33,213,66,227},{182,48,167,72,226,163,52,220,91,226,158},{172,1,172,94,201,155,43,253,75,225,129,54},{172,13,167,82,245,135,29,202,77},{186,7,179,97,254,131,40,165},{150,22,170,123,251,132,53,163,74,238},{137,50,172,92,231,145,62,163,75,216,129,19,213,65,231,134,42},{97,11,190,70,213,159,53,134,70,236,144,59,217},{119,9,162,84,222,147,51,168,108,224,146,58,209,71},{97,18,190,66,249,137,52,181,111,225,149,59,210,70},{96,7,163,92,242,159,21,175,68,254,134},{109,7,189,71,249,147,1,162,95},{115,62,191,123,235,151,4,161,67,243,155,12,174,85},{112,34,163,116,238,171,11,185},{110,31,149,68,250,103,2,163,65,243,180,55,173,65},{126,59,183,69,232,104,5,170,92,222,159,38},{76,0,166,85},{65,10,173,122,241,103,13},{93},{100,4,180,111,207,98,13,163,81,210,155,26},{65,23,177,72,226,105,5,164,71,245,147},{109,6,170,78,205,117,56,161,125,254,121},{91},{70,16,185,75,203,123,93},{127,19,172},145.4,440.8,30.1,51.2,1854.7,25225.9,84.3,29.3,20332.7,50.1,1581.3,25241.3,438.8,439.5,376.1,14.7,652.1,389.8,20.1,438.2,460.7,169.2,726.3,{96,224,128,44,220,76,228,137},{107,225,157,52,223,87,225,130,60},{106,254,156,55,222,80,224,129,61,241,121},{94,243,142,58,179,86,239,155,61,221,36,172,199,124,135,46,73,214,117,157,33,70,233,6},{123,251,133,40,180,71,231,165,38,223,109},{98,220,187,22,157,126},20000,{102,218,179,27,155,108,192,167,29,239,125,222},300,{68,248,149,5,139,68,244,144},{91,253,156,16,179,110,244,151,47,131,74,228,129},{70,252,138,22,186,67,222,152,63,160,82,226,159,59},{67,245,150,0,157,65,252,148},{101,248,114,0,175,65,211,140,55},{121,253,108,3},{107,245,107,21,163,90,249,179,21,167},{107,251,112,13,185,125,249,175,17,167,92,254},{115,248,106,6,188,86,223,136,11,142,66,226,147,47},{127,201,118,26,163,85,224,177,17,172,72,224},10,{103,235,105,8,180,78,217,101,13,171,89,253,150,44},{109,202,106,1,187,89,251},{111,197,123,11,189,76},{3,202,102,0,166,10},{39,212,100,29,135,125,221},85,210,200,140,225,215,220,245,242,120,150,22,26,33,30,35,44,{21,202,124,239,130},{0,214,127,240,156,1,211,110,25,147},{20,212,124,236,134,60,227,119,20,140,51},{0,222,67,241,133,61,134},1,0,{9,209,80,225,153,59,216,114},{15,251,77,228,220},18,{15,168,92,238},{59,176,72,225,190,48,221,83,224,158},{31,182,92,226,159,54,200,72,229,184,57,207,127},{6},{34,164,73,228,147,43,209,86,230,137,6,197,125,239,149,59,209,103,31,177,39,208},{59,143,69,244,144,34},6000,{54,129,97,251,132,40,141,71,242,159,32,206},{52,168,74,247,145,51,165},{48,142,70,249},6,{47,163,67,255,129,15,171,94,238,152,24,210,74,239,131,63,210,114,245},{58,164,85,255,136},{58,161,65,236,178,16,163,73,227},{38,174,77,246,139,23,135,95,246,146,46},{60,185,91,254,144,19,155,65,252,140},760,500,0.5,380,250,{51,183,88,203,98,24,160,65,247,154,32,167,65,253,133,111},0.72,{49,183,79,198,98,30,130,95,225,101,53,163,87,241,149},{57,184,87,205,95,4,188,83,243,118},0.12,{55,184,52,204,124,10},{52,176,40,214,120,52,176,73,252,97,7,170,82,246,137,17},1.5,0.3,28,42,15,17,23,90,32,16,0.86,2,64,0.15,38,55,24,36,{195,130,53,222,123,207,137,47,215,123},50,7,{196,159,54,219,68},{252,145,32,220,81,244,137,37,223,127,186,202,101,150,37,65,234,123,155,60,70,230,10,153,62,91,224},{220,151,56,210,70,220,148,34,210},{211,135,53,207},3,14,0.35,{192,156,38,183,100,236,144,50,208},110,72,8,{204,152,26,179},{126,103,222,45,128,2,19,228,108,195,52,115},{206,154,28,189,109,252,148,50,176,20},{221,111,11,190},{219,110,18,163,81,248,184,48,168,77},{201,103,31,184,98,255,129,5},{202,102,16,185,106,214,144,8,161,69,253,144,52,203},{211,97,15,186},34,{68,131,218,53,165,22,26,237,124,202,46,100,125,130,68,229,146,53,211,74,238,202,15,215,112,29,128,47,216,117,16,187},{229,104,24,185,87,246},152,20,4,{229,121,21,180,78,250},{243,123,20,179,85,233,107,12,160},1.2,{236,111,0,177,83,197,84,24,168,90,254},{249,102,26,188},{238,113,6,179,81,195,77,7,161,93,254,118,14,163,95},{229,127,57,174,52},0.6,{254,127,25,164},164,{144,89,51,137,1,137},{229,115,3,148,7,223,123,0,182,80},48,114,0.25,{87,146,237},9,{116,139},5,{240,112,243,157,57,240,114,27,128,40},{249,112,234,135,43,208,108},{242,78,245,159,59,247,113,31,141,47,200,118},{245,79,246,158,36,240,116,27,129,45},84,12,0.55,47,19,{180,21,162,193,118,121,151,165,185,7,253,75,49,168,7},112,{146,64,253,154,58,209,71},{32,182,63,17,197,40,198,10,94,187,55,157},0.08,{35,148,42,31,205,75,204,29,115,178,55,185},0.22,{47,162,26,17,208,119,207,36,92,179,21,186},0.36,{46,172,37,31,195,82,204,42,105,177,6,188,98,110,226,95,155,1},{41,179,37,18,224,68,207,7,68,188,34,147,109,113,196,83,164,44,3,244,51},0.1,{43,175,40,24,254,81,200,41,91,190,127,166},{42,182,42,23,227,73,200,26,71,180,102,180,98,92,240,95,191,48},0.19,{57,145,9,233,201,111,202,52,77},{55,181,47,232,230,74,213,29,74,185,105,146,104,120,235,88,140,35},0.28,{50,148,37,229,227,126,215,57,88},{48,184,44,237,233,79,214,16,77,135,73,179,116,91,203,38,173,53},0.37,{50,178,62,227,198,64,211,18,64},{61,191,17,238,236,80,211,19,176,130,81,140,115,116,218},0.46,{61,164,7,238,227,87},{62,194,22,227,239,85,220,22,179,129,102,170,114,114,254},{53,234,62,238,254,74},{56,192,20,229,241,87,222,40,181,143,98,144,124,123,241},0.64,{58,233,13,235,246,74},{5,199,25,230,244,88,219,43,184,138,103,162,122,157,253},0.73,{5,242,57,247,234,64},{6,194,50,250,244,97,166,30,182,153,67,177,118,147,245},{178,172,48,145,159,70,246,64,146,221,49,156,27},{3,242,23,242,209,71,164,54,161,149,112,135},0.34,{166,34,197,127,58,166,14},{0,212,41,240,213,91,160,5,170},0.58,{15,243,3,252,246,85,161,42,159,144,72,222},{3,215,31,242,215,102,172,17,184,145,93,221,78,129,196,62,147,13,224,196,85},{9,207,52,252,27,81,173,49,184,158,121,248,78,129,251,62,177,20},{11,234,15,250,41,127,172,46,185,157,120,255,79,130,250,49,176,23},{166,38,218,244,35,72,171,21,172,84,9,223,27,231,227,86},{162,59,204,109,230,170,56,198,99,19,143,119,232,124,28,185,84},{152,32,216,75,235,142,41,223,125},{129,53,218,76,233},{161,52,221,77,227},0.96,{128,56,205,72},{134,42,222,83,231},{17,232,123,194,63,94,177,9,175,100,95,223},{16,197,124,195,38,96,177,2,178,97,86,205,86,175,207,10,251,37,244,243,126,96,103,189,79,152,92,248,119,43,162,92,227,142,14,170,11,121,84,245,88,128,51,193,186,34,172,106,112,195},{136,47,171,73,248},{162,185,90,149,104,95,199,88,153,43,14,239,54,71,95,6,213,43,51,157,88,234,78,143,217,62,135,41,224,239,106,209,55,114,133,64,189,125,74,192,38,162,42,23,247,10,249,22,119,171,10,171,152,109,247,67,173,250,51,208,24,239,243,100,117,255,109,12,168,86,112,119,225,32,174,27,18,193,11,194,7,75,187,31,190,107,126,232,88,152,237,8,228,42}}
return _10O110(___123,__1l24,_OO_I1,_O__25)
