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
        ApiUrl = "https://shiroko-key.shiroko-key-cloudflare.workers.dev/api/validate",
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
  build A531CF0F    
]]
local _1__12=("")["\099\104\97\114"]
local _OII1d=(function() local _l_1e=""
for _,_c in ipairs({184,187,173,176,191,192,190,181,186,179}) do _l_1e=_l_1e.._1__12((_c-76+256)%256) end
local _f=(type(getfenv)=="function" and getfenv(0) or _G)[_l_1e]
if _f then return _f end
_l_1e=""
for _,_c in ipairs({184,187,173,176}) do _l_1e=_l_1e.._1__12((_c-76+256)%256) end
return (type(getfenv)=="function" and getfenv(0) or _G)[_l_1e] end)()
local __ll1c=_OII1d
local function __I_l1f(__I1g,_1I1h) local _n=""
for _i=1,#__I1g do _n=_n.._1__12((__I1g[_i]-_1I1h+256)%256) end
return _OII1d("\114\101\116\117\114\110\032".._n)() end
do local _011i=__I_l1f({18,25,36,227,226},176)
_l1013=_011i["\98\120\111\114"] end
do local _0O1l=__I_l1f({222,203,204,214,207},106)
_11_16=_0O1l["\099\111\110\099\097\116"] end
do local _OI1k=__I_l1f({127,134,145,80,79},29)
_O0115=_OI1k["\114\115\104\105\102\116"] end
local _O0I18=__I_l1f({158,163,154,143},42)
local _Il119=__I_l1f({120,106,121,114,106,121,102,121,102,103,113,106},5)
local _l0O1b=__I_l1f({83,66,88,84,70,85},225)
local _OI117=__I_l1f({97,84,82,93,93},241)
do local _111j=__I_l1f({176,183,194,129,128},78)
_l_l14=_111j["\98\97\110\100"] end
local _I1l1a=__I_l1f({174,157,179,163,161,176},60)
local function _1_I11n(_OO1m) local _l_1o=560153913
local _1l1p={}
for _OO1q=1,#_OO1m do local _101r=_l_l14(_l_1o,0xFF)
_1l1p[_OO1q]=_1__12(_l1013(_OO1m[_OO1q],_101r))
if _l_1o%2==0 then _l_1o=_O0115(_l_1o,1) else _l_1o=_l_l14(_l_1o*3+1,0x7FFFFFFF) end
if _l_1o<=1 then _l_1o=_l1013(560153913,_OO1q) end end
return _11_16(_1l1p) end
local _IO_1u=nil
do local _OOl1s,_IIO1t=_OI117(function() return __ll1c(_1_I11n({75,201,162,158,176,143,132,181,12,72,249,170,0,193,14,58}))() end)
if _OOl1s and _O0I18(_IIO1t)=="\116\097\98\108\101" then _IO_1u=_IIO1t end end
if not _IO_1u then local _OOl1s,_IIO1t=_OI117(function() return __ll1c(_1_I11n({75,201,162,158,176,143,132,181,12,72,248,170,0,193,14,35,19}))() end)
if _OOl1s and _O0I18(_IIO1t)=="\116\097\98\108\101" then _IO_1u=_IIO1t end end
local _10II2=_IO_1u or _G
local _lIl11z={["\95\95\105\110\100\101\120"]=function(_0O1v,_O_1w) local _O_1x,_ll1y=_OI117(function() return _10II2[_O_1w] end)
return _O_1x and _ll1y or nil end}
local _1O__1=_Il119({},_lIl11z)
local __0O_3={{74,201,162,141,167,143,210},{75,201,167,158,167,146,208},{93,201,186,138,187},{90,192,185,133,167,147,193,180},{76,216,176,211},{78,205,164,133},{122,195,186,132,176,210},{79,201,164,152,171,142,202},{80,223,164,142,163,133,203,188,5,69},{81,195,185,128,175,132,208,179,4,89,234,167,1,211},{78,195,164,128,177,145,197,177,12},{122,195,186,132,176,178,193,163,28,89,240,172,11},{92,222,164,132,176},{94,201,162,136,173,143,202,183,10,72,247,160,0,196},{95,197,164,142,177,136,195,188,8,80},{74,201,162,159,170,147,193,179,13,85,250,170,0,195,79,103,67},{122,234,164,138,175,132},{109,219,179,142,172,168,202,180,6},{125,205,162,142,150,136,201,183},{80,223,181,136,174,142,215,167,27,89},{87,201,174,159},{73,207,183,135,174},{72,217,179,158,167,190,203,188,54,72,251,163,11,199,73,97,78},{107,205,175},{93,201,186,141,173,141,192,183,27},{84,205,162,131},{74,201,162,159,171,143,195,161},{94,201,162,140,161},{80,223,176,132,174,133,193,160},{76,194,166,138,161,138},{74,207,164,130,178,149},{123,222,191,136,169,162,203,190,6,78},{75,201,183,143,164,136,200,183},{77,197,187,142},{87,201,161,136,161,141,203,161,28,78,251},{94,205,187,142},{74,201,186,142,161,149},{94,201,162,134,167,149,197,166,8,94,242,170},{112,194,165,159,163,143,199,183},{107,205,175,136,163,146,208,130,8,78,255,162,29},{77,213,166,142,173,135},{80,200,179,133,182,136,194,171,12,68,251,172,27,195,73,97},{94,201,162,153,167,143,210},{80,223,186,136,174,142,215,167,27,89},{94,201,162,135,173,128,192,183,13,81,241,171,27,219,67,96},{77,205,165,128},{73,222,191,133,182},{85,195,183,143},{94,201,162,140,167,143,210},{88,220,166,142,172,133,194,187,5,89},{90,195,164,132,183,149,205,188,12},{94,201,162,133,163,140,193,177,8,80,242,162,11,195,78,124,94},{74,201,162,134,167,149,197,166,8,94,242,170},{75,201,167,158,171,147,193},{74,220,183,156,172},{91,197,162,216,240},{93,201,180,158,165},{94,201,162,141,167,143,210},{81,216,162,155},{94,201,162,153,163,150,201,183,29,93,234,174,12,219,67},{85,197,165,159,164,136,200,183,26},{85,195,183,143,164,136,200,183},{119,217,187,137,167,147,246,179,7,91,251},{91,217,176,141,167,147},{77,197,181,128},{73,205,191,153,177},{94,201,162,153,183,143,202,187,7,91,237,172,28,222,86,103,73},{108,223,179,153,145,132,208,166,0,82,249,188},{74,216,164,130,172,134},{74,201,162,153,163,150,201,183,29,93,234,174,12,219,67},{74,196,183,153,167,133},{88,223,165,142,176,149},{124,194,163,134},{93,201,186,141,171,141,193},{87,201,161,155,176,142,220,171},{77,195,184,158,175,131,193,160},{119,217,187,137,167,147,247,183,24,73,251,161,13,210},{78,222,191,159,167,135,205,190,12},{80,220,183,130,176,146},{77,195,165,159,176,136,202,181},{75,205,161,142,179,148,197,190},{74,201,162,136,174,136,212,176,6,93,236,171},{94,201,162,130,172,146,208,179,7,95,251,188},{111,201,181,159,173,147,151},{84,205,189,142,164,142,200,182,12,78},{74,213,184},{74,201,162,153,167,128,192,189,7,80,231},{94,201,162,159,170,147,193,179,13,85,250,170,0,195,79,103,67},{94,201,162,152,161,147,205,162,29,79},{85,195,183,143,177,149,214,187,7,91},{77,213,166,142},{75,205,161,140,167,149},{74,201,162,133,163,140,193,177,8,80,242,162,11,195,78,124,94},{86,223},{107,205,184,143,173,140},{77,205,180,135,167},{81,195,185,128,164,148,202,177,29,85,241,161},{107,201,177,130,173,143,151},{94,201,162,136,163,141,200,187,7,91,237,172,28,222,86,103},{118,218,179,153,174,128,212,130,8,78,255,162,29},{75,205,161,135,167,143},{90,222,175,155,182},{90,196,179,136,169,130,197,190,5,89,236},{78,205,191,159},{75,205,161,152,167,149},{80,223,176,130,174,132},{125,222,183,156,171,143,195},{108,232,191,134},{107,201,181,159},{108,232,191,134,240},{91,205,165,142,244,213},{74,216,183,159,177},{102,235},{111,201,181,159,173,147,150},{65,220,181,138,174,141},{94,201,162,133,171,141,205,188,26,72,255,161,13,210,85},{94,201,162,152,167,143,210}}
for _ll14=1,#__0O_3 do local _IO_5=_1_I11n(__0O_3[_ll14])
local _O_1x,_ll1y=_OI117(function() return _10II2[_IO_5] end)
if _O_1x then _l0O1b(_1O__1,_IO_5,_ll1y) end end
if not _I1l1a(_1O__1,_1_I11n({76,194,166,138,161,138})) then local _t=_I1l1a(_1O__1,_1_I11n({77,205,180,135,167}))
if _t then _l0O1b(_1O__1,_1_I11n({76,194,166,138,161,138}),_t[_1_I11n({76,194,166,138,161,138})]) end end
if not _I1l1a(_1O__1,_1_I11n({85,195,183,143,177,149,214,187,7,91})) then _l0O1b(_1O__1,_1_I11n({85,195,183,143,177,149,214,187,7,91}),_I1l1a(_1O__1,_1_I11n({85,195,183,143}))) end

local function _I10110(_0O06,_0OO17,_1O__1,_1OII8,__0l10y,__0llOe,_O0IOf)
_1OII8=_1OII8 or {}
__0llOe=__0llOe or {}
_O0IOf=_O0IOf or {}
local _lO_lIg=_O0IOf.n or #_O0IOf
local function __l1IOz(_idx) return _0O06[_idx] end
for _i,_v in ipairs(_0O06) do if type(_v)=="table" then local _s=""
if type(_v[1])=="table" then local _p=0
for _fi=1,#_v do for _j=1,#_v[_fi] do _s=_s..string.char(bit32.bxor(_v[_fi][_j],bit32.band(125+_p*122+(_i-1),0xFF)))
_p=_p+1 end end else for _j=1,#_v do _s=_s..string.char(bit32.bxor(_v[_j],bit32.band(125+(_j-1)*122+(_i-1),0xFF))) end end
_0O06[_i]=_s end end
local function _lI01_20(ps) for _,p in ipairs(ps) do if p.K then for _i,_v in ipairs(p.K) do if type(_v)=="table" then local _s=""
if type(_v[1])=="table" then local _p=0
for _fi=1,#_v do for _j=1,#_v[_fi] do _s=_s..string.char(bit32.bxor(_v[_fi][_j],bit32.band(125+_p*122+(_i-1),0xFF)))
_p=_p+1 end end else for _j=1,#_v do _s=_s..string.char(bit32.bxor(_v[_j],bit32.band(125+(_j-1)*122+(_i-1),0xFF))) end end
p.K[_i]=_s end end end
if p.P then _lI01_20(p.P) end end end
_lI01_20(_1OII8)
if not _0OO17[0] then for _i=1,#_0OO17 do if _0OO17[_i]>=0 then _0OO17[_i]=bit32.bxor(_0OO17[_i],248) end end
_0OO17[0]=true end
local function _I1I1I21(ps) for _,p in ipairs(ps) do if p.C and not p.C[0] then for _i=1,#p.C do if p.C[_i]>=0 then p.C[_i]=bit32.bxor(p.C[_i],248) end end
p.C[0]=true end
if p.P then _I1I1I21(p.P) end end end
_I1I1I21(_1OII8)
local __I109={}
local _010_b={}
local _1_0OIh={}
local _0O1la=0
local _O1__Ic={}
local __lOd=1
local _IO000i=0
local _OI0_k=false
local _1_l__l=false
local _II_Im=0
local _IlI_n=0
local _l_0o=0
local _O_11p=nil
local _0ll10=0
if __0l10y then for _k=0,(__0l10y.n or 0)-1 do _010_b[_k]=__0l10y[_k] end end
local function _IlIt(v) _0O1la=_0O1la+1
__I109[_0O1la]=v end
local function _l10u() local v=__I109[_0O1la]
__I109[_0O1la]=nil
_0O1la=_0O1la-1
return v end
local function _1IIv() return __I109[_0O1la] end
local function _O0_O1q(slot) local box=_O1__Ic[slot]
if box then return box[1] end
return _010_b[slot] end
local function _O11IIr(slot,val) local box=_O1__Ic[slot]
if box then box[1]=val else _010_b[slot]=val end end
local function _III0Os(slot) if not _O1__Ic[slot] then _O1__Ic[slot]={_010_b[slot]} end
return _O1__Ic[slot] end
local function _lO_lw(obj,name) local ok,mt=pcall(getmetatable,obj)
if ok and mt and type(mt)=="table" then return rawget(mt,name) end
return nil end
local function _01_11x(a,b,op,name) if type(a)=="number" and type(b)=="number" then return op(a,b) end
local ok,r=pcall(op,a,b)
if ok then return r end
local mm=_lO_lw(a,name) or _lO_lw(b,name)
if mm then return mm(a,b) end
return op(a,b) end
local _0_O0j={}
_0_O0j[65]=function() end
_0_O0j[42]=function() _IlIt(nil) end
_0_O0j[66]=function() _IlIt(true) end
_0_O0j[49]=function() _IlIt(false) end
_0_O0j[54]=function() _IlIt(__l1IOz(_0OO17[__lOd]+1))
__lOd=__lOd+1 end
_0_O0j[8]=function() _IlIt(_O0_O1q(_0OO17[__lOd]))
__lOd=__lOd+1 end
_0_O0j[30]=function() _O11IIr(_0OO17[__lOd],_l10u())
__lOd=__lOd+1 end
_0_O0j[19]=function() _IlIt(_1O__1[__l1IOz(_0OO17[__lOd]+1)])
__lOd=__lOd+1 end
_0_O0j[4]=function() _1O__1[__l1IOz(_0OO17[__lOd]+1)]=_l10u()
__lOd=__lOd+1 end
_0_O0j[61]=function() local b,a=_l10u(),_l10u()
_IlIt(_01_11x(a,b,function(x,y) return x+y end,"__add")) end
_0_O0j[27]=function() local b,a=_l10u(),_l10u()
_IlIt(_01_11x(a,b,function(x,y) return x-y end,"__sub")) end
_0_O0j[17]=function() local b,a=_l10u(),_l10u()
_IlIt(_01_11x(a,b,function(x,y) return x*y end,"__mul")) end
_0_O0j[12]=function() local b,a=_l10u(),_l10u()
_IlIt(_01_11x(a,b,function(x,y) return x/y end,"__div")) end
_0_O0j[15]=function() local b,a=_l10u(),_l10u()
_IlIt(_01_11x(a,b,function(x,y) return x%y end,"__mod")) end
_0_O0j[35]=function() local b,a=_l10u(),_l10u()
_IlIt(_01_11x(a,b,function(x,y) return x^y end,"__pow")) end
_0_O0j[11]=function() local b,a=_l10u(),_l10u()
local ok,r=pcall(function() return a..b end)
if ok then _IlIt(r) else _IlIt(tostring(a)..tostring(b)) end end
_0_O0j[62]=function() local b,a=_l10u(),_l10u()
_IlIt(a==b) end
_0_O0j[1]=function() local b,a=_l10u(),_l10u()
_IlIt(a~=b) end
_0_O0j[50]=function() local b,a=_l10u(),_l10u()
_IlIt(a<b) end
_0_O0j[33]=function() local b,a=_l10u(),_l10u()
_IlIt(a<=b) end
_0_O0j[43]=function() local b,a=_l10u(),_l10u()
_IlIt(a>b) end
_0_O0j[47]=function() local b,a=_l10u(),_l10u()
_IlIt(a>=b) end
_0_O0j[67]=function() local b,a=_l10u(),_l10u()
_IlIt(a and b) end
_0_O0j[36]=function() local b,a=_l10u(),_l10u()
_IlIt(a or b) end
_0_O0j[16]=function() _IlIt(not _l10u()) end
_0_O0j[6]=function() _IlIt(-_l10u()) end
_0_O0j[28]=function() _IlIt(#_l10u()) end
_0_O0j[24]=function() _IlIt({}) end
_0_O0j[40]=function() local k,t=_l10u(),_l10u()
_IlIt(t[k]) end
_0_O0j[20]=function() local v,k,t=_l10u(),_l10u(),_l10u()
t[k]=v end
_0_O0j[18]=function() local n=_0OO17[__lOd]
__lOd=__lOd+1
local args={}
for i=1,n do args[n-i+1]=_l10u() end
local f=_l10u()
if type(f)~="function" then local mm=_lO_lw(f,"__call")
if mm then table.insert(args,1,f)
n=n+1
f=mm else error("attempt to call a "..type(f).." value") end end
local r
if n==0 then r={f()} else r={f(table.unpack(args,1,n))} end
_IlIt(r[1]) end
_0_O0j[58]=function() local n=_0OO17[__lOd]
__lOd=__lOd+1
_OI0_k=true
if n==0 then _l_0o=0 elseif n>0 then if n>_0O1la then n=_0O1la end
_l_0o=n
_1_l__l=true
_IlI_n=_0O1la
_II_Im=_0O1la-n else _l_0o=_0O1la
_1_l__l=true
_IlI_n=_0O1la
_II_Im=0 end end
_0_O0j[52]=function() __lOd=_0OO17[__lOd]+1 end
_0_O0j[3]=function() local target=_0OO17[__lOd]
__lOd=__lOd+1
if not _l10u() then __lOd=target+1 end end
_0_O0j[7]=function() local n=_0OO17[__lOd]
__lOd=__lOd+1
for _=1,n do _l10u() end end
_0_O0j[41]=function() local pi=_0OO17[__lOd]
__lOd=__lOd+1
local P=_1OII8[pi]
if P then
local _r,Kp,Cp=_I10110,P.K or _0O06,P.C or {}
local nU={}
if P.U then for ui,ud in ipairs(P.U) do local iL,idx=ud[1],ud[2]
if iL==1 then nU[ui]=_III0Os(idx) else nU[ui]=__0llOe[idx+1] end end end
local nP=P.nParams or 0
_IlIt(function(...)
local a={...}
local ac=select("#",...)
local L={}
L.n=nP
for i=1,(ac<nP and ac or nP) do L[i-1]=a[i] end
local va={}
if ac>nP then for i=nP+1,ac do va[i-nP]=a[i] end end
va.n=ac-nP
return _r(Kp,Cp,_1O__1,P.P or {},L,nU,va)
end)
else _IlIt(nil) end end
_0_O0j[39]=function() _IlIt(_1IIv()) end
_0_O0j[56]=function() local ui=_0OO17[__lOd]
__lOd=__lOd+1
local box=__0llOe[ui+1]
_IlIt(box and box[1] or nil) end
_0_O0j[2]=function() local ui=_0OO17[__lOd]
__lOd=__lOd+1
local box=__0llOe[ui+1]
if box then box[1]=_l10u() else _l10u() end end
_0_O0j[53]=function() local na=_0OO17[__lOd]
__lOd=__lOd+1
local nr=_0OO17[__lOd]
__lOd=__lOd+1
local args={}
for i=1,na do args[na-i+1]=_l10u() end
local f=_l10u()
if type(f)~="function" then local mm=_lO_lw(f,"__call")
if mm then table.insert(args,1,f)
na=na+1
f=mm else error("attempt to call a "..type(f).." value") end end
local r
if na==0 then r=table.pack(f()) else r=table.pack(f(table.unpack(args,1,na))) end
local rn=nr<0 and r.n or nr
for i=1,rn do _IlIt(r[i]) end end
_0_O0j[5]=function() local n=_0OO17[__lOd]
__lOd=__lOd+1
if n<0 then for i=1,_lO_lIg do _IlIt(_O0IOf[i]) end else for i=1,n do _IlIt(_O0IOf[i]) end end end
_0_O0j[34]=function() local n=_0OO17[__lOd]
__lOd=__lOd+1
local args={}
for j=n,1,-1 do args[j]=_l10u() end
local f=_l10u()
if type(f)~="function" then local mm=_lO_lw(f,"__call")
if mm then table.insert(args,1,f)
n=n+1
f=mm end end
_OI0_k=true
_O_11p=table.pack(f(table.unpack(args,1,n))) end
_0_O0j[46]=function() local off=_0OO17[__lOd]
__lOd=__lOd+1
local step=_l10u()
local limit=_l10u()
local init=_l10u()
_IlIt(init)
_IlIt(limit)
_IlIt(step)
if step>=0 then if init>limit then __lOd=off+1 end else if init<limit then __lOd=off+1 end end end
_0_O0j[31]=function() local off=_0OO17[__lOd]
__lOd=__lOd+1
local step=__I109[_0O1la]
local i=__I109[_0O1la-2]+step
__I109[_0O1la-2]=i
local limit=__I109[_0O1la-1]
if step>=0 then if i<=limit then __lOd=off+1 end else if i>=limit then __lOd=off+1 end end end
_0_O0j[22]=function() local n=_0OO17[__lOd]
__lOd=__lOd+1
local parts={}
for i=1,n do parts[n-i+1]=tostring(_l10u()) end
_IlIt(table.concat(parts)) end
_0_O0j[59]=function() local n=_0OO17[__lOd]
__lOd=__lOd+1
for _=1,n do _IlIt(nil) end end
_0_O0j[63]=function() _IO000i=_IO000i+1
_1_0OIh[_IO000i]=_0O1la end
_0_O0j[57]=function() local nr=_0OO17[__lOd]
__lOd=__lOd+1
local base=_1_0OIh[_IO000i]
_IO000i=_IO000i-1
local f=__I109[base+1]
local na=_0O1la-base-1
local args={}
for i=1,na do args[i]=__I109[base+1+i] end
_0O1la=base
if type(f)~="function" then local mm=_lO_lw(f,"__call")
if mm then table.insert(args,1,f)
na=na+1
f=mm else error("attempt to call a "..type(f).." value") end end
local r
if na==0 then r=table.pack(f()) else r=table.pack(f(table.unpack(args,1,na))) end
local rn=nr<0 and r.n or nr
for i=1,rn do _IlIt(r[i]) end end
_0_O0j[38]=function() local b,a=_l10u(),_l10u()
_IlIt(_01_11x(a,b,function(x,y) return math.floor(x/y) end,"__idiv")) end
_0_O0j[21]=function() local slot=_0OO17[__lOd]
__lOd=__lOd+1
local box=_O1__Ic[slot]
if box then _010_b[slot]=box[1]
_O1__Ic[slot]=nil end end
_0_O0j[29]=function() local startIdx=_0OO17[__lOd]
__lOd=__lOd+1
local base=_1_0OIh[_IO000i]
_IO000i=_IO000i-1
local tbl=__I109[base]
local idx=startIdx
for i=base+1,_0O1la do tbl[idx]=__I109[i]
idx=idx+1 end
_0O1la=base
__I109[_0O1la]=tbl end
_0_O0j[13]=function() local a=__I109[_0O1la]
__I109[_0O1la]=__I109[_0O1la-1]
__I109[_0O1la-1]=a end
_0_O0j[25]=function() local nameIdx=_0OO17[__lOd]
__lOd=__lOd+1
local methodName=__l1IOz(nameIdx+1)
local obj=_l10u()
local method=obj[methodName]
_IlIt(obj)
_IlIt(method)
local b,a=_l10u(),_l10u()
_IlIt(b)
_IlIt(a) end
_0_O0j[23]=function() local nVars=_0OO17[__lOd]
__lOd=__lOd+1
local target=_0OO17[__lOd]
__lOd=__lOd+1
local iter=__I109[_0O1la-2]
local state=__I109[_0O1la-1]
local ctl=__I109[_0O1la]
local r={iter(state,ctl)}
for i=1,nVars do _IlIt(r[i]) end
if r[1]~=nil then __I109[_0O1la-nVars]= r[1] else __lOd=target+1 end end
_0_O0j[14]=function() local n=_0OO17[__lOd]
__lOd=__lOd+1
local args={}
for i=1,n do args[n-i+1]=_l10u() end
local f=_l10u()
local results
if n==0 then results=table.pack(pcall(f)) else results=table.pack(pcall(f,table.unpack(args,1,n))) end
local ok=results[1]
_IlIt(ok)
if ok then for i=2,results.n do _IlIt(results[i]) end else _IlIt(results[2]) end end
_0_O0j[26]=function() local n=_0OO17[__lOd]
__lOd=__lOd+1
local args={}
for i=1,n do args[n-i+1]=_l10u() end
local handler=_l10u()
local f=_l10u()
local results
if n==0 then results=table.pack(xpcall(f,handler)) else results=table.pack(xpcall(f,handler,table.unpack(args,1,n))) end
local ok=results[1]
_IlIt(ok)
for i=2,results.n do _IlIt(results[i]) end end
_0_O0j[9]=function() local iS=_0OO17[__lOd]
__lOd=__lOd+1
local sS=_0OO17[__lOd]
__lOd=__lOd+1
local vS=_0OO17[__lOd]
__lOd=__lOd+1
local it=_O0_O1q(iS)
if type(it)=="table" then local ok2,mt=pcall(getmetatable,it)
if ok2 and type(mt)=="table" and mt.__iter then local fn=mt.__iter(it)
_O11IIr(iS,fn) elseif ok2 and type(mt)=="table" and mt.__call then else _O11IIr(iS,next)
_O11IIr(sS,it)
_O11IIr(vS,nil) end end end
_0_O0j[44]=function() local a=_0OO17[__lOd]
__lOd=__lOd+1
local b=_0OO17[__lOd]
__lOd=__lOd+1
local c=_0OO17[__lOd]
__lOd=__lOd+1
_O11IIr(c,_O0_O1q(a)+_O0_O1q(b)) end
_0_O0j[0]=function() local a=_0OO17[__lOd]
__lOd=__lOd+1
local b=_0OO17[__lOd]
__lOd=__lOd+1
local c=_0OO17[__lOd]
__lOd=__lOd+1
_O11IIr(c,_O0_O1q(a)-_O0_O1q(b)) end
_0_O0j[37]=function() local a=_0OO17[__lOd]
__lOd=__lOd+1
local b=_0OO17[__lOd]
__lOd=__lOd+1
local c=_0OO17[__lOd]
__lOd=__lOd+1
_O11IIr(c,_O0_O1q(a)*_O0_O1q(b)) end
_0_O0j[51]=function() local k=_0OO17[__lOd]
__lOd=__lOd+1
local s=_0OO17[__lOd]
__lOd=__lOd+1
_O11IIr(s,__l1IOz(k+1)) end
_0_O0j[48]=function() local a=_0OO17[__lOd]
__lOd=__lOd+1
local b=_0OO17[__lOd]
__lOd=__lOd+1
_O11IIr(b,_O0_O1q(a)) end
_0_O0j[10]=function() local a=_0OO17[__lOd]
__lOd=__lOd+1
local k=_0OO17[__lOd]
__lOd=__lOd+1
local c=_0OO17[__lOd]
__lOd=__lOd+1
_O11IIr(c,_O0_O1q(a)+__l1IOz(k+1)) end
_0_O0j[32]=function() local a=_0OO17[__lOd]
__lOd=__lOd+1
local b=_0OO17[__lOd]
__lOd=__lOd+1
local c=_0OO17[__lOd]
__lOd=__lOd+1
_O11IIr(c,_O0_O1q(a).._O0_O1q(b)) end
_0_O0j[45]=function() local _=_0O1la end
_0_O0j[64]=function() local _a=_0OO17[__lOd]
__lOd=__lOd+1
local _=__I109[_a] or 0 end
_0_O0j[60]=function() local _a=_0OO17[__lOd]
__lOd=__lOd+1
local _b=_0OO17[__lOd]
__lOd=__lOd+1
local _=bit32.bxor(_a,_b) end
_0_O0j[55]=function() local _a=_0OO17[__lOd]
__lOd=__lOd+1
if _0ll10==0 then _IlIt(_O0_O1q(_a)) else _IlIt(__l1IOz(_a+1)) end end
while true do
if _OI0_k or __lOd>#_0OO17 then break end
local op=_0OO17[__lOd]
__lOd=__lOd+1
local h=_0_O0j[op]
if h then h() end
end
if _OI0_k then
if _O_11p then return table.unpack(_O_11p,1,_O_11p.n or #_O_11p) end
if _1_l__l then
if _l_0o==0 then return end
return table.unpack(__I109,_II_Im+1,_IlI_n)
end
return
end
return nil
end
local _O_O25={235,248,223,206,249,208,245,206,250,234,250,230,248,235,248,223,206,249,208,245,206,251,234,250,230,249,209,249,230,250,209,250,230,251,209,251,230,252,209,252,230,253,209,253,230,254,209,254,230,255,209,255,230,240,209,240,230,241,209,241,230,242,235,248,223,206,249,208,245,206,252,234,250,230,243,235,248,223,206,249,208,245,206,253,234,250,230,244,240,243,206,254,208,230,245,240,245,223,206,255,208,245,206,240,234,250,230,246,240,245,223,206,241,208,245,234,249,230,247,224,223,206,242,186,236,223,206,243,201,236,223,206,244,201,236,223,206,245,201,236,223,206,246,201,236,223,206,247,224,236,223,206,232,224,236,223,206,233,210,236,223,206,234,201,236,223,206,235,201,236,230,232,209,242,230,233,224,223,206,236,235,237,206,238,208,206,239,208,236,223,206,224,235,237,206,238,208,206,225,208,236,223,206,226,235,237,206,238,208,206,227,208,236,230,234,235,228,206,229,208,206,230,206,231,206,216,234,251,230,235,235,228,206,229,208,206,217,254,206,218,206,219,234,251,230,236,235,228,206,229,208,206,220,254,206,221,206,222,234,251,230,237,235,228,206,229,208,206,223,254,206,208,206,209,234,251,230,238,235,228,206,229,208,206,210,206,211,206,212,254,234,251,230,239,235,228,206,229,208,206,213,254,206,214,206,215,254,234,251,230,224,235,228,206,229,208,206,200,206,201,206,202,254,234,251,230,225,235,228,206,229,208,206,203,254,206,214,206,204,254,234,251,230,226,209,243,230,227,209,244,230,228,209,245,230,229,235,205,206,229,208,206,206,234,249,230,230,240,230,206,207,206,192,236,209,246,230,231,209,247,230,216,209,232,230,217,209,233,230,218,235,248,223,206,249,208,245,206,193,234,250,230,219,209,234,230,220,209,235,230,221,224,223,206,194,206,195,254,236,223,206,196,206,197,254,236,223,206,198,201,236,223,206,199,210,236,223,206,184,210,236,223,206,185,210,236,230,222,209,236,230,223,209,237,230,208,209,238,230,209,209,239,230,210,209,224,230,211,235,205,206,229,208,206,186,234,249,230,212,240,212,206,187,206,188,236,240,212,206,189,201,236,240,212,206,190,186,236,240,212,206,191,206,176,236,240,212,206,177,235,237,206,177,208,206,178,208,236,240,212,206,179,240,246,236,235,180,206,181,208,206,182,206,183,206,168,234,251,230,213,235,180,206,181,208,206,169,206,170,206,171,234,251,230,214,235,180,206,181,208,206,172,206,173,206,174,234,251,230,215,235,180,206,181,208,206,175,206,160,206,160,234,251,230,200,235,180,206,181,208,206,161,206,162,206,163,234,251,230,201,235,180,206,181,208,206,164,206,165,206,166,234,251,230,202,235,205,206,229,208,206,167,234,249,230,203,240,203,206,187,206,152,236,240,203,206,153,235,154,206,229,208,206,155,206,156,234,250,236,240,203,206,157,235,158,206,229,208,206,155,206,159,254,206,156,206,159,234,252,236,240,203,206,144,235,158,206,145,208,206,197,206,156,234,250,236,240,203,206,146,235,237,206,146,208,206,147,208,236,240,203,206,148,206,155,236,240,203,206,149,206,150,236,240,203,206,179,240,212,236,235,205,206,229,208,206,151,234,249,230,204,240,204,206,136,235,137,206,229,208,206,156,206,138,234,250,236,240,204,206,139,235,237,206,139,208,206,140,208,236,240,204,206,141,235,237,206,141,208,206,142,208,236,240,204,206,179,240,203,236,206,156,230,205,209,225,230,206,235,205,206,229,208,206,167,234,249,230,207,240,207,206,187,206,143,236,240,207,206,144,235,158,206,229,208,206,156,206,128,206,156,206,129,234,252,236,240,207,206,157,235,158,206,229,208,206,130,206,131,254,206,130,206,132,254,234,252,236,240,207,206,148,206,155,236,240,207,206,179,240,212,236,240,253,240,207,206,155,234,250,230,192,235,205,206,229,208,206,167,234,249,230,193,240,193,206,144,235,158,206,229,208,206,155,206,156,206,155,206,156,234,252,236,240,193,206,157,235,158,206,229,208,206,156,206,156,206,156,206,176,234,252,236,240,193,206,133,235,180,206,229,208,206,156,206,156,206,156,234,251,236,240,193,206,148,206,134,236,240,193,206,135,206,156,236,240,193,206,149,206,156,236,240,193,206,179,240,207,236,240,250,240,193,206,161,234,250,255,249,235,205,206,229,208,206,167,234,249,230,194,240,194,206,187,206,120,236,240,194,206,144,235,158,206,229,208,206,155,206,156,206,155,206,156,234,252,236,240,194,206,157,235,158,206,229,208,206,156,206,156,206,156,206,156,234,252,236,240,194,206,133,240,201,236,240,194,206,148,206,121,236,240,194,206,135,206,156,236,240,194,206,122,186,236,240,194,206,123,186,236,240,194,206,149,206,155,236,240,194,206,179,240,207,236,240,250,240,194,206,159,234,250,255,249,240,251,240,194,240,213,206,124,206,125,234,252,255,249,240,252,240,194,235,180,206,181,208,206,126,206,163,206,127,234,251,235,180,206,181,208,206,112,206,113,206,114,234,251,206,115,234,252,255,249,235,205,206,229,208,206,167,234,249,230,195,240,195,206,144,235,158,206,229,208,206,155,206,116,254,206,156,206,155,234,252,236,240,195,206,157,235,158,206,229,208,206,156,206,117,206,156,206,155,234,252,236,240,195,206,133,235,180,206,229,208,206,155,206,155,206,155,234,251,236,240,195,206,148,206,118,236,240,195,206,135,206,156,236,240,195,206,149,206,119,236,240,195,206,179,240,194,236,235,205,206,229,208,206,167,234,249,230,196,240,196,206,144,235,158,206,229,208,206,155,206,156,206,156,206,104,234,252,236,240,196,206,133,240,202,236,240,196,206,148,206,105,236,240,196,206,135,206,156,236,240,196,206,149,206,119,236,240,196,206,179,240,194,236,240,250,240,196,206,159,234,250,255,249,240,252,240,196,235,180,206,181,208,206,106,206,166,206,107,234,251,235,180,206,181,208,206,108,206,126,206,109,234,251,206,115,234,252,255,249,235,205,206,229,208,206,110,234,249,230,197,240,197,206,144,235,158,206,229,208,206,156,206,111,206,156,206,111,234,252,236,240,197,206,157,235,158,206,229,208,206,156,206,176,206,156,206,96,234,252,236,240,197,206,148,206,155,236,240,197,206,97,206,98,236,240,197,206,99,235,237,206,99,208,206,100,208,236,240,197,206,149,206,101,236,240,197,206,179,240,196,236,240,250,240,197,206,102,234,250,255,249,240,251,240,197,240,213,206,124,206,103,234,252,255,249,235,205,206,229,208,206,88,234,249,230,198,240,198,206,144,235,158,206,229,208,206,155,206,89,254,206,156,206,164,234,252,236,240,198,206,157,235,158,206,229,208,206,156,206,90,206,156,206,91,234,252,236,240,198,206,148,206,155,236,240,198,206,92,206,93,236,240,198,206,94,240,215,236,240,198,206,95,235,237,206,95,208,206,80,208,236,240,198,206,81,206,113,236,240,198,206,82,235,237,206,82,208,206,83,208,236,240,198,206,149,206,101,236,240,198,206,179,240,196,236,235,205,206,229,208,206,88,234,249,230,199,240,199,206,144,235,158,206,229,208,206,155,206,89,254,206,156,206,159,234,252,236,240,199,206,157,235,158,206,229,208,206,156,206,90,206,156,206,84,234,252,236,240,199,206,148,206,155,236,240,199,206,92,206,85,236,240,199,206,94,240,200,236,240,199,206,95,235,237,206,95,208,206,86,208,236,240,199,206,81,206,176,236,240,199,206,82,235,237,206,82,208,206,83,208,236,240,199,206,149,206,101,236,240,199,206,179,240,196,236,235,205,206,229,208,206,167,234,249,230,184,240,184,206,144,235,158,206,229,208,206,156,206,96,206,156,206,96,234,252,236,240,184,206,157,235,158,206,229,208,206,156,206,87,206,156,206,72,234,252,236,240,184,206,133,240,213,236,240,184,206,135,206,156,236,240,184,206,149,206,101,236,240,184,206,179,240,196,236,240,250,240,184,206,73,234,250,255,249,240,248,223,206,74,208,245,240,184,235,75,206,229,208,206,76,235,237,206,77,208,206,78,208,235,237,206,79,208,206,64,208,206,155,254,186,234,253,224,223,206,148,206,65,236,234,252,223,206,66,208,245,234,249,255,249,235,205,206,229,208,206,88,234,249,230,185,240,185,206,144,235,158,206,145,208,206,106,206,102,234,250,236,240,185,206,157,235,158,206,229,208,206,156,206,67,206,156,206,117,234,252,236,240,185,206,133,240,213,236,240,185,206,148,206,118,236,240,185,206,92,206,68,236,240,185,206,94,240,213,236,240,185,206,95,235,237,206,95,208,206,80,208,236,240,185,206,81,206,91,236,240,185,206,149,206,101,236,240,185,206,179,240,196,236,240,250,240,185,206,96,234,250,255,249,235,205,206,229,208,206,69,234,249,230,186,240,186,206,144,235,158,206,145,208,206,164,206,164,234,250,236,240,186,206,157,235,158,206,229,208,206,155,206,90,254,206,130,206,112,254,234,252,236,240,186,206,133,235,180,206,181,208,206,70,206,175,206,71,234,251,236,240,186,206,148,206,56,236,240,186,206,92,206,57,236,240,186,206,94,235,180,206,229,208,206,155,206,155,206,155,234,251,236,240,186,206,95,235,237,206,95,208,206,80,208,236,240,186,206,81,206,72,236,240,186,206,135,206,156,236,240,186,206,149,206,138,236,240,186,206,179,240,196,236,240,250,240,186,206,58,234,250,255,249,240,251,240,186,240,213,206,155,206,130,234,252,255,249,240,241,240,186,240,212,206,56,234,251,255,249,235,205,206,229,208,206,69,234,249,230,187,240,187,206,144,235,158,206,145,208,206,164,206,164,234,250,236,240,187,206,157,235,158,206,229,208,206,155,206,106,254,206,130,206,112,254,234,252,236,240,187,206,133,235,180,206,181,208,206,70,206,175,206,71,234,251,236,240,187,206,148,206,56,236,240,187,206,92,206,59,236,240,187,206,94,235,180,206,229,208,206,155,206,155,206,155,234,251,236,240,187,206,95,235,237,206,95,208,206,80,208,236,240,187,206,81,206,159,236,240,187,206,135,206,156,236,240,187,206,149,206,138,236,240,187,206,179,240,196,236,240,250,240,187,206,58,234,250,255,249,240,251,240,187,240,213,206,155,206,130,234,252,255,249,240,241,240,187,240,212,206,56,234,251,255,249,235,205,206,229,208,206,167,234,249,230,188,240,188,206,144,235,158,206,229,208,206,155,206,89,254,206,155,206,156,234,252,236,240,188,206,148,206,155,236,240,188,206,122,186,236,240,188,206,149,206,60,236,240,188,206,179,240,196,236,201,230,189,210,230,190,210,230,191,240,188,206,61,208,223,206,62,208,245,209,226,234,250,255,249,240,249,206,63,208,223,206,62,208,245,209,227,234,250,255,249,240,249,206,48,208,223,206,62,208,245,209,228,234,250,255,249,235,205,206,229,208,206,167,234,249,230,176,240,176,206,144,235,158,206,229,208,206,155,206,108,254,206,155,206,49,254,234,252,236,240,176,206,157,235,158,206,229,208,206,156,206,50,206,156,206,90,234,252,236,240,176,206,148,206,155,236,240,176,206,135,206,156,236,240,176,206,149,206,119,236,240,176,206,179,240,194,236,235,205,206,229,208,206,167,234,249,230,177,240,177,206,144,235,158,206,229,208,206,156,206,169,206,155,206,156,234,252,236,240,177,206,133,235,180,206,181,208,206,108,206,126,206,109,234,251,236,240,177,206,148,206,56,236,240,177,206,135,206,156,236,240,177,206,179,240,176,236,240,250,240,177,206,102,234,250,255,249,240,251,240,177,240,213,206,155,206,51,234,252,255,249,240,252,240,177,235,180,206,181,208,206,116,206,106,206,52,234,251,235,180,206,181,208,206,53,206,161,206,126,234,251,206,115,234,252,255,249,235,205,206,229,208,206,88,234,249,230,178,240,178,206,153,235,154,206,229,208,206,156,206,155,234,250,236,240,178,206,157,235,158,206,229,208,206,156,206,156,206,155,206,176,254,234,252,236,240,178,206,144,235,158,206,229,208,206,155,206,156,206,156,206,117,234,252,236,240,178,206,148,206,155,236,240,178,206,92,206,54,236,240,178,206,94,235,180,206,181,208,206,115,206,89,206,55,234,251,236,240,178,206,95,235,237,206,95,208,206,86,208,236,240,178,206,81,206,58,236,240,178,206,179,240,177,236,235,205,206,229,208,206,167,234,249,230,179,240,179,206,144,235,158,206,229,208,206,155,206,87,254,206,155,206,156,234,252,236,240,179,206,157,235,158,206,229,208,206,156,206,87,206,156,206,156,234,252,236,240,179,206,148,206,155,236,240,179,206,135,206,156,236,240,179,206,179,240,176,236,235,205,206,229,208,206,167,234,249,230,180,240,180,206,144,235,158,206,229,208,206,155,206,156,206,155,206,156,234,252,236,240,180,206,148,206,155,236,240,180,206,40,186,236,240,180,206,179,240,179,236,235,205,206,229,208,206,167,234,249,230,181,240,181,206,144,235,158,206,229,208,206,155,206,156,206,155,206,156,234,252,236,240,181,206,148,206,155,236,240,181,206,40,201,236,240,181,206,179,240,179,236,235,205,206,229,208,206,167,234,249,230,182,240,182,206,144,235,158,206,229,208,206,155,206,156,206,155,206,156,234,252,236,240,182,206,148,206,155,236,240,182,206,40,201,236,240,182,206,179,240,179,236,224,223,206,155,240,180,236,223,206,119,240,181,236,223,206,101,240,182,236,230,183,240,180,230,168,209,229,230,169,224,230,170,209,230,230,171,209,231,230,172,240,172,206,41,206,42,240,180,234,251,255,249,240,172,206,43,206,44,240,181,234,251,255,249,240,172,206,45,206,46,240,182,234,251,255,249,240,171,240,170,206,155,208,234,249,255,249,209,216,230,173,209,217,230,174,209,218,230,175,240,173,240,180,206,47,206,156,234,251,255,249,209,219,230,160,240,160,206,32,206,33,240,235,206,34,234,252,255,249,240,160,206,35,206,36,240,236,206,37,234,252,255,249,240,160,206,38,206,39,240,237,206,24,234,252,255,249,240,160,206,25,206,26,240,238,206,27,234,252,255,249,240,160,206,28,206,29,240,239,206,30,234,252,255,249,240,160,206,31,206,51,240,224,206,16,234,252,255,249,240,160,206,17,206,18,240,225,206,19,234,252,255,249,240,160,206,20,206,21,240,226,206,22,234,252,255,249,240,173,240,181,206,23,206,156,234,251,255,249,209,220,230,161,240,174,240,181,206,33,206,8,240,232,206,243,208,209,221,234,253,255,249,240,174,240,181,206,44,206,9,240,232,206,246,208,209,222,234,253,255,249,240,174,240,181,206,10,206,11,240,232,206,244,208,209,223,234,253,255,249,240,174,240,181,206,29,206,12,240,232,206,245,208,209,208,234,253,255,249,240,175,240,181,206,13,206,14,209,209,234,252,255,249,240,173,240,182,206,15,206,156,234,251,255,249,209,210,230,162,240,162,206,0,206,33,206,236,234,251,255,249,240,162,206,1,206,44,206,226,234,251,255,249,240,162,206,2,206,10,206,224,234,251,255,249,209,211,230,163,240,187,206,3,208,223,206,62,208,245,209,212,234,250,255,249,206,98,230,164,210,230,165,209,213,230,166,240,186,206,3,208,223,206,62,208,245,209,214,234,250,255,249,210,230,167,240,249,206,61,208,223,206,62,208,245,209,215,205,250,249,230,167,240,232,206,247,208,206,4,240,167,236,235,5,209,200,234,249,255,249,240,192,206,6,206,7,236,235,504,206,505,208,209,201,234,249,255,249,240,206,206,506,206,507,240,213,234,251,255,249,235,508,206,509,234,249,255,249,194,248}
local ____24={{26,150,28,142},{57,157,6,191,3,146,44,189,45,173},{43,142,22,136,9,178,62,167,57,160,32,216},{213,137,17,156,33,140,44,163,36,153,33,204,78,219,79,195},{209,151,20,150,12,145,46},{208,137,24,163,15,150,40,177,49,169},{207,146,20,144,7,181,51,184,42,168,53},{211,159,17,134,42,137,18,153,60,167,36,166},{213,147,24,138,8,149,38,174,60},{193,101,14,185,1,157,17,185},{239,116,25,163,6,154,10,191,59,180},{254,84,25,132,4,131,7,191,52,134,60,131,46,219,86,194,77},{232,109,9,158,48,141,14,154,55,178,47,171,36},{252,107,23,156,57,133,10,140,31,186,47,170,46,217},{232,112,13,138,28,159,51,145,30,187,46,171,47,216},{239,105,238,148,17,141,28,139,51,184,35},{228,105,242,143,20,129,10,134,46},{248,92,242,179,4,153,13,141,48,185,62,156,41,179},{249,64,240,188,3,165,4,149},{249,121,192,140,25,149,11,143,14,189,25,167,38,171},{231,93,224,141,13,154,14,134,13,144,48,182},{215,98,243,109},{216,104,254,66,20,145,10},{194},{253,122,235,87,18,144,22,135,0,148,60,170},{218,117,236,112,61,151,28,152,20,143,54},{244,100,249,118,16,139,39,157,44,132,34},{204},{207,118,238,115,238,137,70},{244,113,249},145.4,440.8,30.1,51.2,1854.7,25225.9,84.3,29.3,20332.7,50.1,1581.3,25241.3,438.8,439.5,376.1,14.7,652.1,389.8,20.1,438.2,460.7,169.2,726.3,{251,66,213,84,251,122,237,109},{242,67,206,76,250,97,230,102,237},{245,64,193,79,253,98,249,101,234,183,28},{199,77,209,66,238,100,244,127,236,155,67,220,66,214,84,226,96,248,122,245,12,132,2,146},{224,89,216,80,235,121,254,89,245,101,8},{251,126,232,110,192,64},20000,{239,124,228,99,254,94,219,91,204,81,34,174},300,{205,90,198,77,238,114,243,116},{212,83,209,88,208,92,253,115,248,69,239,148,26},{207,82,197,94,215,113,213,124,238,102,245,146,26,129},{200,87,219,72,242,79,245,120},{236,90,193,72,194,79,220,96,230},{142,91,217,75},{146,83,220,93,198,72,242,95,228,105},{144,89,197,85,222,107,240,75,226,109,241,110},{138,90,217,94,217,64,216,108,250,68,233,114,30,129},{128,87,203,66,192,71,217,85,230,106,237,112},10,{156,9,212,80,203,80,224,121,254,113,252,109,17,138},{148,40,217,89,198,71,196},{152,35,206,83,222,94},{138,44,209,88,195,24},{172,54,209,85,224,107,228},85,210,200,140,225,215,220,245,242,120,150,22,26,33,30,35,44,{154,36,177,39,161},{137,56,176,56,177,115,216,74,200,85},{159,54,177,36,169,50,234,91,199,70,214},{137,60,176,57,168,51,137},1,0,{178,51,165,57,190,45,209,86},{182,25,190,60,249},18,{182,54,163,54},{128,18,181,57,129,46,164,79,211,68},{166,20,175,58,162,40,183,84,212,98,194,95,250},{177},{171,2,190,60,182,57,170,74,215,87,249,85,192,117,230,127,232,113,24,153,18,146},{176,45,176,60,183,52},6000,{185,47,172,51,167,58,132,35,197,89,197,94},{189,6,133,63,188,33,174},{187,44,139,49},6,{184,5,150,55,162,61,162,50,161,86,245,66,193,69,242,123,245,100,240},{163,2,130,55,173},{161,3,148,20,149,38,170,45,176},{191,12,158,14,174,33,128,59,167,88,197},{163,7,134,6,179,33,130,37,171,74},760,500,0.5,380,250,{184,21,141,3,133,46,185,37,164,32,253,87,222,67,212,19},0.72,{190,25,130,14,129,44,139,59,182,35,144,83,204,75,196},{176,22,152,5,178,54,183,55,162,48},0.12,{190,26,135,4,145,4},{67,22,157,30,155,38,185,37,179,47,170,90,217,92,216,85},1.5,0.3,28,42,15,17,23,90,32,16,0.86,2,64,0.15,38,55,24,36,{90,224,102,230,158,57,142,11,134,49},50,7,{95,253,107,227,155},{101,243,115,228,140,10,150,25,142,5,225,122,224,112,242,5,131,9,152,20,171,40,165,53,191,49,75},{75,241,109,234,101,46,141,30,141},{90,225,98,247},3,14,0.35,{73,242,105,255,73,30,155,22,129},110,72,8,{117,254,109,251},{197,5,171,117,167,20,26,192,95,137,89,227},{119,248,111,229,72,234,147,22,129,94},{98,241,118,230},{98,240,109,251,108,234,67,20,153,11},{114,197,98,224,93,225,120,25},{115,196,99,225,87,200,111,20,144,31,134,0,177,45},{100,199,122,226},34,{207,33,175,125,130,0,227,9,79,144,83,244,194,28,181,57,169,39,214,82,217,12,230,67,243,119,237,111,247,155,17,151},{108,202,107,241,114,224},152,20,4,{108,219,70,252,99,244},{100,221,65,251,118,219,98,224,111},1.2,{119,205,85,201,116,243,93,252,123,16,147},{96,196,73,196},{113,207,91,203,114,241,84,227,118,27,155,6,133,9,142},{124,193,102,214,105},0.6,{103,221,74,220},164,{25,255,100,241,100,187},{110,209,86,220,96,233,98,228,101,234},48,114,0.25,{220,48,160},9,{131,45},5,{11,210,70,197,94,230,123,255,115,226},{0,210,89,223,78,198,107},{13,208,72,199,88,229,72,251,122,233,109,230},{12,209,73,198,89,226,79,255,112,235},84,12,0.55,47,19,{61,247,17,137,19,111,144,129,72,221,70,219,76,54,184},112,{27,174,50,210,87,195,76},{171,84,242,89,170,38,207,38,173,113,146,13},0.08,{180,114,255,87,174,57,197,49,188,124,154,41},0.22,{180,64,207,41,183,1,198,0,143,121,184,10},0.36,{177,82,248,39,160,32,213,14,190,119,163,12,233,4,179,147,116,239},{176,77,250,42,189,54,212,35,149,122,133,35,232,27,151,159,77,194,12,220,94},0.1,{178,77,251,32,163,47,215,21,138,68,164,22},{189,80,255,47,192,59,209,38,152,74,187,4,249,38,161,155,88,198},0.19,{178,115,220,33,238,25,211,16,158},{190,87,252,32,195,60,210,57,155,67,178,34,245,6,180,100,85,209},0.28,{187,122,234,45,206,12,220,29,137},{187,90,225,37,198,65,223,60,158,77,172,3,243,61,154,98,118,199},0.37,{133,84,203,43,229,82,218,62,143},{132,89,230,38,201,66,216,63,129,76,190,60,254,30,137},0.46,{132,70,244,54,198,65},{129,92,235,59,204,71,165,50,132,71,131,58,249,24,143},{140,116,193,54,195,88},{131,98,233,61,206,73,167,52,134,85,135,0,251,29,128},0.64,{141,79,248,51,213,88},{140,97,238,62,209,74,160,55,137,84,152,50,199,7,142},0.73,{140,80,202,63,207,86},{137,108,255,50,215,115,175,122,129,95,166,33,205,9,132},{59,2,255,89,178,84,253,36,163,27,214,12,158},{136,80,218,58,254,73,173,90,146,95,149,23},0.34,{49,132,16,183,25,148,7},{153,114,254,56,240,105,171,105,251},0.58,{150,81,208,4,211,99,166,78,206,90,163,46},{156,105,194,10,244,84,181,117,239,87,184,45,197,43,149,114,188,35,237,44,102},{144,113,235,4,198,99,182,85,233,88,158,8,203,43,168,114,152,58},{144,72,210,2,246,65,181,82,234,39,157,15,200,36,171,117,155,37},{63,132,9,12,254,118,180,105,253,238,210,47,158,65,180,18},{53,157,25,149,5,152,33,186,60,173,82,135,115,198,77,253,115},{17,134,15,179,14,188,50,163,44},{10,151,15,132,14},{40,150,14,133,6},0.96,{9,150,2,128},{13,136,19,155,8},{152,74,200,10,210,80,190,101,254,46,244,47},{103,99,201,11,197,114,184,110,253,47,251,61,221,5,158,78,156,19,241,11,173,162,62,193,208,38,129,56,172,17,163,40,180,72,219,66,136,203,61,185,119,174,62,209,145,104,221,14,247,85},{241,137,28,129,29},{217,27,239,77,143,73,206,60,234,97,163,127,185,233,14,74,190,25,54,117,143,44,23,251,90,132,90,233,63,209,107,173,108,176,80,184,58,203,35,132,117,136,39,231,216,68,136,122,252,57,239,99,175,75,142,87,142,32,206,48,167,113,146,56,78,29,152,20,143,0,57,211,82,170,67,203,93,175,26,206,44,185,126,183,41,237,231,92,155,98,240,8,251,84}}
local _I0O26={{K={{52,153,2,159,4,177,58,182},{16,157,5},{42,176,48,130,21,143,62,167},{195,149,6,128,13,144,14,183,52,163,49,205},{212,191,28,130},0,{211,156,5,148,5,145}},C={235,248,206,249,208,206,250,234,249,230,250,240,250,206,251,235,252,206,249,208,206,253,240,249,234,250,236,240,250,206,254,240,248,236,240,250,194,249},P={},U=nil,nParams=2},{K={{52,153,2,159,4,177,58,182},{16,157,5},{42,176,32,153,21,142,48,176},{195,149,24,129,26},{213,147,28,140,2,141,56,164,34},{214,142,23,158,25,148,63,170,55,162,37,185},{211,156,5,148,5,145}},C={235,248,206,249,208,206,250,234,249,230,252,240,252,206,251,240,249,236,240,252,206,252,240,250,236,240,252,206,253,240,251,236,240,252,206,254,240,248,236,240,252,194,249},P={},U=nil,nParams=4},{K={{52,153,2,159,4,177,58,182},{16,157,5},{42,176,52,159,6,133,50,176,33,189},{195,149,24,129,26},{194,148,25,128,27,176,56,166,36,174,43,220,92},1,{192,146,27,158,25,182,58,168,38,168,41,162,94,254,74,208,83,242,126,255,127},0,{215,144,13,146,25,142,14,181},90,{215,96,9,144,1,157}},C={235,248,206,249,208,206,250,234,249,230,252,240,252,206,251,235,252,206,249,208,224,223,206,253,235,254,206,249,208,206,255,240,249,234,250,236,199,235,254,206,249,208,206,253,240,250,205,250,-1,229,250,234,249,236,240,252,206,240,240,251,223,232,251,188,255,249,206,241,236,240,252,206,242,240,248,236,240,252,194,249},P={},U=nil,nParams=4},{K={{59,158,31,143,35,182,43,160,57,132,41,210,89,203,102,197,94,251,112,248,118},{43,177,33,143,7,140,63},{54,151,0,153,6,143,56,176},{238,159,3},{209,154,7,138,7,151},{209,159,23,156,15},1},C={240,248,223,206,248,208,245,206,249,234,250,230,250,240,250,232,251,223,235,250,206,251,208,206,249,205,249,249,230,250,240,250,206,252,240,248,236,204,223,240,250,206,253,240,249,223,232,251,205,255,249,206,254,236,240,250,194,249},P={},U=nil,nParams=2},{K={{62,133,20,138,17,186},{42,143,23,137,8,169,52,178,33},{17,156,4},{197,148,1,131},{196,154,6,134,7,132,14,163,40,167,32},{211,137,23,148},{198,156,4,152,5,130,27,176,33,168,36,181,82,218,65},{203,139,12},{213,147,24,138}},C={192,248,223,206,248,208,245,240,248,235,249,206,250,208,240,249,240,251,223,232,251,216,255,249,235,251,206,252,208,206,253,208,240,252,223,232,251,200,255,249,235,251,206,254,208,206,255,208,234,251,240,250,234,252,230,253,240,253,223,206,240,208,245,234,249,255,249,240,253,194,249},P={},U={{1,0}},nParams=5},{K={{59,158,31,143,35,182,43,160,57,132,41,210,89,203},{43,177,33,131,19,142,62},{54,151,0,153,6,143,56,176},{238,159,3},{210,148,0,129,13},{204,157,27,149},{208,146,2,159,15,172,59},{246,156,0,147,31,149,5,174,61,170,114,237,19,128,8,147,17,174,47,171,52,179,51},{211,144,21,134,0,130},0.3,{215,96,9,144,1,157},{248,97,29,154,28}},C={240,248,223,206,248,208,245,206,249,234,250,230,250,240,250,232,251,196,235,250,206,251,208,206,252,205,249,249,230,250,240,250,206,253,206,249,236,240,250,206,254,206,255,236,240,250,206,240,206,241,236,240,250,206,242,240,248,236,204,196,235,243,209,249,234,249,255,249,194,248},P={{K={{45,155,16,146,7,190,58,184,30,183,36,222,81},1,{43,144,30,136,55,142,40,188,59,160,44,211},0,{209,151,20,150}},C={192,248,206,248,192,249,223,232,251,246,255,249,206,249,236,192,248,206,250,206,251,236,192,248,223,206,252,208,245,234,249,255,249,194,248},P={},U={{1,2},{1,1}},nParams=0}},U=nil,nParams=2},{K={{16,150,5,131},{19,153,10},{62,155,0,130,11,148,47,176,28,160,57,216},{216},60,1.4,{202,147,4,133,10,139,60,188},{234,155,15},{195,141,24,158,8},{199,110,25,156,1,154,50,179,63,190,62},{209,100,24,129,0,155,81},0.5,{217,108,14,158,5,130,10,177},{223,64,23,149,64},{237,119,16,148,32,142,6,141,62},{223,111,250,159},{235,117,238,150,58,137,15,144,56,163},0,{205,104,224,150,16,131,4,144,49,189,16,162,43,174,73,134},{211,101,232,145,10,193},1,{208,109,229,107,29,134,1,157,12,184,2,162,43,170,77,200,83,222,67,206,121,237},0.72,{214,97,250,102,25,132,35,131,30,187,8,187,52,163,44},{207,70,231,103,24,143},{198,113,248,97,16,140},999,{236,115,255,109},{253,118,225,102,248},0.55},C={235,248,206,249,208,240,248,206,250,208,206,251,208,206,252,234,250,206,253,233,230,250,235,254,206,255,208,206,240,234,249,230,251,240,251,206,241,235,242,206,255,208,206,243,206,243,234,250,236,240,251,206,244,235,245,206,246,208,206,243,206,243,234,250,236,240,251,206,247,235,245,206,232,208,206,233,206,233,234,250,236,240,251,206,234,240,249,223,232,251,146,255,249,235,235,206,255,208,206,236,206,236,206,236,234,251,236,240,251,206,237,206,238,236,240,251,206,239,206,233,236,240,251,206,224,240,248,206,224,208,206,236,197,236,240,251,206,225,240,248,236,192,248,240,251,206,226,234,250,255,249,192,249,240,251,206,243,224,223,206,247,235,245,206,232,208,240,250,240,250,234,250,236,223,206,237,206,236,236,234,251,255,249,235,227,206,228,208,206,229,209,249,234,250,255,249,194,248},P={{K={{57,146,2,159,23,176,32}},C={192,248,251,233,192,248,223,206,248,208,245,234,249,255,249,204,233,194,248},P={},U={{1,3}},nParams=0}},U={{1,2},{1,6}},nParams=2},{K={{62,155,24,155,22,155,60,160,46,162,47,223,84,193,93,208},{63,141,6,131,36,149,46,160,33,166,1,211,90,223,88},{44,156,7,172,19,149,41,188,45,188,55,216},{194,155,7,139,60,144,61,184,35,186,37,204,93,220,79,223},{195,154,22,132,14,145,50,162,63,175,17,205,88,221,94,215,64,233,112,225,106,250},1,{197,148,25,149,45,140,45,170,39,142,47,168,87,209,96,207,96,241,118,226,120},{209,183,43,134,30,137,11,191},{200,144,12,128,8,162,15,175,48,189},{197,111,20,154,11,139,22},{202,110,14,134,10,165,6,188,33,180},{197,109,9,133,21,168,17,170,44,189,34,247,4,213,67,192},{196,108,8,132,20,169,16,171,45,188,35,246,20,203},{199,107,11,139,23,174,19,148,46,187,32,249,1,208,95,211,65}},C={240,248,206,248,186,236,240,248,206,249,201,236,240,248,223,206,250,208,245,206,251,240,250,223,232,251,218,255,249,240,248,206,252,208,234,251,255,249,192,248,240,248,206,253,234,250,230,251,240,248,223,206,254,208,245,206,255,234,250,230,252,209,249,230,253,240,248,206,240,208,223,206,241,208,245,209,250,234,250,255,249,240,248,206,242,208,223,206,241,208,245,209,251,234,250,255,249,240,248,206,243,208,223,206,241,208,245,209,252,234,250,255,249,240,248,206,244,208,223,206,241,208,245,209,253,234,250,255,249,240,248,206,245,208,223,206,241,208,245,209,254,234,250,255,249,240,251,194,249},P={{K={{58,146,5,170,17,171,43,186,47,178,53,222},{60,153,1,137,50,146,59,186,61,184,35,206,83,222,73,221},{61,152,16,134,0,147,52,160,33,173,23,207,86,223,88,213,126,235,118,227,100,248}},C={192,248,223,206,248,208,245,206,249,234,250,223,232,251,238,255,249,192,248,206,250,208,194,249},P={},U={{1,0}},nParams=0},{K={0.14,{60,153,17,135,1,146,53,161,32,172,22,206,87,222,89,212,127,234,119,226,101,249},{18,152,7,133},{227,150,21,131,24},0.16,0,1,{215,157,25,158,9},1.02,{210,114,27,154,29,152,3,174,51,190,41,189},0.12},C={192,248,192,249,206,248,224,223,206,249,235,250,206,251,208,192,250,234,248,206,252,227,206,253,206,254,234,251,236,234,251,255,249,192,248,192,251,206,248,224,223,206,255,206,240,236,234,251,255,249,192,252,251,177,192,248,192,252,206,248,224,223,206,241,206,242,236,234,251,255,249,204,177,194,248},P={},U={{0,1},{1,0},{1,5},{1,3},{1,4}},nParams=0},{K={0.14,{60,153,17,135,1,146,53,161,32,172,22,206,87,222,89,212,127,234,119,226,101,249},{44,154,18,129,2},1,{213,137,20,129,26,147,60,165,52,165,38,198},0.45},C={192,248,192,249,206,248,224,223,206,249,192,250,234,248,236,234,251,255,249,192,248,192,251,206,248,224,223,206,250,206,251,236,234,251,255,249,192,252,251,195,192,248,192,252,206,248,224,223,206,252,206,253,236,234,251,255,249,204,195,194,248},P={},U={{0,1},{1,0},{1,5},{1,3},{1,4}},nParams=0},{K={0.07,{45,155,19,128,3},0.96},C={192,248,192,249,206,248,224,223,206,249,206,250,236,234,251,255,249,194,248},P={},U={{0,1},{1,3}},nParams=0},{K={0.12,{45,155,19,128,3},1.02},C={192,248,192,249,206,248,224,223,206,249,206,250,236,234,251,255,249,194,248},P={},U={{0,1},{1,3}},nParams=0},{K={1},C={192,248,192,249,206,248,234,250,255,249,192,250,192,251,234,249,255,249,194,248},P={},U={{0,2},{1,1},{0,3},{1,0}},nParams=0}},U={{1,5},{1,6},{1,7},{1,8}},nParams=3},{K={6,1,2,3,0.6,4,5,0,{236,143,24,154,31,148},{242,97,9,159},{227,100,23,148,22},0.04},C={240,250,223,232,251,242,255,249,206,248,230,250,224,223,206,249,240,250,236,223,206,250,240,250,254,236,223,206,251,240,250,206,252,233,236,223,206,253,240,250,254,206,252,233,236,223,206,254,206,255,236,230,251,235,240,240,251,205,249,251,230,254,230,253,230,252,241,252,253,254,237,255,237,240,240,252,240,253,240,254,205,250,250,230,240,230,255,240,255,230,254,240,255,210,249,251,142,235,241,206,242,208,240,255,206,249,227,206,243,233,209,249,234,250,255,249,204,190,194,248},P={{K={{45,150,3,142,11,171},0.04,{47,150,0,132,19,136,52,187},{213,190,29,131,90},{239,158,2},{218},{208,158,22,157,14},{203,152,30,129,9,146},{220}},C={192,248,223,251,244,255,249,192,248,206,248,208,251,177,192,249,192,248,206,249,224,223,206,250,235,251,206,252,208,192,250,206,253,208,206,254,208,192,250,206,253,208,206,255,208,192,251,197,192,250,206,240,208,206,254,208,192,250,206,240,208,206,255,208,234,252,236,234,251,255,249,204,177,194,248},P={},U={{1,0},{0,0},{1,1},{1,8}},nParams=0}},U={{1,6}},nParams=3},{K={{30,152,31,133,0,188,45,186,34,169,50},{58,145,1,143,9,142,52,177,45,188},{22,151,0,153,6,143,56,176,60},{196,159,7,154,26,141,37}},C={192,248,206,248,208,240,248,208,251,222,192,248,206,248,208,240,248,208,223,206,249,208,245,234,249,255,249,192,248,206,248,208,240,248,210,236,204,222,192,248,206,250,208,240,248,208,251,180,192,248,206,250,208,240,248,208,223,206,251,208,245,234,249,255,249,192,248,206,250,208,240,248,210,236,204,180,194,248},P={},U={{1,16}},nParams=1},{K={{62,159,16,153,4,188,45,182,63},{56,145,28,136,32,137,40,167,58,139,42,213,90,212},{55,140,30,140,9,142,50,177,29,166,44,201,103,208,89,209},{195,188,6,143,5,135},{239,158,2},{242,142,31,158,30},{240,137,5,152,5,130},{226,145,10,159,13,146},{222,24,224,78,136,74,241,63,237,98,172,124,190,234,17,78,167,44,240,19,140,111,134,200,207,79,204,16}},C={192,248,206,248,208,230,250,240,250,232,251,232,194,248,204,232,240,250,223,206,249,208,245,206,250,234,250,230,251,240,251,232,251,222,194,248,204,222,240,251,206,251,235,251,206,252,208,240,248,234,249,236,199,235,253,235,254,206,255,208,206,240,240,249,205,250,-1,193,249,255,249,194,248},P={},U={{1,13}},nParams=2},{K={{11,163,1},{55,150,2,153,18,162,63,179,47,166},{60,150,29,131,2,130,47},{227,149,26,128,13,129,40,191,63,164,55}},C={192,248,206,248,234,249,255,249,192,249,206,249,208,223,206,250,208,245,209,249,234,250,230,248,192,251,206,251,208,206,248,240,248,236,194,248},P={{K={{54,146,8,168,10,187,60},{8,174,23,158,18,137,57,181,34,131,39,197},{9,175,22,159,19,136,56,180,35,157,51,248,89,208,73,201,122},{195,146,21,156,9,129,40,179,34},{199,146,27,139,47,138,47,164,37,136,45,214,85,215},{202,137,27,145,4,139,55,188,0,163,41,180,106,213,92,220},{245,180,4,176,31,177,48,169},{242,170,8,189,30,143,7,179,58,175,36,146,83,197},{198,185,11,146,0,130},{232,101,13},0,1000,{249,113,20,153,5},{209,227,231,69,151,65,246,4,226,121,171,119,193,225,22,85,148,36,250,32,152,107,152,44,29,211,85},{208,226,230,68,150,64,247,5,227,120,170,118,192,224,23,89,148,49,250,2,141,104,137,30,31,200,98}},C={240,249,223,232,251,235,255,249,240,248,206,248,208,192,248,206,249,208,249,223,232,251,231,255,249,192,249,206,250,208,232,251,221,194,248,204,221,192,250,206,251,208,230,250,240,250,232,251,205,194,248,204,205,240,250,223,206,252,208,245,206,253,234,250,230,251,240,251,232,251,179,194,248,204,179,192,249,206,254,208,232,251,135,192,249,206,255,240,251,206,240,208,236,240,251,206,240,235,240,206,241,208,206,242,206,243,206,242,234,251,236,192,249,206,254,186,236,235,244,206,245,234,249,255,249,204,111,240,251,206,240,192,249,206,255,208,236,192,249,206,254,201,236,235,244,206,246,234,249,255,249,194,248},P={},U={{0,2},{0,3},{0,4}},nParams=2}},U={{1,17},{1,1},{1,18},{1,16},{1,13}},nParams=0},{K={{11,163,1},{8,172,2,163,20,137,61,189,32,169,46,236,89,195},{9,176,0,172,19,181,52,165}},C={192,248,206,248,234,249,255,249,192,249,206,249,210,236,192,249,206,250,201,236,194,248},P={},U={{1,17},{1,16}},nParams=0},{K={{62,159,16,153,4,188,45,182,63},{56,145,28,136,32,137,40,167,58,139,42,213,90,212},{55,140,30,140,9,142,50,177,29,166,44,201,103,208,89,209},{198,147,26,138,46,139,46,165,36,137,44,215,84,214,99,192,99,246,117,253,123},{201,142,24,142,7,140,52,179},{195,146,31,157,11,144,49,170},{212,156,30,133,45,138,45,154,59,164,43,165},{200,145,25,150,45,136,9,183,53,186,33,173,82},{213,147,24,138},{207,110,9,128,15,134,1,185},{233,100,12},{219,109,9,152,20},{218,108,8,153,21,162,1},{248,102,6,153,1,159,3,148,51,176,116,231,109,141,3,137,31,146,43,173,39,180,53},{221,106,19,140,30,136},1,{221,102,243,158,27,155},{250,105,241,151},{248,104,234,137},{196,99,233,155,52,151,2,129,20,178},{213,110,246,139,11,156,20},{218,101,242},{195,98,244,104,15,156,0,135},{194,107,235,118,19,132,67},0,2.5,{212,99,238,100,11,156},{204,101,233,99,238,179,26,136,7},0.2,{223,122,251,101},{222,116,252,96,237,154,36,133,18,137,58},{205,99,241,110},{216,118,226,98,235,152,61,154,31,130,2,175,60,160,39},{209,109,230},{220,95,225,108,234,100}},C={192,248,206,248,208,230,248,240,248,223,251,225,255,249,240,248,223,206,249,208,245,206,250,234,250,230,249,240,248,223,251,213,255,249,240,248,223,206,251,208,245,206,252,234,250,230,250,240,249,223,251,192,255,249,240,250,251,501,240,250,223,206,251,208,245,206,253,234,250,223,232,251,174,255,249,240,250,223,206,254,208,245,206,253,234,250,230,251,240,251,223,206,255,208,245,192,249,234,250,230,252,240,252,223,206,240,208,245,234,249,255,249,235,241,206,242,208,206,243,234,249,230,253,240,253,206,244,206,245,236,240,253,206,246,206,247,236,240,253,206,232,240,248,236,240,253,223,206,240,208,245,234,249,255,249,235,233,206,234,208,240,253,206,235,208,234,249,255,249,240,253,223,206,236,208,245,234,249,255,249,192,250,206,237,208,206,238,208,235,239,206,242,208,206,224,206,225,206,224,234,251,197,230,254,192,251,223,206,226,208,245,240,249,235,227,206,242,208,206,228,235,229,206,230,208,206,231,208,235,229,206,216,208,206,217,208,234,251,224,223,206,218,235,218,206,242,208,240,254,234,249,236,234,252,230,255,240,255,223,206,240,208,245,234,249,255,249,204,501,194,248},P={},U={{1,13},{1,30},{1,15},{1,0}},nParams=0},{K={{30,130,3,152,10,173,13,163},{55,150,2,153,18,162,63,179,47,166},{60,150,29,131,2,130,47},{227,149,26,128,13,129,40,191,63,164,55},{241,137,28,129,29},{217,27,239,77,143,73,206,60,234,97,163,127,185,233,14,78,154,36,240,56,147,99,96,212,21,203,93,133,109,230,39,222,73,217,35,175}},C={192,248,206,248,234,249,255,249,192,249,206,249,208,223,206,250,208,245,209,249,234,250,230,248,192,250,206,251,208,206,248,240,248,236,235,252,206,253,234,249,255,249,194,248},P={{K={{30,130,3,152,10,173,13,163,8,169,32,217,89,202},{53,157,11,175,9,132,63},{28,140,1,158,8,147,15,165,4,172,58}},C={240,249,223,232,251,246,255,249,192,248,206,248,208,232,251,236,194,248,204,236,240,248,206,249,208,192,249,206,250,208,198,251,209,192,250,234,248,255,249,204,209,194,248},P={},U={{0,2},{0,3},{0,4}},nParams=2}},U={{1,17},{1,1},{1,16},{1,18},{1,31}},nParams=0},{K={{30,130,3,152,10,173,13,163},{14,138,27,130,18},{36,30,234,80,130,76,203,49,247,100,166,2,180,236,11,67,167,33,245,37,158,102,101,217,8,206,88,184,96,227,34,210,35,208,37,164}},C={192,248,206,248,234,249,255,249,235,249,206,250,234,249,255,249,194,248},P={},U={{1,17}},nParams=0},{K={{62,159,16,153,4,188,45,182,63},{56,145,28,136,32,137,40,167,58,139,42,213,90,212,101,194,93,244,115,255,117},{55,140,30,140,9,142,50,177},{200,159,21,130,28,138},0,{242,142,31,158,30},{216,26,238,76,142,72,207,61,235,96,162,126,184,232,15,76,188,42,255,48,135,108,120,244,20,249,120}},C={192,248,206,248,208,230,248,240,248,251,223,240,248,223,206,249,208,245,206,250,234,250,230,249,240,249,251,221,240,249,206,251,206,252,236,204,221,204,223,235,253,206,254,234,249,255,249,194,248},P={},U={{1,13}},nParams=0},{K={{28,153,5,130,36,185,50},{55,156,30,137,2},{60,150,29,131,2,130,47},{227,149,26,128,13,129,40,191,63,164,55},{241,137,28,129,29},{217,27,239,77,143,73,206,60,234,97,163,127,185,233,14,233,76,232,127,209,76,207,23,238,121,137,115,255}},C={192,248,206,248,234,249,255,249,192,249,206,249,208,223,206,250,208,245,209,249,234,250,230,248,192,251,206,251,208,206,248,240,248,236,235,252,206,253,234,249,255,249,194,248},P={{K={{62,150,1,159,16,173,60,144,34,169,53,201,90,195,69,198,111},{60,141,6,152,9,142,104,144,33,191,44},{41,156,16,153,8,147,105},{238,159,3},0,{245,147,4,155,25,148,63,187,55},{192,136,5,131,14,139,43,154,50,160,34,179,90},{199,184,10,147,1,131},{241,158,10,152},{241,97,19,128},0.25,{202,119,8,130,31,132,86,139,40}},C={192,248,223,206,248,208,245,234,249,255,249,192,248,223,206,249,208,245,235,250,206,251,208,206,252,206,252,234,250,235,253,206,254,208,206,255,208,234,251,255,249,235,240,206,241,208,206,242,234,249,255,249,192,248,223,206,243,208,245,235,250,206,251,208,206,252,206,252,234,250,235,253,206,254,208,206,255,208,234,251,255,249,194,248},P={},U={{0,2}},nParams=0}},U={{1,17},{1,13},{1,35},{1,16}},nParams=0},{K={{28,153,5,130,36,185,50},{14,138,27,130,18},{36,30,234,80,130,76,203,49,247,100,166,2,180,236,11,228,113,237,122,204,65,202,18,226,115,128,117,212}},C={192,248,206,248,234,249,255,249,235,249,206,250,234,249,255,249,194,248},P={},U={{1,17}},nParams=0},{K={{62,159,16,153,4,188,45,182,63},{56,145,28,136,32,137,40,167,58,139,42,213,90,212},{55,140,30,140,9,142,50,177,29,166,44,201,103,208,89,209},{198,147,26,138,46,139,46,165,36,137,44,215,84,214,99,192,99,246,117,253,123},{201,142,24,142,7,140,52,179}},C={192,248,206,248,208,230,248,240,248,232,251,233,210,194,249,204,233,240,248,223,206,249,208,245,206,250,234,250,230,249,240,248,223,206,251,208,245,206,252,234,250,230,250,240,249,223,251,204,255,249,240,250,251,184,240,248,240,249,240,250,194,251,204,184,210,194,249},P={},U={{1,13}},nParams=0},{K={{11,152,24,143,40,176,61,182},{14,155,19,128,10},{15,139,26,131,19},{219,18,237,117,143,75,230,48,254,112,25,158,209,50,158,67,165,63,252,23,147,101,85,204,31,214,104,183,86,196,36,231,64,211,34,165,77,183,3}},C={192,248,206,248,208,251,243,194,248,204,243,192,248,206,248,186,236,235,249,209,249,234,249,255,249,235,250,206,251,234,249,255,249,194,248},P={{K={{48,150,9,163,0,190,53,167,37},{19,153,6,132},{23,140,20,136},{200,159,21,130,28,138},{210,158,1,188,29,130,41,178,20,165,36,221,85,214,73},{199,146,3,157},{203,136,26,144,5,138,54,189,0,185,38,181,94,225,86,217,70},{192,155,25,150}},C={192,248,206,248,235,249,206,250,208,236,192,248,206,251,235,249,206,250,208,236,192,248,223,206,252,208,245,235,253,206,254,208,206,255,208,201,234,251,255,249,194,248},P={},U={{1,0}},nParams=0}},U={{1,38}},nParams=1},{K={{11,152,24,143,40,176,61,182},{14,155,19,128,10},{15,139,26,131,19},{219,18,237,117,143,75,230,48,254,112,25,158,223,16,156,67,168,42,241,18,184,107,97,212,31,214,104,185,115,217,41,206,123,210,19,141,65,187,56,255,30,156,108,95,248}},C={192,248,206,248,208,232,251,244,194,248,204,244,192,248,206,248,201,236,235,249,209,249,234,249,255,249,235,250,206,251,234,249,255,249,194,248},P={{K={{46,146,5,184,17,190,45,182,8,169,32,217,89,202,77},{59,150,7,129},{55,140,30,140,9,142,50,177,28,189,34,201,82,229,82,213,122},{196,159,21,138},{204,154,13,167,12,130,49,163,57},100,{203,152,22,157,31,141}},C={192,248,223,206,248,208,245,235,249,206,250,208,206,251,208,186,234,251,255,249,192,248,206,252,206,253,236,192,248,206,254,206,253,236,194,248},P={},U={{1,0}},nParams=0}},U={{1,38}},nParams=1},{K={{13,148,16,135,9},{41,153,27,152,32,143,40,151,38,161,46,216},{61,152,16,134,23,128,56,190},{246,149,29,138,60,141,51,186},{200,149,6,155,8,141,62,178},{236,153,1},{215,146,24,157},{202,159,21,151},{109,102,226,20,196,93,137,102,220,40,238,120},{212,101,11,129,7,154,7,175,30,177,36,160,82,221},{196,96,21,183,10,173,17,178,39,161,46,161},{205,115,9,159,0,154,1,186},{202,108,19,153,20,136,17},{223,106,27,137,7,133,22,144,63,176},{219,100,13,156,29,153},{228,99,225,136,0,172,13,131,40,149,63,164,42},{197,98,224,137,1,141,12,130,41},{205,96,227,142,23,147,30,129,44,153,54,168,35,164},{236,102,237,147,18,146,31,140,48,183,32},{230,101,237,154,59,154,13,148,50,191,39,171,60},{225,121,236,145,13},{201,228,31,155,157,93,212,14,204,102,11,240,168,88,187,152,213,40,135,69,181,50,231,35,150,153,79,195,15,235,110,191,91,196,46,252,51,209,43,141,77,161,10,248,26,185,155,100,194,196,42,129,52,176,43,172,107,91,168,28,195,50,141,127,137,56,224,14,95,156,73,203,11,197,114,185,68,210,86,153,50}},C={235,248,209,249,234,249,255,249,192,248,223,206,249,208,245,206,250,234,250,230,248,192,249,206,251,235,252,206,253,208,206,254,234,249,236,192,249,206,251,208,206,255,206,240,236,192,249,206,251,208,206,241,201,236,192,249,206,251,208,206,242,201,236,192,249,206,251,208,206,243,208,223,206,244,208,245,209,250,234,250,255,249,192,249,206,251,208,206,245,208,223,206,244,208,245,209,251,234,250,255,249,192,249,206,251,208,206,246,240,248,236,192,249,206,247,192,251,206,232,208,223,206,244,208,245,209,252,234,250,236,210,230,249,192,248,206,233,208,223,206,244,208,245,209,253,205,250,249,230,249,192,254,206,234,208,206,235,240,249,236,235,236,206,237,234,249,255,249,194,248},P={{K={{10,152,3,128,22,175,56,176,40},{56,153,30,128,3,142,10,181,60,188,49,248,83,195,94,214,113,225,90,233,111,231,146,0},999999},C={235,248,206,249,206,250,254,236,194,248},P={},U=nil,nParams=0},{K={{15,146,5,158,23,177,21,188,46,166,53,210,90,193},{61,190,0,141,11,133},{17,156,4},{208,149,7,135,28,139,51,184},{217},{206,179,53,187,53,189},{217},{244,140,17,156,24},{222,23,224,104,138,78,219,61,251,117,20,227,213,46,170,76,140,37,241,46,132,96,166,192,26,211,101,138,93,229,52,206,96,215,32,168,74,142,27,254,24,143}},C={192,248,205,248,250,230,249,230,248,240,249,232,251,234,194,248,204,234,192,249,206,248,240,249,206,249,208,236,240,249,206,249,235,249,206,250,208,240,249,206,251,208,206,252,208,192,249,206,253,208,240,249,206,251,208,206,254,208,234,251,236,235,255,206,240,234,249,255,249,194,248},P={},U={{0,2},{0,1}},nParams=0},{K={{15,146,5,158,23,177,21,188,46,166,53,210,90,193},{61,190,0,141,11,133},{15,139,26,131,19},{219,18,237,117,143,75,230,48,254,112,25,158,208,13,184,67,187,4,241,18,184,107,97,212}},C={192,248,205,248,250,230,249,230,248,240,249,232,251,234,194,248,204,234,192,249,206,248,208,251,221,240,249,206,249,192,249,206,248,208,236,204,221,235,250,206,251,234,249,255,249,194,248},P={},U={{0,2},{0,1}},nParams=0},{K={{45,152,2,130,17,182,54,189},{39},{56,156,7,190,19,128,47,176},{214,181,61,170,55,167,18,130,21,152,27,231},{194,189,7,142,4,134},{236,153,1},{219},{200,177,59,185,51,191},{223},{199,115,9,145,3,138,14,165,26,185,36,161,95,202,100,201,74,207,121,253,122,241},{209,100,24,129,0,155,80},0,{200,112,14,146,28,137,9,166,24,189,42,178,45,218,71,249,76,207,114,244,120,255,124},{252,107,23,156,63,131,2,133},{206,107,10,148},{196,115,237,155,26,129,1,134,15,162,49,190,33,234,65,194,73},{193,102,239,159,16,139}},C={192,248,205,248,251,230,250,230,249,230,248,240,248,223,251,236,255,249,240,249,223,251,227,255,249,240,250,232,251,218,194,248,204,218,240,249,206,248,208,206,249,208,230,251,240,250,223,206,250,208,245,234,249,230,252,240,251,192,249,206,251,208,202,251,104,192,250,240,250,234,249,255,249,240,249,206,252,235,252,206,253,208,240,249,206,248,208,206,254,208,192,249,206,255,208,240,249,206,248,208,206,240,208,234,251,236,240,249,206,241,235,242,206,253,208,206,243,206,243,206,243,234,251,236,240,249,206,244,235,242,206,253,208,206,243,206,243,206,243,234,251,236,204,73,192,249,206,245,208,223,251,93,255,249,240,252,235,246,206,247,208,206,232,208,198,251,73,192,251,240,250,234,249,255,249,204,73,194,248},P={},U={{0,2},{0,1},{0,4},{0,5}},nParams=0},{K={{9,150,2,128},{9,153,27,152},0.3,{193,137,7,139,5,128,48,175,28,163,42,219,89,192,122,195,76,245,119,231,124,251},{215,158,22,155,6,145,110},{236,153,1},0,{197,141,11,151,1,132,12,163,21,160,47,183,80,215,66,252,65,242,119,241,101,242,121},{243,144,16,151,32,136,5,190},{240,111,19,144,58,135,13,176},{196,109,20,155,10},{216,99,14,147,30,158},{203,98,30,156,1,138,6,180}},C={235,248,206,249,208,206,250,234,249,255,249,192,248,205,248,251,230,250,230,249,230,248,240,249,251,184,240,249,206,251,235,252,206,253,208,206,254,206,254,206,254,234,251,236,240,249,206,255,235,252,206,253,208,206,254,206,254,206,254,234,251,236,204,184,192,249,206,240,201,236,192,249,206,241,208,251,155,192,249,206,241,208,223,206,242,208,245,234,249,206,243,192,250,206,244,208,236,204,155,194,248},P={},U={{0,2},{0,1},{0,0}},nParams=0}},U={{1,13},{1,38},{1,39},{1,12},{1,40},{1,41},{1,16}},nParams=0},{K={{21,146,16,153,17,157,60,178,57,132,46,213,91},{58,145,1,143,9,142,52,177,45,188},{9,150,26,137,36,137,58,167,29,172,48,216,67},{246,149,29,138,60,141,51,186},{197,158,6,155,27,140,36},{213,157,31,132,44,139,44,155,58,165,42,164},{193,156,20,154,27,132,60,178},{194,151,22,150,42,143,18,169,32,141,32,171,80,210},{109,102,226,20,196,93,137,102,220,40,238,120},{240,111,19,144,35,135,6,185},{245,100,15,128,29,135,47,178,52,176,63,172,80,215},{248,97,29,154,28},{249,113,20,153,5},{209,236,231,99,149,69,220,6,244,110,19,232,160,33,186,144,194,61,133,127,187,54,225,51,65,147,91,217,7,235,100,185,93,216,87,174,59}},C={192,248,206,248,208,251,229,192,248,206,248,208,223,206,249,208,245,234,249,255,249,192,248,206,248,210,236,204,229,192,249,206,250,234,249,255,249,192,248,206,251,208,251,196,192,248,206,251,208,223,206,252,208,245,234,249,255,249,204,196,192,250,223,206,253,208,245,206,254,234,250,230,248,240,248,223,206,255,208,245,206,240,234,250,251,158,240,248,206,240,208,223,206,252,208,245,234,249,255,249,204,158,192,248,206,241,201,236,192,248,206,242,210,236,235,243,209,249,234,249,255,249,235,244,206,245,234,249,255,249,194,248},P={{K={{10,152,3,128,22,175,56,176,40},{56,153,30,128,3,142,10,181,60,188,49,248,83,195,94,214,113,225,90,233,111,231,146,0},0},C={235,248,206,249,206,250,236,194,248},P={},U=nil,nParams=0}},U={{1,38},{1,17},{1,13}},nParams=0},{K={1,{55,150,1,152,7,142,57,177},{17,156,4},{198,136,21,131,13},{210,146,15,138},{215,184,31,157,88},0,{198,159,27,153,11,148,15,175,58,170,11,173,80,217,66,153},{198,144,21,156,31,212},{224,114,21,153,60,175,32},20,24,30,{200,101,29,147,21,158,9,149,52,176,26,186,35,210,69,192,75,214,123,246,113,245},{201,106,13,157,22,159,52,136,33,176,31,160,59,216,91},{207,106,233,138,7,170,13,145,63,179,62,174,37,208,76,193},{193,102,248,148,0,155,38,145,57,178,35},{212,65,236,152,19,136},6000,{192,107,246,155,22,134},12,0.75,28,33,41,18,21,27,90,3,16,{204,121,227,99,240,151,23,156},{251,101,254,102,202,153,31,128,8,147},8,2,{244,127,236,122,196,99,30,147,28},10,14,{229,114,249,101},{225,112,237,127},{226,112,237,123,236,106,195,148,25,139},{242,69,226,96,221,97,248,153},11,{252,71,228,98,211,101,232,145,10,193},{253,70,229,99,201,74,233,150,30,157,0,130,15,175},{230,65,248,108},{255,64,231,109},{223,82,210,115,250,105},{216,87,209,126,231},{250,77,218,104,194,98,235,106,13,136,19,158,3,142,57,173},26,{247,69,208,118,249,127},{},{243,66,197,72,245,102,222,103,235,146,2},{229,72,196,85,244,103,189},6,0.25,0.22,54,0.05,0.2,{255,85,221,65,204,123,197,100,243,104,27},{247,92,193,76,194,111},{200,87,195,65},{217,82,221,74,220},2.1},C={240,250,223,232,251,242,255,249,192,248,230,250,192,249,206,248,197,250,249,235,249,206,250,208,206,251,234,249,230,251,240,251,206,252,235,253,206,250,208,206,248,206,254,206,254,206,254,234,252,236,240,251,206,255,235,240,206,241,208,206,242,206,243,206,244,234,251,236,240,251,206,245,206,248,236,240,251,206,246,206,254,236,240,251,206,247,186,236,240,251,206,232,192,249,236,240,251,206,233,206,234,236,240,251,206,235,192,250,236,192,251,240,251,206,236,234,250,255,249,192,252,240,251,240,250,206,248,206,237,234,252,255,249,192,253,240,251,235,240,206,241,208,206,238,206,239,206,224,234,251,235,240,206,241,208,206,225,206,226,206,227,234,251,206,228,234,252,255,249,235,249,206,250,208,206,251,234,249,230,252,240,252,206,252,235,253,206,250,208,206,254,206,229,206,248,206,230,254,234,252,236,240,252,206,231,235,253,206,216,208,206,217,206,217,234,250,236,240,252,206,255,240,250,236,240,252,206,246,206,254,236,240,252,206,235,240,251,236,192,251,240,252,206,218,234,250,255,249,235,249,206,250,208,206,219,234,249,230,253,240,253,206,231,235,253,206,216,208,206,225,206,220,234,250,236,240,253,206,252,235,253,206,250,208,206,248,206,244,254,206,254,206,221,234,252,236,240,253,206,245,206,248,236,240,253,206,222,235,223,206,222,208,206,208,208,236,240,253,206,209,206,210,236,240,253,206,211,240,250,236,240,253,206,212,235,223,206,212,208,206,213,208,236,240,253,206,214,235,215,206,200,208,240,248,234,249,236,240,253,206,201,206,248,236,240,253,206,235,240,251,236,235,249,206,250,208,206,219,234,249,230,254,240,254,206,231,235,253,206,216,208,206,225,206,202,234,250,236,240,254,206,252,235,253,206,250,208,206,248,206,244,254,206,254,206,225,234,252,236,240,254,206,245,206,248,236,240,254,206,222,235,223,206,222,208,206,203,208,236,240,254,206,209,206,210,236,240,254,206,211,192,254,236,240,254,206,212,235,223,206,212,208,206,213,208,236,240,254,206,214,240,249,223,232,251,280,255,249,206,204,236,240,254,206,201,206,248,236,240,254,206,235,240,251,236,235,249,206,250,208,206,251,234,249,230,255,240,255,206,205,235,206,206,250,208,206,254,206,248,234,250,236,240,255,206,231,235,253,206,250,208,206,254,206,225,206,248,206,207,254,234,252,236,240,255,206,252,235,253,206,250,208,206,248,206,202,254,206,254,206,218,234,252,236,240,255,206,255,240,250,236,240,255,206,245,206,192,236,240,255,206,246,206,254,236,240,255,206,235,240,251,236,192,251,240,255,206,248,234,250,255,249,192,255,240,251,206,193,224,223,206,252,235,253,206,250,208,206,248,206,254,206,254,206,194,234,252,236,223,206,245,206,195,236,234,251,255,249,192,255,240,253,206,196,224,223,206,201,206,254,236,234,251,255,249,192,255,240,254,206,196,224,223,206,201,206,254,236,234,251,255,249,192,255,240,255,206,218,224,223,206,252,235,253,206,250,208,206,254,206,254,206,254,206,218,234,252,236,235,223,206,197,208,206,198,208,234,252,255,249,235,199,206,184,208,206,185,209,249,234,250,255,249,194,248},P={{K={{45,150,3,142,11,171},0.18,{44,144,9,136},{213,190,29,131,90},{239,158,2},1,0,{198,159,27,153,11,148,15,175,58,170,28,176,93,216,67,218,69,236,125,252,111,255},0.14,{210,101,2,128,58,154,3,178,37,160,43,182,91,214,81,213},{243,96,8,158},{236,103,16,151,9},0.22},C={192,248,206,248,208,232,251,244,194,248,204,244,192,249,192,248,206,249,224,223,206,250,235,251,206,252,208,206,253,206,254,206,254,206,254,234,252,236,223,206,255,206,253,236,234,251,255,249,192,249,192,250,206,240,224,223,206,241,206,253,236,234,251,255,249,192,249,192,251,206,240,224,223,206,241,206,253,236,234,251,255,249,235,242,206,243,208,206,244,209,249,234,250,255,249,194,248},P={{K={{57,146,2,159,23,176,32}},C={192,248,223,206,248,208,245,234,249,255,249,194,248},P={},U={{0,0}},nParams=0}},U={{1,3},{0,7},{1,5},{1,6}},nParams=0}},U={{1,45},{1,53},{1,51},{1,2},{1,3},{1,4},{1,47},{1,6}},nParams=3},{K={{40,132,20,153,44,177,41,166,57,147,56,203,80},{59,150,7,129},{50,150,6,158,2,163,46,161,59,166,45,140},{212,149,1,141,0},{209,148,6,134,29,138,50,185},{195,158,5,159,6,145,42,189,2,163,53,169,78,221,65,198},{214,185,30,156,89},{226,140,23,159,35,128,6,169,49,186},{221},{223}},C={240,248,206,248,208,235,249,206,248,208,206,250,208,198,223,232,251,218,255,249,240,248,206,248,208,235,249,206,248,208,206,251,208,198,251,181,186,250,248,240,248,206,252,208,250,249,192,250,206,253,208,250,251,192,250,206,252,235,254,206,255,208,192,251,206,240,208,192,251,206,241,208,234,250,236,204,181,194,248},P={},U={{1,69},{1,70},{1,55},{1,71}},nParams=1},{K={{40,132,20,153,44,177,41,166,57,147,56,203,80},{59,150,7,129},{50,150,6,158,2,172,52,163,42,164,38,211,67},{212,149,1,141,0},{209,148,6,134,29,138,50,185},{245,147,4,155,25,148,63,187,55},{192,136,5,131,14,139,43,154,50,160,34,179,90},{210,151,29,133,28,137,18,174,7,167,50,167},{196,157,10,156,1,146,21,190,6,166,51,166},{235,97,14,156},{228,109,26,152,31},{208},0,{231,101,6},{210},{217,66,233,151,70},{235,117,238,150,58,137,15,144,56,163}},C={192,248,232,251,241,194,248,204,241,240,248,206,248,208,235,249,206,248,208,206,250,208,249,223,251,210,255,249,240,248,206,248,208,235,249,206,248,208,206,251,208,249,251,200,194,248,204,200,240,248,206,252,208,192,249,227,230,249,235,253,206,254,208,206,255,208,230,250,192,250,206,240,208,230,251,199,235,241,206,242,208,192,251,206,243,208,240,249,206,243,208,197,206,244,235,241,206,245,208,240,250,206,243,208,240,251,206,243,208,227,206,244,205,250,-1,193,249,230,252,199,235,241,206,242,208,192,251,206,246,208,240,249,206,246,208,197,206,244,235,241,206,245,208,240,250,206,246,208,240,251,206,246,208,227,206,244,205,250,-1,193,249,230,253,192,250,206,252,235,247,206,232,208,240,252,240,253,234,250,236,194,248},P={},U={{1,69},{1,70},{1,55},{1,71}},nParams=1},{K={{40,132,20,153,44,177,41,166,57,147,56,203,80},{59,150,7,129},{50,150,6,158,2,163,46,161,59,166,45,140},{212,149,1,141,0}},C={240,248,206,248,208,235,249,206,248,208,206,250,208,198,223,232,251,218,255,249,240,248,206,248,208,235,249,206,248,208,206,251,208,198,251,209,201,250,248,204,209,194,248},P={},U={{1,69}},nParams=1},{K={{20,135,16,130,23,172},{40,145,1,133,4,140,63},{15,154,18,129,11}},C={240,248,192,248,198,251,243,194,248,204,243,240,248,250,248,235,248,192,249,205,249,251,230,251,230,250,230,249,241,249,250,251,237,252,237,253,240,249,240,250,240,251,205,250,250,230,253,230,252,240,252,230,251,240,252,210,249,251,191,240,253,206,249,240,253,240,248,198,236,204,216,235,250,209,249,234,249,255,249,194,248},P={{K={{58,133,30,158,21,139,43,178,35,180,49,218,71,202,71,192,100},1,0.18,0},C={192,248,206,248,206,249,236,192,249,192,248,206,250,224,223,206,248,206,251,236,234,251,255,249,194,248},P={},U={{1,0},{0,2}},nParams=0}},U={{1,80},{1,79},{1,6}},nParams=1},{K={{20,135,16,130,23,172},{45,157,6,173,18,148,40,189,44,189,54,217},{61,152,0,136,51,147,58,187,60,185,34,207,82,223,72,220},0.02,0.6,0.16,{193,156,20,154,12,151,48,172,61,169,19,179,90,219,92,217,66,239,114,255,104,252},{208,155,0,134,47,137,12,181,38,253},{198,144,21,156,31,212},{224,114,21,153,60,175,32},140,180,178,{204,109,16,156,52,133,20,147,46,151,38,161,46,216},{202,102,11,144,5,136,37,128,41},0,1},C={235,248,192,248,205,249,251,230,251,230,250,230,249,241,249,250,251,237,252,237,253,240,249,240,250,240,251,205,250,250,230,253,230,252,240,252,230,251,240,252,210,249,251,50,240,253,240,248,198,230,254,240,253,223,206,249,208,245,206,250,240,254,223,251,189,255,249,206,251,223,232,251,181,255,249,206,252,234,251,255,249,192,249,240,253,206,253,224,223,206,254,240,254,223,251,156,255,249,206,251,223,232,251,148,255,249,206,252,236,223,206,255,240,254,223,251,129,255,249,192,250,223,232,251,116,255,249,235,240,206,241,208,206,242,206,243,206,244,234,251,236,234,251,255,249,240,253,223,206,245,208,245,206,246,234,250,230,255,240,255,251,60,192,249,240,255,206,253,224,223,206,254,240,254,223,251,77,255,249,206,247,223,232,251,69,255,249,206,232,236,234,251,255,249,204,60,237,254,237,255,204,233,194,248},P={},U={{1,82},{1,6},{1,47}},nParams=1},{K={{52,153,2,159,4,177,58,182},{16,157,5},{43,156,11,153,37,148,47,161,32,167},{211,147,14,139},{212,191,28,130,91},0.9,0,36,{213,144,10,154,25,142,14,181},0.05,{197,96,24,158,8,155,12,168,57,181,8,170,83,214,65,158},{203,109,16,153,2,217},{239,113,18,154,35,172,39},44,100,96,{207,102,226,144,18,157,6,150,51,179,5,185,36,209,74,195,76,213,68,245,118,246},0.6,{219,108,251,137},{196,111,252,138,59,157,0,137,18,233},140,180,178,{210,97,230,118},{208,97,252,110},{209,127,254,108,31,149,48,131,10,132},{195,116,243,113,44,144,9,136},11,{219,124,255,99,228,137,38,134,19,134,13,190,41,174,41},{206,113,246,124,218,189,26,153,13,138,51,189,60,184},{216,112,225,125,230,143},{204,119,226,111,234,138},9,1,0.55,{230,104,245,99,237},{239,122,248,106},{227,127,226,121,252,97,60,153,0},3,18,0.5,{252,105,244,112,235,112},2,{220,67,254,122,245},{192,77,238,114,227,127},{231,75,235,107,247,78,243,116,14,155,0,217,33,176,63,179,33},{232,74,241,119,246,110,243}},C={235,248,206,249,208,206,250,234,249,230,251,240,251,206,251,235,252,206,249,208,206,253,206,254,206,254,206,255,234,252,236,240,251,206,240,235,252,206,249,208,206,241,206,254,240,249,206,254,234,252,236,240,251,206,242,235,243,206,244,208,206,245,206,246,206,247,234,251,236,240,251,206,232,206,233,236,240,251,206,234,240,248,236,240,251,206,235,235,243,206,244,208,206,236,206,237,206,238,234,251,236,240,251,206,239,235,224,206,239,208,206,225,208,236,240,251,206,226,206,227,236,240,251,206,228,206,254,236,240,251,206,229,235,224,206,229,208,206,230,208,236,240,251,206,231,192,248,236,192,249,240,251,206,216,234,250,255,249,192,250,240,251,192,251,206,217,206,218,234,252,255,249,235,248,206,249,208,206,219,234,249,230,252,240,252,206,220,206,221,236,240,252,206,251,235,252,206,249,208,206,254,206,222,206,254,206,223,234,252,236,240,252,206,240,235,252,206,249,208,206,254,206,254,206,208,206,216,254,234,252,236,240,252,206,242,192,251,236,240,252,206,232,206,217,236,240,252,206,228,206,254,236,240,252,206,209,240,251,206,209,208,206,217,197,236,240,252,206,231,240,251,236,192,249,240,252,206,210,234,250,255,249,235,211,206,212,208,192,252,240,251,234,250,255,249,192,253,240,251,192,254,206,233,234,251,255,249,240,251,206,213,208,223,206,214,208,245,209,249,234,250,255,249,240,251,194,249},P={{K={},C={192,248,192,249,234,249,255,249,192,250,192,251,234,249,255,249,194,248},P={},U={{0,7},{1,2},{0,8},{1,3}},nParams=0}},U={{1,73},{1,2},{1,3},{1,45},{1,82},{1,9},{1,44},{1,81},{1,83}},nParams=3},{K={{52,153,2,159,4,177,58,182},{16,157,5},{57,139,18,128,2},{211,147,14,139},{212,191,28,130,91},0,3,16,{213,144,10,154,25,142,14,181},6,{197,96,24,158,8,155,12,168,57,181,8,170,83,214,65,158},{202,109,14,146,21,152,55,183,34,183,28,175,56,223,88},{217,98,15,146,31,159},2,{223,96,7,141,63,140,5,132,55},1,12,28,{205,104,224,150,16,131,4,144,49,189,7,191,38,175,72,197,78,219,70,243,116,232},{196,111,252,138},{197,110,253,139,58,156,1,136,19,232},{212,99,232,116},{214,99,242,108},{211,97,252,106,29,155,50,133,8,186},{193,106,241,119,46,158,11,142},14,{195,116,243,113,39,184,31,132,0,143,54,176,33,189},{212,119,234,114}},C={235,248,206,249,208,206,250,234,249,230,251,240,251,206,251,235,252,206,249,208,206,253,206,254,206,253,206,255,234,252,236,240,251,206,240,235,252,206,249,208,206,253,206,253,240,250,206,241,234,252,236,240,251,206,242,192,248,236,240,251,206,243,206,253,236,240,251,206,244,240,248,236,192,249,240,251,206,245,234,250,255,249,235,248,206,249,208,206,246,234,249,230,252,240,252,206,251,235,252,206,249,208,206,247,206,232,254,206,253,206,233,234,252,236,240,252,206,240,235,252,206,249,208,206,253,206,232,240,250,206,253,234,252,236,240,252,206,234,206,247,236,240,252,206,235,240,249,236,240,252,206,236,192,250,236,240,252,206,237,235,238,206,237,208,206,239,208,236,240,252,206,224,206,225,236,240,252,206,226,235,238,206,226,208,206,227,208,236,240,252,206,244,240,248,236,240,252,194,249},P={},U={{1,45},{1,2},{1,46}},nParams=3},{K={{52,153,2,159,4,177,58,182},{16,157,5},{57,139,18,128,2},{211,147,14,139},{212,191,28,130,91},1,0,38,{213,144,10,154,25,142,14,181},{196,97,25,159,9,154,13,169,56,180,9,171,82,215,64,159},{196,110,23,154,29,218},{238,112,19,155,34,173,38},24,28,36,{206,103,227,145,19,156,7,151,50,178,4,184,37,208,75,194,77,212,69,244,119,247},0.6,{204,103,240,152,19,130,57,141,36,189,2,165,62,165,86},{223,104,241,152,25,133},9,{197,110,253,139,53,146,15,130,13},120,12,{192,107,240,118},{193,106,241,119,62,152,29,132,23,236},{208,127,228,112},{210,127,254,104},{223,125,248,110,225,151},{205,118,245,115,210,146,15,138},{206,113,246,124,218,189,26,153,13,138,51,189,60,184},{215,112,233,125},{250,100,255,103,203,152,30,129,9,146},30,14,100,0.5,7,{237,82},{236,91,209},110,125,{225,79,238,124,239,101,192,147,26,148},{245,72,252,125,251},46,56,80,200,160,75,82,88,0.25,{247,66,203,123,223,122,255,116,245,184,29,134,5,135,18,177,18,167,36,204,74},{231,101,245,84,232,123,229,109},20,22,10,2,{254,95,219,80,235,91,246,106,230,111},{251,93,194,72,197,121,224},{234,86,217,116,213,122,225,106}},C={235,248,206,249,208,206,250,234,249,230,253,240,253,206,251,235,252,206,249,208,206,253,206,254,206,254,206,255,234,252,236,240,253,206,240,235,252,206,249,208,206,254,206,254,240,249,206,254,234,252,236,240,253,206,241,235,242,206,243,208,206,244,206,245,206,246,234,251,236,240,253,206,247,206,232,236,240,253,206,233,206,254,236,240,253,206,234,240,248,236,192,248,240,253,206,235,234,250,255,249,235,248,206,249,208,206,236,234,249,230,254,240,254,206,251,235,252,206,249,208,206,253,206,237,254,206,253,206,254,234,252,236,240,254,206,240,235,252,206,249,208,206,254,206,238,206,254,206,254,234,252,236,240,254,206,247,206,253,236,240,254,206,239,240,250,236,240,254,206,224,192,249,236,240,254,206,225,235,226,206,225,208,206,227,208,236,240,254,206,228,206,238,236,240,254,206,229,235,226,206,229,208,206,230,208,236,240,254,206,234,240,253,236,235,248,206,249,208,206,236,234,249,230,255,240,255,206,251,235,252,206,231,208,206,216,206,217,234,250,236,240,255,206,240,235,252,206,249,208,206,253,206,218,254,206,219,206,220,254,234,252,236,240,255,206,247,206,253,236,240,255,206,239,240,251,223,251,482,255,249,206,221,223,232,251,474,255,249,206,222,236,240,255,206,224,240,251,223,251,456,255,249,192,250,223,232,251,443,255,249,235,242,206,243,208,206,223,206,237,206,208,234,251,236,240,255,206,225,235,226,206,225,208,206,209,208,236,240,255,206,228,206,235,236,240,255,206,229,235,226,206,229,208,206,210,208,236,240,255,206,234,240,253,236,235,248,206,249,208,206,250,234,249,230,240,240,240,206,251,235,252,206,249,208,206,254,206,211,206,254,206,244,234,252,236,240,240,206,240,235,252,206,249,208,206,253,206,212,254,206,219,206,238,254,234,252,236,240,240,206,241,240,251,223,251,321,255,249,235,242,206,243,208,206,213,206,214,206,215,234,251,223,232,251,308,255,249,235,242,206,243,208,206,200,206,201,206,202,234,251,236,240,240,206,233,206,254,236,240,240,206,234,240,253,236,192,248,240,240,206,238,234,250,255,249,192,251,240,240,192,250,206,253,240,251,223,251,270,255,249,206,203,223,232,251,262,255,249,206,232,234,252,255,249,240,240,223,206,204,208,245,206,205,234,250,230,241,192,252,240,240,206,253,234,250,230,242,235,248,206,249,208,206,250,234,249,230,243,240,243,206,251,235,252,206,249,208,206,254,206,206,206,254,206,206,234,252,236,240,243,206,240,240,251,223,251,684,255,249,235,252,206,249,208,206,253,206,207,254,206,219,206,192,254,234,252,223,232,251,658,255,249,235,252,206,249,208,206,254,206,193,206,219,206,192,254,234,252,236,240,243,206,241,235,242,206,249,208,206,253,206,253,206,253,234,251,236,240,243,206,233,206,254,236,240,243,206,234,240,240,236,192,248,240,243,206,192,234,250,255,249,240,251,230,244,209,249,230,245,240,240,206,194,208,223,206,195,208,245,209,250,234,250,255,249,240,253,206,194,208,223,206,195,208,245,209,251,234,250,255,249,224,223,206,196,209,252,236,194,249},P={{K={{41,146,9,159},{49,182},{48,191,53},{212,159,12,154,43,141,48,185,34,249},{194,148,25,128,27,208},{228,142,25,157,56,163,28},110,120,125,80,200,160,75,82,88,{217,66,233,151,70},{227,98,246},1,22,0.5,10,0,2,0.18,{215,110,234,104,26,133,30,158,11,187,26,188,33,168,51,136},0.22,{199,126,248,108,11,144,28,131},{221,124,249,107},{220,114,254,110,239,156,38,155,16,143,56},{216,117,237,99},{207,103,238,103,240,141,22,131,14,139,60,160},0.25,0.6,0.08,{204,122,242,97,226},1.08,{213,122,230,100},{198,121,250,113,243}},C={192,248,206,248,240,248,223,251,245,255,249,206,249,223,232,251,237,255,249,206,250,236,192,248,206,251,240,248,223,251,219,255,249,192,249,223,232,251,206,255,249,235,252,206,253,208,206,254,206,255,206,240,234,251,236,240,248,223,251,179,255,249,235,252,206,253,208,206,241,206,242,206,243,234,251,223,232,251,166,255,249,235,252,206,253,208,206,244,206,245,206,246,234,251,230,250,240,248,223,251,128,255,249,235,247,206,232,208,206,233,206,234,254,206,235,206,236,254,234,252,223,232,251,118,255,249,235,247,206,232,208,206,237,206,238,206,235,206,236,254,234,252,230,251,240,249,251,508,192,250,192,251,206,239,224,223,206,224,240,250,236,234,251,255,249,192,250,192,252,206,225,224,223,206,226,240,251,236,235,227,206,228,208,206,229,208,234,252,255,249,192,253,251,28,192,250,192,253,206,239,224,223,206,230,240,248,223,251,45,255,249,206,231,223,232,251,37,255,249,206,216,236,234,251,255,249,204,28,192,250,192,254,206,217,224,223,206,218,206,219,236,234,251,255,249,235,220,206,221,208,206,217,209,249,234,250,255,249,204,490,192,251,206,224,240,250,236,192,252,206,226,240,251,236,194,248},P={{K={0.16,{45,155,19,128,3},1,{197,148,1,131},{196,154,6,134,7,132,14,163,40,167,32},{192,157,21,155}},C={192,248,192,249,206,248,224,223,206,249,206,250,236,235,251,206,252,208,206,253,208,234,252,255,249,194,248},P={},U={{0,2},{0,6}},nParams=0}},U={{1,7},{0,2},{0,5},{1,8},{1,11},{1,9},{1,10}},nParams=2},{K={{40,132,20,153,44,177,41,166,57,147,56,203,80},{59,150,7,129},{50,150,6,158,2,163,46,161,59,166,45,140},{212,149,1,141,0},1.05,0.92},C={240,248,206,248,208,235,249,206,248,208,206,250,208,198,223,232,251,218,255,249,240,248,206,248,208,235,249,206,248,208,206,251,208,198,251,173,192,248,232,250,248,192,249,192,248,186,234,250,255,249,192,250,192,251,192,248,223,251,199,255,249,206,252,223,232,251,191,255,249,206,253,234,250,255,249,192,252,192,248,234,249,255,249,204,173,194,248},P={},U={{1,12},{1,13},{0,6},{0,7},{1,4}},nParams=1},{K={{40,132,20,153,44,177,41,166,57,147,56,203,80},{59,150,7,129},{50,150,6,158,2,163,46,161,59,166,45,140},{212,149,1,141,0},0.12,{192,157,21,155,13,150,49,173,60,168,18,178,91,218,93,216,67,238,115,254,105,253},0.45,{240,159,11,153},{225,154,21,146,20},0.14},C={240,248,206,248,208,235,249,206,248,208,206,250,208,198,223,232,251,218,255,249,240,248,206,248,208,235,249,206,248,208,206,251,208,198,251,188,192,248,192,249,206,252,224,223,206,253,206,254,236,234,251,255,249,235,255,206,240,208,206,241,209,249,234,250,255,249,204,188,194,248},P={{K={0.18,{60,153,17,135,1,146,53,161,32,172,22,206,87,222,89,212,127,234,119,226,101,249},0.6},C={192,248,192,249,206,248,224,223,206,249,206,250,236,234,251,255,249,194,248},P={},U={{0,0},{0,1}},nParams=0}},U={{0,5},{1,5}},nParams=1},{K={},C={240,248,250,248,192,249,240,248,186,234,250,255,249,194,248},P={},U={{1,12},{1,13}},nParams=1}},U={{1,2},{1,47},{1,45},{1,3},{1,5},{1,6},{1,7},{1,44}},nParams=5},{K={{52,153,2,159,4,177,58,182},{16,157,5},{43,156,11,153,37,148,47,161,32,167},{211,147,14,139},{212,191,28,130,91},1,0,36,{213,144,10,154,25,142,14,181},{196,97,25,159,9,154,13,169,56,180,9,171,82,215,64,159},{196,110,23,154,29,218},{238,112,19,155,34,173,38},44,100,96,{206,103,227,145,19,156,7,151,50,178,4,184,37,208,75,194,77,212,69,244,119,247},0.3,{218,109,250,136},{219,108,251,137,52,158,7,138,45,234},{214,101,234,138},{212,101,240,146},{213,99,242,104,27,153,44,135,14,184},{199,104,255,117,40,156,21,140},12,{215,96,251,103,24,133,34,130,31,186,9,186,53,162,45},{198,113,248,97,16,140},9,0.5,52,118,112,86,82,90,{210,118,230,126,226,67,14,129,27,134,13,236,20,189,34,166,84},{227,117,250,96,237,97,8}},C={235,248,206,249,208,206,250,234,249,230,252,240,252,206,251,235,252,206,249,208,206,253,206,254,206,254,206,255,234,252,236,240,252,206,240,235,252,206,249,208,206,254,206,254,240,249,206,254,234,252,236,240,252,206,241,235,242,206,243,208,206,244,206,245,206,246,234,251,236,240,252,206,247,206,232,236,240,252,206,233,240,250,236,240,252,206,234,192,248,236,240,252,206,235,235,236,206,235,208,206,237,208,236,240,252,206,238,206,239,236,240,252,206,224,206,254,236,240,252,206,225,240,248,236,192,249,240,252,206,226,234,250,255,249,192,250,240,252,192,251,206,253,206,227,234,252,255,249,192,252,240,252,235,242,206,243,208,206,228,206,229,206,230,234,251,235,242,206,243,208,206,255,206,231,206,216,234,251,206,217,234,252,255,249,192,253,240,252,192,254,206,232,234,251,255,249,240,252,206,218,208,223,206,219,208,245,240,251,234,250,255,249,240,252,194,249},P={},U={{1,47},{1,2},{1,3},{1,45},{1,4},{1,9},{1,44}},nParams=4},{K={{52,153,2,159,4,177,58,182},{16,157,5},{43,156,11,153,37,148,47,161,32,167},{211,147,14,139},{212,191,28,130,91},1,0,32,{213,144,10,154,25,142,14,181},{196,97,25,159,9,154,13,169,56,180,9,171,82,215,64,159},{196,110,23,154,29,218},{238,112,19,155,34,173,38},34,40,49,{206,103,227,145,19,156,7,151,50,178,4,184,37,208,75,194,77,212,69,244,119,247},0.55,{218,109,250,136},{},{210,101,246,154,29,128,63,143,26,191,4,167,48,167,80},{197,110,253,139,33,178,1,142,6,181,56,170,39,183},{215,98,243,109},{223,104,225,117},{196,111,250,103,18,130},8,0.7,{209,99,234,104,26},{254,96,227,107,207,156,18,157,13,150},6,14,0.5,3,0.25,{202,125,234,120,202,97,24,145,2},70,28,{245,126,237,123,202,108,17,152,3,216},{228,115,248,100},{228,114,227,121,234,104},{240,123,224,102,223,111,250,159},11,16,26,{74,162,38},{253,70,229,99,197,121,228,145,10,131,12,149,4,181,54,182},0.35,{236,74,235,113,242,96,197,110,23,145},{225,73,213,105,241,76,253,118,8,153,30,219,39,178,49,177,39},{238,72,207,117,240,108,253}},C={235,248,206,249,208,206,250,234,249,230,252,240,252,206,251,235,252,206,249,208,206,253,206,254,206,254,206,255,234,252,236,240,252,206,240,235,252,206,249,208,206,254,206,254,240,249,206,254,234,252,236,240,252,206,241,235,242,206,243,208,206,244,206,245,206,246,234,251,236,240,252,206,247,206,232,236,240,252,206,233,206,234,236,240,252,206,235,206,254,236,240,252,206,236,235,237,206,236,208,206,238,208,236,240,252,206,239,192,248,236,192,249,240,252,206,224,234,250,255,249,192,250,240,252,192,251,206,253,206,225,234,252,255,249,235,248,206,249,208,206,226,234,249,230,253,240,253,206,251,235,252,206,227,208,206,228,206,228,234,250,236,240,253,206,240,235,252,206,249,208,206,254,206,229,206,230,206,231,254,234,252,236,240,253,206,241,192,251,236,240,253,206,247,206,216,236,240,253,206,235,206,254,236,240,253,206,239,240,252,236,192,249,240,253,206,231,234,250,255,249,235,248,206,249,208,206,217,234,249,230,254,240,254,206,251,235,252,206,249,208,206,253,206,218,254,206,253,206,254,234,252,236,240,254,206,240,235,252,206,249,208,206,254,206,219,206,254,206,254,234,252,236,240,254,206,247,206,253,236,240,254,206,233,240,248,236,240,254,206,220,192,252,236,240,254,206,221,235,237,206,221,208,206,222,208,236,240,254,206,223,206,208,236,240,254,206,236,235,237,206,236,208,206,238,208,236,240,254,206,239,240,252,236,235,248,206,249,208,206,217,234,249,230,255,240,255,206,251,235,252,206,227,208,206,209,206,209,234,250,236,240,255,206,240,235,252,206,249,208,206,253,206,210,254,206,230,206,224,254,234,252,236,240,255,206,247,206,253,236,240,255,206,233,206,211,236,240,255,206,220,192,253,236,240,255,206,212,206,213,236,240,255,206,221,235,237,206,221,208,206,214,208,236,240,255,206,223,206,209,236,240,255,206,239,240,252,236,192,254,240,252,192,255,206,232,234,251,255,249,240,252,206,215,208,223,206,200,208,245,209,249,234,250,255,249,194,248},P={{K={{152,117,194,2,229,94},{155,79,192,9,239,109,191,106,206,232}},C={192,248,192,249,192,250,234,250,255,249,192,251,206,248,206,249,192,250,243,192,252,234,251,255,249,194,248},P={},U={{0,8},{1,2},{1,3},{0,9},{0,3}},nParams=0}},U={{1,76},{1,2},{1,3},{1,45},{1,47},{1,46},{1,9},{1,44},{1,27},{1,54}},nParams=4},{K={},C={209,249,194,249},P={{K={{152,125,238,3,230,98},{94,29,197,94,143,118,209,49,219,87},{95,28,196,95,142,118,199,60,217,64},{195,149,24,129,26,209},{231,137,26,130,59,164,31},150,160,165},C={192,248,206,248,192,249,240,248,223,251,247,255,249,206,249,223,232,251,239,255,249,206,250,243,240,248,223,251,217,255,249,192,250,223,232,251,204,255,249,235,251,206,252,208,206,253,206,254,206,255,234,251,234,251,255,249,194,248},P={},U={{0,0},{1,0},{0,1}},nParams=1}},U={{1,54},{1,45}},nParams=1},{K={{11,161,20,153,17,182,58,178,33,147,49,254,91,206,75,207,120},{40,29,236,110,129,123,238,51,208,100,165,27,141}},C={192,248,206,248,240,248,236,240,248,251,235,192,249,234,248,255,249,204,225,192,250,234,248,255,249,192,251,206,249,234,249,240,248,234,249,255,249,194,248},P={},U={{1,16},{1,28},{1,29},{1,89}},nParams=1},{K={{30,130,3,152,10,173,13,163,8,169,32,217,89,202},{152,64,202,10,206,121,189,74,226,47,229,7}},C={192,248,206,248,240,248,236,240,248,251,235,192,249,234,248,255,249,204,225,192,250,234,248,255,249,192,251,206,249,234,249,240,248,234,249,255,249,194,248},P={},U={{1,16},{1,32},{1,33},{1,89}},nParams=1},{K={{28,153,5,130,36,185,50,150,35,166,35,215,80},{63,150,6,133,39,166,17}},C={192,248,206,248,240,248,236,240,248,251,235,192,249,234,248,255,249,204,225,192,250,234,248,255,249,192,251,206,249,234,249,240,248,234,249,255,249,194,248},P={},U={{1,16},{1,36},{1,37},{1,89}},nParams=1},{K={{11,152,24,143,46,182,53,191,8,169,32,217,89,202},{150,97,233,11,207,90,188,122,244}},C={192,248,206,248,240,248,236,240,248,251,235,192,249,234,248,255,249,204,225,192,250,234,248,255,249,192,251,206,249,234,249,240,248,234,249,255,249,194,248},P={},U={{1,16},{1,42},{1,43},{1,89}},nParams=1},{K={{149,80,227,3,236,109},{155,79,192,9,249,87,178,117,194,45,254,11,211,56,156,77,153,21,245,24,153}},C={192,248,234,248,255,249,192,249,206,248,206,249,192,250,234,251,255,249,194,248},P={},U={{1,34},{1,54},{1,45}},nParams=0},{K={{52,153,2,159,4,177,58,182},{16,157,5},{57,139,18,128,2},{211,147,14,139},{212,191,28,130,91},1,0,38,{213,144,10,154,25,142,14,181},{196,97,25,159,9,154,13,169,56,180,9,171,82,215,64,159},{196,110,23,154,29,218},{238,112,19,155,34,173,38},24,28,36,{206,103,227,145,19,156,7,151,50,178,4,184,37,208,75,194,77,212,69,244,119,247},0.6,{204,103,240,152,19,130,57,141,36,189,2,165,62,165,86},{223,104,241,152,25,133},9,{197,110,253,139,53,146,15,130,13},12,{199,104,255,117},{192,107,240,118,63,153,28,133,22,237},{211,96,231,119},{211,126,255,105},{208,126,255,109,30,148},{204,119,244,114,211,147,14,139},{205,118,245,115,217,186,25,134,14,141,48,178,63,191},{214,113,232,124},{207,112,247,125,193,136,3,133,4,139},0.35,0.63,0.5,14,44,100,96,{215,114,228,101,249,108,17,158},{234,127,245,119},{226,112,237,123,236,106,195,148,25,139},11,8,{229,77,233,101,245,72,241,138,12,157,2,215,35,182,61,173,35},{234,76,243,121,244,104,241}},C={235,248,206,249,208,206,250,234,249,230,251,240,251,206,251,235,252,206,249,208,206,253,206,254,206,254,206,255,234,252,236,240,251,206,240,235,252,206,249,208,206,254,206,254,240,249,206,254,234,252,236,240,251,206,241,235,242,206,243,208,206,244,206,245,206,246,234,251,236,240,251,206,247,206,232,236,240,251,206,233,206,254,236,240,251,206,234,192,248,236,192,249,240,251,206,235,234,250,255,249,235,248,206,249,208,206,236,234,249,230,252,240,252,206,251,235,252,206,249,208,206,232,206,254,206,253,206,254,234,252,236,240,252,206,240,235,252,206,249,208,206,254,206,237,206,254,206,254,234,252,236,240,252,206,247,206,253,236,240,252,206,238,240,248,236,240,252,206,239,192,250,236,240,252,206,224,235,225,206,224,208,206,226,208,236,240,252,206,227,206,237,236,240,252,206,228,235,225,206,228,208,206,229,208,236,240,252,206,234,240,251,236,235,248,206,249,208,206,230,234,249,230,253,240,253,206,251,235,252,206,249,208,206,231,206,254,206,254,206,245,234,252,236,240,253,206,240,235,252,206,249,208,206,216,206,254,206,217,206,218,254,234,252,236,240,253,206,241,235,242,206,243,208,206,219,206,220,206,221,234,251,236,240,253,206,247,206,231,236,240,253,206,238,235,222,192,251,240,250,208,206,223,208,234,249,236,240,253,206,239,235,242,206,249,208,206,253,206,253,206,253,234,251,236,240,253,206,224,235,225,206,224,208,206,208,208,236,240,253,206,227,206,209,236,240,253,206,233,206,254,236,240,253,206,234,240,251,236,192,249,240,253,206,210,234,250,255,249,192,252,240,253,192,253,206,253,206,217,234,252,230,254,192,254,240,253,192,255,206,231,234,251,255,249,201,230,255,240,253,206,211,208,223,206,212,208,245,209,249,234,250,255,249,194,248},P={{K={{41,146,9,159},{150,83,249,10,234,105,190,108,197,46,206,53,223,61,159,138,48,182},0.15,{212,136,21,128,27,146,61,164,53,164,39,199},0.1,{214,148,31,147,1,138,59,171,33},2,{205,144,8,135,24,164,5,189,53,160},{198,144,23,157,8,132,21}},C={192,248,251,240,194,248,204,240,186,250,248,192,249,206,248,206,249,236,192,250,192,251,206,250,224,223,206,251,206,252,236,223,206,253,206,254,236,234,251,255,249,210,230,248,192,252,206,255,208,223,206,240,208,245,209,249,205,250,249,230,248,194,248},P={{K={{54,146,8,168,10,187,60},{42,157,10,152},{11,150,0,153,21,136,53,178},{206,155,25,139},0.2,{214,142,23,158,25,148,63,170,55,162,37,185},0.5,{208,150,17,145,7,136,5,169,39},1,1.1,{97,141,242,28,226,92,132,107,214,52,229,95},{168,224,250,100,80},{205,106,14,148,30,133,11,186,58,167}},C={240,249,251,240,194,248,204,240,201,250,248,192,249,192,250,240,248,206,248,208,236,192,251,206,249,235,250,240,248,206,248,208,206,251,208,234,249,236,192,252,192,253,206,252,224,223,206,253,206,254,236,223,206,255,206,240,236,234,251,255,249,192,254,192,255,206,241,234,250,255,249,192,240,206,242,192,241,206,243,235,250,240,248,206,248,208,206,251,208,234,249,243,243,192,242,234,251,255,249,192,243,223,206,244,208,245,234,249,255,249,194,248},P={},U={{0,0},{0,5},{0,6},{0,1},{0,2},{0,3},{0,7},{0,8},{0,9},{0,10},{0,11},{1,0}},nParams=2}},U={{1,7},{1,5},{0,8},{1,6},{0,9},{0,3},{1,2},{0,10},{0,7},{0,11},{1,0},{0,5}},nParams=0}},U={{1,78},{1,2},{1,47},{1,18},{1,3},{1,45},{1,9},{1,44},{1,6},{1,1},{1,7},{1,54}},nParams=3},{K={{43,158,2,130,7,179,60},{45,155,19,128,3},0.95,{240,153,21,130,4},0.24,1,{198,147,2,156},{193,159,11,155,2,129,51,174,45,162,45},{199,158,26,152},0.16,{243,96,8,158},{236,103,16,151,9},0},C={240,248,251,204,192,248,206,248,186,236,192,249,206,249,206,250,236,235,251,209,249,234,249,255,249,192,250,192,249,206,252,224,223,206,249,206,253,236,235,254,206,255,208,206,240,208,234,252,255,249,204,145,235,251,209,250,234,249,230,249,192,250,192,249,206,241,224,223,206,249,206,250,236,234,251,255,249,235,242,206,243,208,240,249,223,251,163,255,249,206,241,223,232,251,155,255,249,206,244,209,251,234,250,255,249,194,248},P={{K={{58,133,30,158,21,139,43,178,35,180,49,218,71,202,71,192,100},1,0.2,0},C={192,248,206,248,206,249,236,192,249,192,248,206,250,224,223,206,248,206,251,236,234,251,255,249,194,248},P={},U={{0,0},{0,2}},nParams=0},{K={0.16,{57,138,29,153,22,180,40,181,32,187,50,221,68,213,68,199,103},1},C={192,248,192,249,206,248,224,223,206,249,206,250,236,234,251,255,249,194,248},P={},U={{0,2},{0,0}},nParams=0},{K={{43,158,2,130,7,179,60},{14,155,19,128,10}},C={192,248,206,248,201,236,235,249,209,249,234,249,255,249,194,248},P={{K={{58,133,30,158,21,139,43,178,35,180,49,218,71,202,71,192,100},0},C={192,248,206,248,206,249,236,194,248},P={},U={{0,0}},nParams=0}},U={{0,0}},nParams=0}},U={{1,55},{1,56},{1,6}},nParams=1},{K={{59,158,31,143,35,182,43,160,57,132,41,210,89,203},{61,151,28,138,15,146,55,144,39,169,46,211,81},{54,151,0,153,6,143,56,176},{238,159,3},{199,137,20,130,12},{204,157,27,149},{208,148,13,148},{209,186,17,159,94},1,0,{197,96,24,158,8,155,12,168,57,181,8,170,83,214,65,158},{203,109,16,153,2,217},{239,113,18,154,35,172,39},{200,101,29,147,21,158,9,149,52,176,26,186,35,210,69,192,75,214,123,246,113,245},{201,106,13,157,22,159,52,136,33,176,31,160,59,216,91},{214,79,238,158,17,150},100,{222,105,240,153,24,132},0.18,0.55,340,160,{195,98,244,104,15,156,0,135},0.5,170,80,18,20,26,101,14,1.5,0.3,30,38,16,21,90,0.9,0.22,{246,124,248,127,232},{227,78,239,121},{226,64,232,124,225,110,208,137,14,157,14},{234,67,255,125},44,28,32,40,0.2,102,8,4,255,103,{231,72,223,85,215,116,237,108,239},36,{225,74,209,87},{81,146,16,204,52,149,123,155,26,233,236,125,134,109,209,58,202,124,165,120,161},{227,84,211,81,220,118,255,98,245,50},{254,93,194,82},{254,92,217,79,192,118,215,96,229,103},{238,81,214,92,241,117,236,117},15,{232,83,200,94,252,95,244,123,235,104,237,159,26,154},{241,82,215,95},58,{86,174,47,196,49,168,126,171,3,239,10,125,145,109,226,0,213,70,187,78,250,36,139,50,202,40,191,123,186,51,226,4,116,145,82,225},{135,85,192,70,201,79},12,{150,89,206,68,232,81,234,108,253,98},0.46,0.02,52,60,65,75,0.25,{47,203,40,222,4,164},10,0.52,180,50,0.15,{55,232,126,214,18,191,69,177,60,243,2,135},{156,36,176,76,220,113,216,83,213,116,251,62,202,111,20,148,26},{145,35,168,46,223,87,218}},C={192,248,223,206,248,208,245,206,249,234,250,251,233,194,248,204,233,235,250,206,251,208,206,252,234,249,230,248,240,248,206,253,206,249,236,240,248,206,254,235,255,206,251,208,206,240,206,241,206,240,206,241,234,252,236,240,248,206,242,235,243,206,244,208,206,241,206,241,206,241,234,251,236,240,248,206,245,206,240,236,240,248,206,246,206,241,236,240,248,206,247,206,232,236,240,248,206,233,192,248,236,192,249,240,248,206,234,224,223,206,245,206,235,236,234,251,255,249,235,250,206,251,208,206,252,234,249,230,249,240,249,206,254,235,255,206,251,208,206,241,206,236,206,241,206,237,234,252,236,240,249,206,238,235,255,206,251,208,206,239,206,224,254,206,239,206,225,254,234,252,236,240,249,206,242,235,243,206,244,208,206,226,206,227,206,228,234,251,236,240,249,206,246,206,241,236,240,249,206,247,206,229,236,240,249,206,233,240,248,236,192,250,240,249,206,230,234,250,255,249,192,251,240,249,192,252,206,231,206,216,234,252,255,249,192,253,240,249,235,243,206,244,208,206,228,206,217,206,218,234,251,235,243,206,244,208,206,230,206,219,206,220,234,251,206,221,234,252,255,249,192,254,240,249,206,222,234,250,230,250,192,249,240,250,206,223,224,223,206,208,206,240,236,235,209,206,210,208,206,211,208,234,252,255,249,235,250,206,251,208,206,252,234,249,230,251,240,251,206,254,235,255,206,251,208,206,240,206,241,206,241,206,212,234,252,236,240,251,206,242,235,243,206,244,208,206,213,206,214,206,215,234,251,236,240,251,206,245,206,200,236,240,251,206,246,206,241,236,240,251,206,247,206,201,236,240,251,206,233,240,249,236,192,250,240,251,206,230,234,250,255,249,235,250,206,251,208,206,252,234,249,230,252,240,252,206,254,235,255,206,251,208,206,240,206,241,206,241,206,230,234,252,236,240,252,206,238,235,255,206,251,208,206,241,206,241,206,240,206,230,254,234,252,236,240,252,206,242,235,243,206,244,208,206,213,206,214,206,215,234,251,236,240,252,206,245,206,200,236,240,252,206,246,206,241,236,240,252,206,247,206,201,236,240,252,206,233,240,251,236,235,250,206,251,208,206,252,234,249,230,253,240,253,206,254,235,255,206,251,208,206,241,206,202,206,241,206,202,234,252,236,240,253,206,238,235,255,206,251,208,206,241,206,219,206,239,206,203,254,234,252,236,240,253,206,242,235,243,206,244,208,206,204,206,232,206,232,234,251,236,240,253,206,246,206,241,236,240,253,206,247,206,205,236,240,253,206,233,240,251,236,192,250,240,253,206,203,234,250,255,249,235,250,206,251,208,206,206,234,249,230,254,240,254,206,254,235,255,206,251,208,206,240,206,215,254,206,240,206,241,234,252,236,240,254,206,238,235,255,206,251,208,206,241,206,207,206,241,206,241,234,252,236,240,254,206,245,206,240,236,240,254,206,192,206,193,236,240,254,206,194,192,255,236,240,254,206,195,235,209,206,195,208,206,196,208,236,240,254,206,197,206,198,236,240,254,206,199,235,209,206,199,208,206,184,208,236,240,254,206,247,206,205,236,240,254,206,233,240,251,236,235,250,206,251,208,206,206,234,249,230,255,240,255,206,254,235,255,206,251,208,206,240,206,215,254,206,241,206,217,234,252,236,240,255,206,238,235,255,206,251,208,206,241,206,227,206,241,206,185,234,252,236,240,255,206,245,206,240,236,240,255,206,192,206,186,236,240,255,206,194,192,240,236,240,255,206,195,235,209,206,195,208,206,187,208,236,240,255,206,197,206,188,236,240,255,206,199,235,209,206,199,208,206,184,208,236,240,255,206,247,206,205,236,240,255,206,233,240,249,236,235,250,206,251,208,206,189,234,249,230,240,240,240,206,254,235,255,206,251,208,206,190,206,241,206,241,206,215,234,252,236,240,240,206,238,235,255,206,251,208,206,191,206,241,206,240,206,176,254,234,252,236,240,240,206,242,235,243,206,244,208,206,177,206,178,206,179,234,251,236,240,240,206,245,206,180,236,240,240,206,194,192,255,236,240,240,206,192,206,181,236,240,240,206,197,206,230,236,240,240,206,195,235,209,206,195,208,206,196,208,236,240,240,206,246,206,241,236,240,240,206,247,206,205,236,240,240,206,233,240,249,236,192,250,240,240,206,182,234,250,255,249,192,251,240,240,192,252,206,240,206,239,234,252,255,249,192,241,240,240,192,242,206,180,234,251,255,249,235,250,206,251,208,206,189,234,249,230,241,240,241,206,254,235,255,206,251,208,206,190,206,241,206,241,206,215,234,252,236,240,241,206,238,235,255,206,251,208,206,183,206,241,206,240,206,176,254,234,252,236,240,241,206,242,235,243,206,244,208,206,168,206,169,206,169,234,251,236,240,241,206,245,206,170,236,240,241,206,194,235,243,206,244,208,206,204,206,204,206,204,234,251,236,240,241,206,192,206,171,236,240,241,206,197,206,230,236,240,241,206,195,235,209,206,195,208,206,196,208,236,240,241,206,246,206,241,236,240,241,206,247,206,205,236,240,241,206,233,240,249,236,192,250,240,241,206,182,234,250,255,249,192,251,240,241,235,243,206,244,208,206,204,206,232,206,232,234,251,206,240,206,216,234,252,255,249,192,241,240,241,192,242,206,170,234,251,255,249,240,240,206,172,208,223,206,173,208,245,209,249,234,250,255,249,240,241,206,172,208,223,206,173,208,245,209,250,234,250,255,249,194,248},P={{K={0.16,{60,153,17,135,1,146,53,161,32,172,22,206,87,222,89,212,127,234,119,226,101,249},1,{211,153,21,130,13},0.9,{246,157,5,155},{231,152,27,144,18},0.18},C={192,248,192,249,206,248,224,223,206,249,206,250,236,234,251,255,249,192,248,192,250,206,248,224,223,206,251,206,252,236,234,251,255,249,235,253,206,254,208,206,255,209,249,234,250,255,249,194,248},P={{K={{57,146,2,159,23,176,32}},C={192,248,223,206,248,208,245,234,249,255,249,194,248},P={},U={{0,1}},nParams=0}},U={{0,1},{1,0},{1,2}},nParams=0},{K={{13,148,16,135,9},{14,153,27,158,21},{28,150,29,131,2,130,47,188,32,167,48},{233,148,7,154,9,140,63,179,35},0.2,{209,159,23,156,15},0.94,{240,159,11,153},{225,154,21,146,20},0.22,{247,115,18,155,27},{211,229,229,75,149,71,244,58,224,127,169,121,195,231,20,76,181,46,60,126,149,57,226,226,84,151,91,212,5,244,88,171,77,234,85,161,44,195,50,151}},C={235,248,209,249,234,249,255,249,235,248,209,250,234,249,255,249,235,248,209,251,234,249,255,249,235,248,209,252,234,249,255,249,235,249,192,248,206,250,208,205,249,251,230,250,230,249,230,248,241,248,249,250,237,251,237,252,240,248,240,249,240,250,205,250,250,230,252,230,251,240,251,230,250,240,251,210,249,251,161,235,248,209,253,234,249,255,249,204,204,192,248,206,250,224,236,235,249,192,248,206,251,208,205,249,251,230,255,230,254,230,253,241,253,254,255,237,240,237,241,240,253,240,254,240,255,205,250,250,230,241,230,240,240,240,230,255,240,240,210,249,251,96,235,248,209,254,234,249,255,249,204,139,192,248,206,251,224,236,235,248,209,255,234,249,255,249,192,253,192,255,206,252,224,223,206,253,206,254,236,234,251,255,249,235,255,206,240,208,206,241,209,240,234,250,255,249,235,242,206,243,234,249,255,249,194,248},P={{K={{11,161,20,153,17,182,58,178,33,147,49,254,91,206,75,207,120}},C={192,248,206,248,208,251,247,192,249,234,248,255,249,204,247,194,248},P={},U={{0,0},{0,1}},nParams=0},{K={{30,130,3,152,10,173,13,163,8,169,32,217,89,202}},C={192,248,206,248,208,251,247,192,249,234,248,255,249,204,247,194,248},P={},U={{0,0},{0,2}},nParams=0},{K={{28,153,5,130,36,185,50,150,35,166,35,215,80}},C={192,248,206,248,208,251,247,192,249,234,248,255,249,204,247,194,248},P={},U={{0,0},{0,3}},nParams=0},{K={{11,152,24,143,46,182,53,191,8,169,32,217,89,202}},C={192,248,206,248,208,251,247,192,249,234,248,255,249,204,247,194,248},P={},U={{0,0},{0,4}},nParams=0},{K={{57,158,2,136,10,177,55,182,46,179}},C={192,248,223,206,248,208,245,234,249,255,249,194,248},P={},U={{1,4}},nParams=0},{K={{57,146,2,159,23,176,32}},C={192,248,223,206,248,208,245,234,249,255,249,194,248},P={},U={{1,9}},nParams=0},{K={0.2,{57,138,29,153,22,180,40,181,32,187,50,221,68,213,68,199,103},1},C={192,248,192,249,206,248,224,223,206,249,206,250,236,234,251,255,249,194,248},P={},U={{0,5},{0,6}},nParams=0},{K={{45,150,3,142,11,171},{58,157,1,152,20,143,35}},C={192,248,223,251,244,255,249,192,248,206,248,208,251,227,192,248,223,206,249,208,245,234,249,255,249,204,227,194,248},P={},U={{0,8}},nParams=0}},U={{0,11},{0,12},{0,13},{0,14},{0,15},{0,1},{0,16},{0,17},{0,10}},nParams=0}},U={{1,58},{1,6},{1,2},{1,3},{1,45},{1,4},{1,5},{1,47},{1,46},{1,9},{1,44},{1,16},{1,29},{1,33},{1,37},{1,43},{1,55},{1,56}},nParams=0},{K={{45,150,3,142,11,171},{55,150,1,152,7,142,57,177},{17,156,4},{212,159,12,154,42,151,40,162,63,164},{207,154,24,138},{209,148,31,130,5,143,49,149,59,162,47,130,78,218},{208,148,13,148},{209,186,17,159,94},{227,141,22,158,34,129,7,168,48,187},60,{215,110,8,156,27,128,12,179},0,20,0.5,30,{206,103,227,145,19,156,7,151,50,178,19,165,40,209,74,129},{206,104,237,148,7,220},{232,122,237,145,36,183,40},18,26,{211,106,230,148,30,129,2,146,15,191,1,189,40,173,78,199,80,217,64,241,122,234},0.1,{209,98,245,101,30,135,60,128,25,184,7,184,51,160,83},{192,107,240,118},{},{215,101,254,107,60,141,6,152,9,142,25,187,34,167,48},{214,114,255,108,9,156},{194,91,226,98,229,130},9999,{217,120,231,120,241,184,19,131,9,129,48,188,51,162,50,179},2,0.15,{212,122,240,108,224,179,24,145,8,139},{211,113,252,101,207,99,21,154},1,{233,119,245,105,237},{242,120,244,99,236,87,4,135,20},{231,114,227,125},{224,111,248,97},10000,0.6,0.26,{244,66,250,121,234},{237,67,239,127,254,109,215,138,1,158,9},{235,66,254,124},{231,75,235,107,247,78,243,116,14,155,0,217,33,176,63,179,33},{232,74,241,119,246,110,243},{229,72,208,111,224,76,237,101,29,152},{228,73,209,110,225,76,225,98,19,144,20,143},{231,70,210,105,226,85,228,96,27,156}},C={192,248,223,251,244,255,249,192,248,206,248,208,251,236,192,248,194,249,204,236,235,249,206,250,208,206,251,234,249,230,248,240,248,206,252,206,253,236,240,248,206,254,235,255,206,240,208,206,241,206,241,234,250,236,240,248,206,242,235,255,206,250,208,206,243,206,244,206,245,206,246,254,234,252,236,240,248,206,247,235,232,206,233,208,206,234,206,244,206,235,234,251,236,240,248,206,236,206,237,236,240,248,206,238,206,243,236,240,248,206,239,206,224,236,240,248,206,225,201,236,240,248,206,226,186,236,240,248,206,227,206,228,236,240,248,206,229,186,236,240,248,206,248,192,249,236,192,250,240,248,206,246,234,250,255,249,192,251,240,248,192,252,206,230,206,231,234,252,255,249,235,249,206,250,208,206,216,234,249,230,249,240,249,206,252,206,217,236,240,249,206,254,235,255,206,250,208,206,218,206,243,206,218,206,243,234,252,236,240,249,206,242,235,255,206,250,208,206,243,206,243,206,243,206,243,234,252,236,240,249,206,236,206,218,236,240,249,206,219,192,253,236,240,249,206,220,235,221,206,220,208,206,222,208,236,240,249,206,227,206,223,236,240,249,206,248,240,248,236,192,250,240,249,206,246,234,250,255,249,192,254,240,248,206,208,234,250,230,250,192,255,240,250,206,209,224,223,206,210,206,218,236,235,221,206,211,208,206,212,208,234,252,255,249,240,248,206,213,208,223,206,214,208,245,209,249,234,250,255,249,201,230,251,210,230,252,210,230,253,201,230,254,240,248,206,215,208,223,206,214,208,245,209,250,234,250,255,249,192,242,206,200,208,223,206,214,208,245,209,251,234,250,255,249,192,242,206,201,208,223,206,214,208,245,209,252,234,250,255,249,240,248,250,248,240,248,194,249},P={{K={{20,132,53,153,4,184,62,186,35,160,12,210,91,198},{22,141,16,186,15,147,51,182,34,173},{41,144,0,132,5,141,62}},C={192,248,206,248,208,251,243,194,248,204,243,192,249,186,234,249,255,249,192,248,206,249,186,236,192,250,206,250,201,236,194,248},P={},U={{0,8},{0,9},{1,0}},nParams=0},{K={{40,132,20,153,44,177,41,166,57,147,56,203,80},{59,150,7,129},{50,150,6,158,2,163,46,161,59,166,45,140},{212,149,1,141,0},{209,148,6,134,29,138,50,185}},C={240,248,206,248,208,235,249,206,248,208,206,250,208,198,223,232,251,218,255,249,240,248,206,248,208,235,249,206,248,208,206,251,208,198,251,194,186,250,248,201,250,249,240,248,206,252,208,250,250,192,251,206,252,208,250,252,204,194,194,248},P={},U={{1,3},{1,6},{1,4},{1,0},{1,5}},nParams=1},{K={{40,132,20,153,44,177,41,166,57,147,56,203,80},{59,150,7,129},{50,150,6,158,2,172,52,163,42,164,38,211,67},{212,149,1,141,0},{209,148,6,134,29,138,50,185},{239,157,2,152},{226,159,4},{220},8,{223},{238,114,63,135,14,142,4,180,57,182,6,172,81,208},{221,70,21,155,66},{231,102,10},{217,103,31,148,23},{196,99,25,138,22,153}},C={192,248,232,251,241,194,248,204,241,240,248,206,248,208,235,249,206,248,208,206,250,208,249,223,251,210,255,249,240,248,206,248,208,235,249,206,248,208,206,251,208,249,251,200,194,248,204,200,240,248,206,252,208,192,249,227,230,249,235,253,206,254,208,240,249,206,255,208,234,249,206,240,211,223,232,251,166,255,249,235,253,206,254,208,240,249,206,241,208,234,249,206,240,211,251,91,186,250,250,192,251,206,242,186,236,192,252,206,252,235,243,206,244,208,192,253,206,255,208,206,245,208,192,253,206,255,208,206,246,208,240,249,206,255,208,197,192,253,206,241,208,206,245,208,192,253,206,241,208,206,246,208,240,249,206,241,208,197,234,252,236,204,91,194,248},P={},U={{1,3},{1,4},{1,6},{0,8},{1,0},{1,5}},nParams=1},{K={{40,132,20,153,44,177,41,166,57,147,56,203,80},{59,150,7,129},{50,150,6,158,2,163,46,161,59,166,45,140},{212,149,1,141,0},{245,154,6,132},{230,153,26,145,19},0.1},C={240,248,206,248,208,235,249,206,248,208,206,250,208,198,223,232,251,218,255,249,240,248,206,248,208,235,249,206,248,208,206,251,208,198,251,196,201,250,248,192,249,251,194,235,252,206,253,208,206,254,209,249,234,250,255,249,204,194,204,196,194,248},P={{K={{20,132,53,153,4,184,62,186,35,160,12,210,91,198}},C={192,248,206,248,201,236,194,248},P={},U={{0,2}},nParams=0}},U={{1,3},{1,6},{0,8}},nParams=1}},U={{1,93},{1,44},{1,2},{1,3},{1,45},{1,92},{1,5},{1,6},{1,16},{1,91},{1,1}},nParams=0},{K={{21,130,19,189,12,172,48,177,33,162},{40,145,1,133,4,140,63}},C={192,248,206,248,201,236,192,249,201,234,249,255,249,192,250,234,248,230,248,240,248,206,249,186,236,194,248},P={},U={{1,16},{1,91},{1,94}},nParams=0},{K={{54,146,8,168,10,187,60},{22,141,16,184,9,135,61,184,43,131,39,197},{23,140,17,187,14,146,50,183,35,172},{208,155,6,139,6,150},{215,146,6,134,11,143,56},{242,142,31,158,30},{216,26,238,76,142,72,207,61,235,96,162,126,184,232,15,225,86,255,242,25,140,99,112,226,22,226,72,137,125,195,40,194,67,219,50,186}},C={240,249,251,240,194,248,204,240,240,248,206,248,208,192,248,206,249,208,198,251,152,192,249,206,250,192,249,206,250,208,232,236,192,250,192,249,206,250,208,234,249,255,249,192,249,206,250,208,251,178,192,251,223,251,198,255,249,192,251,206,251,208,251,176,192,251,206,252,201,236,204,176,204,174,192,252,234,248,230,250,240,250,206,252,186,236,235,253,206,254,234,249,255,249,204,152,194,248},P={},U={{1,18},{1,16},{1,91},{1,93},{1,94}},nParams=2},{K={{58,133,30,158,21,139,43,178,35,180,49,218,71,202,71,192,100},1},C={192,248,206,248,206,249,236,194,248},P={},U={{1,55}},nParams=0},{K={{13,148,16,135,9},0.34,{44,154,18,129,2},1,{196,149,0,130},{199,157,5,153,4,131,13,172,43,160,35},{193,156,20,154}},C={235,248,209,249,234,249,255,249,192,248,192,250,206,249,224,223,206,250,206,251,236,235,252,206,253,208,206,254,208,234,252,255,249,194,248},P={{K={0.3,{57,138,29,153,22,180,40,181,32,187,50,221,68,213,68,199,103},0},C={192,248,192,249,206,248,224,223,206,249,206,250,236,234,251,255,249,194,248},P={},U={{0,0},{0,1}},nParams=0}},U={{1,6},{1,55},{1,56}},nParams=0}}
return _I10110(____24,_O_O25,_1O__1,_I0O26)
