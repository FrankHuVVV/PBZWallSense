--[[
  PBZWallSense  v0.1.0-preview
  Phantom Blade Zero (UE 5.7 · build 26266538) · UE4SS 3.0.1 · 方案 A 预览版

  用途：跑图时，在**没进战斗**的前提下，把被墙/门/地形挡住的敌人用一枚很淡的
        菱形标记透出来，让你在推门前就知道屋里有没有人。

  触发（全部满足才画）：
    1. 敌人存活，且在 maxDistCm 内；
    2. 敌人没把你放进它的仇恨列表（BP_PBZHatredManagerComponent.HatredList）；
    3. 你不在战斗状态（GameplayEvent 的 InCombat 标签；任一敌人恨你也算）；
    4. 相机 → 敌人的射线被别的东西先挡住（这才是"隔墙"）；
    5. 敌人落在屏幕内。

  实现要点：
    · 不写任何游戏文件，只读敌人状态；
    · 不动渲染管线——标记是 UMG 控件（屏幕空间），天然不会被墙挡住；
    · 判定 10 Hz，绘制跟帧，控件池化复用（上限 maxMarkers）。

  热键：
    F7  开 / 关
    F8  打印一帧诊断（相机、敌人数、射线命中、控件状态）
]]

local MOD     = "PBZWallSense"
local VERSION = "0.1.0-preview"

local CFG = {
    enabled        = true,

    maxDistCm      = 2500,        -- 只关心这个半径内的敌人（2500 cm = 25 m）
    heightCm       = 40,          -- 从敌人 Actor 位置往上抬多少当"胸口"

    alpha          = 0.55,        -- 标记不透明度（0.35 ~ 0.65 是"轻微"区间）
    alphaPulse     = 0.05,        -- 呼吸幅度，0 = 不呼吸
    pulsePeriodS   = 2.4,

    sizeMinPx      = 20,
    sizeMaxPx      = 52,
    sizeGain       = 2.6,         -- 距离→尺寸的放大系数（原来 1.0，嫌小就继续加）
    sizeScale      = 1.0,         -- 整体缩放倍率
    maxMarkers     = 8,

    onlyOccluded   = true,        -- 只标被挡住的（方案 A 的核心）
    hideInCombat   = true,        -- 战斗中全部隐藏

    tickMs         = 100,         -- 判定频率
    drawMs         = 16,          -- 绘制频率

    traceChannel   = 0,           -- KismetSystemLibrary 的 ETraceTypeQuery；0 多数项目 = Visibility
    readoutMode    = "tip",       -- "tip" = 屏幕底部一行；"log" = 只写日志（绝对不闪）
    widgetClass    = "W_PaintSize_C",
    -- 按顺序试：先找带图片的 HUD 类，最后退到能显示文字的提示条
    widgetCandidates = {
        "wb_damageindicator_C",           -- 受击方向指示器：屏幕空间，通常就是一张图标
        "WG_ExecutePoint_Execution_C",    -- 处决点标记
        "WG_ExecutePoint_ShachiWeapon_C", -- 破势点标记
        "WG_PBZFocus_C",                  -- 锁定/聚焦相关
        "W_ShieldBar_C",
        "W_QTEActivateWidget_C",
        "W_AbilityMaterialLine_C",
        "W_PaintSize_C",
        "WB_TipsText_C",                  -- 兜底：墨条文字
    },
    fallbackWidget = "WB_TipsText_C",
    textGlyph      = "◎",
    widgetZ        = 300,
    spritePath     = "art/ring.png",   -- 64x64 水墨飞白环（白墨遮罩，靠 tint 上色）

    tint = { R = 0.78, G = 0.22, B = 0.20 },   -- 暗红：不像血红那么扎眼，暗场里也压得住
}

-- ------------------------------------------------------------------ 基础工具

local function log(fmt, ...)
    print(string.format("[%s] " .. fmt .. "\n", MOD, ...))
end

local function valid(obj)
    if obj == nil or type(obj) == "string" or type(obj) == "number" or type(obj) == "boolean" then
        return false
    end
    local ok, r = pcall(function() return obj:IsValid() end)
    return ok and r == true
end

-- 仇恨列表里的元素可能是 TObjectPtr 包装（userdata，要 :get()），也可能直接就是对象
local function unwrap(a)
    if a == nil then return nil end
    local ok, v = pcall(function() return a:get() end)
    if ok and v ~= nil then return v end
    return a
end

local function modDir()
    local ok, info = pcall(debug.getinfo, 1, "S")
    local src = ok and info and info.source or ""
    src = src:gsub("^@", "")
    local dir = src:match("^(.*)[/\\][^/\\]*$") or "."
    return dir .. "/"
end

local function getPC()
    local ok, pc = pcall(FindFirstOf, "PlayerController")
    if ok and valid(pc) then return pc end
    return nil
end

local function distCm(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ------------------------------------------------------------------ 谁是敌人

local PLAYER_PREFIX = "BP_Renewal_Hun"   -- 玩家（胡）的类，永远不算敌人

local function classOf(actor)
    local ok, cn = pcall(function() return actor:GetClass():GetFName():ToString() end)
    return ok and cn or "?"
end

local function isEnemy(actor)
    if not valid(actor) then return false end
    local cn = classOf(actor)
    if cn:find(PLAYER_PREFIX, 1, true) then return false end
    local ok, monster = pcall(function() return actor.BIsMonster end)
    if ok and monster == true then return true end
    return cn:find("^BP_Monster") ~= nil
end

local function isDead(actor)
    local ok, hp = pcall(function() return actor.AttributeSetBase.Health.CurrentValue end)
    if ok and type(hp) == "number" and hp <= 0 then return true end
    local ok2, dead = pcall(function() return actor:IsDead() end)
    return ok2 and dead == true
end

local function listEnemies()
    local out = {}
    local ok, all = pcall(FindAllOf, "PBZCharacter_NPC")
    if not ok or type(all) ~= "table" then return out end
    for _, e in ipairs(all) do
        if isEnemy(e) then out[#out + 1] = e end
    end
    return out
end

-- 敌人是否已经"发现"玩家：玩家是否在它的仇恨列表里
local function hatesPlayer(enemy, pawn)
    local ok, res = pcall(function()
        local list = enemy.BP_PBZHatredManagerComponent.HatredList
        if not list then return false end
        local hit = false
        local pawnAddr = pawn:GetAddress()
        list:ForEach(function(_, a)
            local actor = unwrap(a)
            if valid(actor) and actor:GetAddress() == pawnAddr then
                hit = true
            end
        end)
        return hit
    end)
    return ok and res == true
end

-- ------------------------------------------------------------------ 状态

local M = {
    on         = CFG.enabled,
    inCombat   = false,
    targets    = {},      -- { {actor=, x=, y=, dist=, alpha=} }
    widgets    = {},
    sprite     = nil,
    spriteTried = false,
    canvas     = { hud = nil, w = 0, h = 0 },
    live       = false,   -- F8 打开后，屏幕底部的数值持续刷新
    nextTip    = 0,
    screen     = {},      -- draw() 算好的屏幕坐标，HUD 回调直接拿来画
    imgOf      = {},      -- 控件地址 -> 它在树里的图片子控件
    inDraw     = false,   -- 防重入
    diag       = { enemies = 0, traced = 0, blocked = 0, marked = 0, projOk = 0, combatHits = 0,
                   inRange = 0, dead = 0, hate = 0, nearest = math.huge, projMode = "-" },
    warned     = {},
    slot       = 0,
}

local function warnOnce(key, msg)
    if M.warned[key] then return end
    M.warned[key] = true
    log("!! " .. msg)
end

-- ------------------------------------------------------------------ 战斗状态

-- 复用 PBZHaptics 验证过的通道：GameplayEvent 的 TagName 里有 InCombat / OffCombat
local function tagString(v)
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" and #s > 0 then return s end
    if type(v) == "string" then return v end
    return nil
end

local function onGameplayEvent(...)
    local n = select("#", ...)
    for i = 1, n do
        local arg = select(i, ...)
        if type(arg) == "table" or type(arg) == "userdata" then
            local ok, tag = pcall(function() return arg.TagName or arg.EventTag end)
            if ok and tag ~= nil then
                local s = tagString(tag)
                if s then
                    if s:find("InCombat", 1, true) then
                        M.inCombat = true
                        M.diag.combatHits = M.diag.combatHits + 1
                    elseif s:find("OffCombat", 1, true) then
                        M.inCombat = false
                        M.diag.combatHits = M.diag.combatHits + 1
                    end
                end
            end
        end
    end
end

pcall(function()
    RegisterHook("/Script/GameplayAbilities.AbilitySystemBlueprintLibrary:SendGameplayEventToActor",
                 onGameplayEvent)
    log("战斗状态钩子: 已注册")
end)

-- ------------------------------------------------------------------ 投影

-- 手动投影：UE4SS 对「引用型 out 参数」的支持不稳，这里直接用相机矩阵算，最可靠
local function viewportSize(pc)
    local w, h = 0, 0
    pcall(function()
        local sz = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"):GetViewportSize(pc)
        if sz and sz.X and sz.X > 0 then w, h = sz.X, sz.Y end
    end)
    return w, h
end

local function projectManual(pc, world)
    local cam = pc.PlayerCameraManager
    if not valid(cam) then return nil end
    local cl = cam:GetCameraLocation()
    local cr = cam:GetCameraRotation()
    local fov = 90.0
    pcall(function()
        local f = cam:GetFOVAngle()
        if type(f) == "number" and f > 1 then fov = f end
    end)
    local vw, vh = viewportSize(pc)
    if vw <= 0 or vh <= 0 then vw, vh = 1920, 1080 end

    local yaw, pitch = math.rad(cr.Yaw), math.rad(cr.Pitch)
    local cy, sy = math.cos(yaw), math.sin(yaw)
    local cp, sp = math.cos(pitch), math.sin(pitch)
    local fx, fy, fz = cp * cy, cp * sy, sp
    local rx, ry = -sy, cy
    local ux, uy, uz = -sp * cy, -sp * sy, cp

    local px, py, pz = world.X - cl.X, world.Y - cl.Y, world.Z - cl.Z
    local depth = px * fx + py * fy + pz * fz
    if depth <= 1.0 then return nil end

    local right = px * rx + py * ry
    local up = px * ux + py * uy + pz * uz
    local tanH = math.tan(math.rad(fov) * 0.5)
    local half = vw * 0.5
    return half + (right / depth) * half / tanH,
           vh * 0.5 - (up / depth) * half / tanH
end

local function project(pc, world)
    -- 1) 引擎接口：out 参数按表传入（UE4SS 的惯例）
    local screen = {}
    local ok = pcall(function()
        return pc:ProjectWorldLocationToScreen(world, screen, false)
    end)
    if ok and type(screen) == "table" and type(screen.X) == "number" then
        M.diag.projMode = "engine"
        return screen.X, screen.Y
    end
    -- 2) 手动投影兜底
    local sx, sy = projectManual(pc, world)
    if sx then M.diag.projMode = "manual" end
    return sx, sy
end

-- 相机 → 敌人 的射线，返回 true 表示"被别的东西挡住了"
local function blockedByGeometry(pawn, camLoc, goal, enemy)
    local ks = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if not valid(ks) then
        warnOnce("ks", "找不到 KismetSystemLibrary，遮挡判定关闭")
        return false
    end
    local hit = {}
    local color = { R = 0.0, G = 0.0, B = 0.0, A = 0.0 }
    local ok, wasHit = pcall(function()
        return ks:LineTraceSingle(pawn, camLoc, goal, CFG.traceChannel, false, {}, 0, hit,
                                  true, color, color, 0.0)
    end)
    if not ok then
        warnOnce("trace", "LineTraceSingle 失败：" .. tostring(wasHit))
        return false
    end
    if wasHit ~= true then
        return false                                       -- 一路无阻
    end
    local h = hit.HitObjectHandle
    local actor
    pcall(function() actor = h.ReferenceObject:Get() end)
    if not valid(actor) then
        pcall(function() actor = h.Actor end)
    end
    if not valid(actor) then
        return true                                        -- 打到了东西但取不到 actor：保守当作挡住
    end
    return actor:GetAddress() ~= enemy:GetAddress()
end

-- ------------------------------------------------------------------ 控件池

-- 贴图路径：不写死任何绝对路径，按可用信息推导
--   1) UE4SS 若暴露 GetModDir()，直接用它
--   2) 从 package.path 里挖出本模组目录（UE4SS 会把它加进去）
--   3) 相对路径：UE 的进程工作目录是游戏 exe 所在目录，所以是 ue4ss/Mods/...
local function spriteCandidates()
    local out = {}

    local okDir, d = pcall(function() return GetModDir() end)
    if okDir and type(d) == "string" and #d > 2 then
        out[#out + 1] = (d:gsub("[/\\]+$", "")) .. "/art/ring.png"
    end

    pcall(function()
        for p in tostring(package.path):gmatch("[^;]+") do
            local base = p:match("^(.-)[/\\]Scripts[/\\][^/\\]+$")
            if base and #base > 2 then out[#out + 1] = base .. "/art/ring.png" end
        end
    end)

    out[#out + 1] = "ue4ss/Mods/PBZWallSense/art/ring.png"
    out[#out + 1] = "Mods/PBZWallSense/art/ring.png"
    out[#out + 1] = "art/ring.png"
    return out
end

local function spriteTexture(pc)
    if M.spriteTried then return M.sprite end
    M.spriteTried = true
    local lib = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    if not valid(lib) then
        log("!! 找不到 KismetRenderingLibrary，贴图跳过")
        return nil
    end
    for _, path in ipairs(spriteCandidates()) do
        local ok, tex = pcall(function() return lib:ImportFileAsTexture2D(pc, path) end)
        if ok and valid(tex) then
            M.sprite = tex
            log("使用自定义贴图: " .. path)
            return tex
        end
        log("!! 贴图尝试失败: " .. path .. " -> " .. tostring(tex))
    end
    log("!! 所有候选路径都失败，标记将退回控件默认图标")
    return nil
end

local IMAGE_NAMES = { "Circle", "Image", "Img", "Icon", "Dot", "Mark", "Point", "Cross", "Brush" }

-- 不同 UI 类里那个图片子控件叫法不一样，挨个试
local function imageChild(w)
    for _, n in ipairs(IMAGE_NAMES) do
        local ok, child = pcall(function() return w[n] end)
        if ok and child ~= nil then
            local okc, cn = pcall(function() return child:GetClass():GetFName():ToString() end)
            if okc and type(cn) == "string" and cn:find("Image") then
                return child, n
            end
        end
    end
    return nil
end

-- 属性名不一定暴露（UMG 里没勾 IsVariable 的子控件取不到），
-- 所以再按「类名 == Image」把整棵控件树走一遍
local function imageInTree(w)
    local found
    local function walk(node, depth)
        if found ~= nil or node == nil or depth > 4 then return end
        local okc, cn = pcall(function() return node:GetClass():GetFName():ToString() end)
        if not okc then return end
        if cn == "Image" then found = node; return end
        local okk, kids = pcall(function() return node:GetAllChildren() end)
        if okk and type(kids) == "table" then
            for _, k in ipairs(kids) do
                local okNode = pcall(function() return k:GetClass() end)
                if okNode then walk(k, depth + 1) end
            end
        end
    end
    pcall(function()
        local tree = w.WidgetTree
        if tree then walk(tree.RootWidget, 0) end
    end)
    return found
end

-- 把贴图套到图片节点上：两条路都试，失败把原因带出来
local function applySprite(img, tex)
    local ok1, err1 = pcall(function() img:SetBrushFromTexture(tex, true) end)
    if ok1 then return true end
    local ok2, err2 = pcall(function()
        local b = img.Brush
        b.ImageSize = { X = 64, Y = 64 }
        img:SetBrush(b)
    end)
    if ok2 then return true end
    return false, tostring(err1) .. " | " .. tostring(err2)
end

local function nodeClass(obj)
    local ok, cn = pcall(function() return obj:GetClass():GetFName():ToString() end)
    return ok and cn or "?"
end

-- 每个标记控件记住自己的图片子控件（属性名取不到就按类名从树里找）
local function markerImage(w)
    local addr
    pcall(function() addr = w:GetAddress() end)
    if addr ~= nil and M.imgOf[addr] ~= nil then return M.imgOf[addr] end
    local img = imageChild(w) or imageInTree(w)
    if addr ~= nil and img ~= nil then M.imgOf[addr] = img end
    return img
end

local function tryCreate(pc, clsName)
    local cls = FindObject("WidgetBlueprintGeneratedClass", clsName)
    if not valid(cls) then return nil end
    local ok, w = pcall(function()
        return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
    end)
    if ok and valid(w) then return w end
    return nil
end

local function newWidget()
    local pc = getPC()
    if not valid(pc) then return nil end
    local tex = spriteTexture(pc)

    for _, name in ipairs(CFG.widgetCandidates) do
        local w = tryCreate(pc, name)
        if w then
            pcall(function() w:AddToViewport(CFG.widgetZ) end)
            pcall(function() w:SetVisibility(3) end)                   -- HitTestInvisible
            pcall(function() w:SetAlignmentInViewport({ X = 0.5, Y = 0.5 }) end)

            local img = markerImage(w)
            if tex and img then
                local okB, err = applySprite(img, tex)
                if okB then
                    M.useImage = true
                    if not M.imgLogged then
                        M.imgLogged = true
                        log("标记控件 = " .. name .. "｜图片节点 = " .. nodeClass(img))
                    end
                    return w
                end
                log("!! 贴图设置失败(" .. name .. "): " .. tostring(err))
            end

            -- 没图片就试文字；两者都不行就换下一个类
            local okText = pcall(function() w:SetText(FText(CFG.textGlyph)) end)
            if okText then
                M.useImage = false
                if not M.imgLogged then
                    M.imgLogged = true
                    log("标记控件 = " .. name .. "｜文字模式")
                end
                return w
            end
            pcall(function() w:RemoveFromParent() end)
        end
    end

    warnOnce("cls", "没有可用的标记控件类")
    return nil
end

local function ensureWidgets(n)
    while #M.widgets < n do
        local w = newWidget()
        if not w then break end
        M.widgets[#M.widgets + 1] = w
    end
end

local function tint(w, alpha)
    if M.useImage then
        local img = markerImage(w)
        if img then
            pcall(function()
                img:SetColorAndOpacity({ R = CFG.tint.R, G = CFG.tint.G, B = CFG.tint.B, A = 1.0 })
            end)
        end
    end
    pcall(function() w:SetRenderOpacity(alpha) end)
end

-- 让环本身最终显示成 want 像素：优先量图片子控件的尺寸（贴图 64x64），量不到再退回整个控件
-- 让环最终显示成 want 像素：以「控件自身的布局尺寸」为基准（图片会被布局拉满，
-- 用图片的 ImageSize 算会严重偏大），取长边，再乘 sizeScale
local function fit(w, want)
    local size
    local ok, s = pcall(function() return w:GetDesiredSize() end)
    if ok then size = s end
    if size and size.X and size.X > 1 and size.Y and size.Y > 1 then
        if not M.sizeLogged then
            M.sizeLogged = true
            log(string.format("控件布局尺寸 = %.0f x %.0f", size.X, size.Y))
        end
        local base = math.max(size.X, size.Y)
        local k = (want * CFG.sizeScale) / base
        pcall(function() w:SetRenderScale({ X = k, Y = k }) end)
    end
end

local function hide(w)
    pcall(function() w:SetVisibility(1) end)                       -- Collapsed
end

-- 关卡/退出时玩家控制器会先消失：这时把控件全部摘掉，别让它们活到引擎销毁阶段
local function cleanupWidgets()
    for _, w in ipairs(M.widgets) do
        pcall(function() w:RemoveFromParent() end)
    end
    M.widgets = {}
    M.imgOf = {}
    if valid(M.tip) then
        pcall(function() M.tip:RemoveFromParent() end)
    end
    M.tip = nil
    M.tipText = nil
    M.lastTipText = nil
end

-- ------------------------------------------------------------------ 屏幕反馈

-- 复用游戏自带的墨条提示（PBZCoop 的 status.lua 用的同一个），按 F8 时在屏幕上回一行数
local TIP_CLASS = "/Game/PBZContent/UI/InGame/SwitchUI/WB_TipsText.WB_TipsText_C"

-- 控件树的子节点：GetAllChildren 在部分容器上返回不了东西，
-- 改用面板自己的 GetChildrenCount / GetChildAt，再补一个 GetContent（单子控件容器）
local function childrenOf(node)
    local out = {}
    local okc, cnt = pcall(function() return node:GetChildrenCount() end)
    if okc and type(cnt) == "number" and cnt >= 0 then
        for i = 0, cnt - 1 do
            local okg, ch = pcall(function() return node:GetChildAt(i) end)
            if okg and ch ~= nil then out[#out + 1] = unwrap(ch) end
        end
    end
    if #out == 0 then
        -- GetAllChildren 返回的是 TObjectPtr 包装，要 unwrap 才是对象
        local okk, kids = pcall(function() return node:GetAllChildren() end)
        if okk and type(kids) == "table" then
            for _, k in ipairs(kids) do
                local c = unwrap(k)
                if c ~= nil then out[#out + 1] = c end
            end
        end
    end
    local ok1, c1 = pcall(function() return node:GetContent() end)
    if ok1 and c1 ~= nil then out[#out + 1] = unwrap(c1) end
    return out
end

-- 直接找内部的文本控件：绕过提示条蓝图的 SetText，就不会触发它的音效/淡入
local function findTextBlock(w)
    local found, foundClass
    local function walk(node, depth)
        if found ~= nil or node == nil or depth > 6 then return end
        local okc, cn = pcall(function() return node:GetClass():GetFName():ToString() end)
        if not okc then return end
        if type(cn) == "string" and cn:find("Text") and cn ~= "TextLayoutWidget" then
            found, foundClass = node, cn
            return
        end
        for _, ch in ipairs(childrenOf(node)) do walk(ch, depth + 1) end
    end
    pcall(function()
        local tree = w.WidgetTree
        if tree then walk(tree.RootWidget, 0) end
    end)
    if found then log("找到文本控件: " .. tostring(foundClass)) end
    return found
end

-- 换图会把提示条从视口里摘掉，但对象本身仍然 valid——所以要单独检查"还在不在屏幕上"
local function tipAlive(w)
    if not valid(w) then return false end
    local ok, inv = pcall(function() return w:IsInViewport() end)
    return ok and inv == true
end

local function ensureTip()
    if valid(M.tip) then
        if tipAlive(M.tip) then return M.tip end
        pcall(function() M.tip:RemoveFromParent() end)
        M.tip, M.tipText = nil, nil
        log("提示条已离开视口（换图），重建")
    end
    local pc = getPC()
    if not valid(pc) then return nil end
    local cls = FindObject("WidgetBlueprintGeneratedClass", "WB_TipsText_C")
    if not valid(cls) then cls = StaticFindObject(TIP_CLASS) end
    if not valid(cls) and type(LoadAsset) == "function" then
        pcall(LoadAsset, TIP_CLASS)
        cls = StaticFindObject(TIP_CLASS)
    end
    if not valid(cls) then
        warnOnce("tipcls", "找不到 WB_TipsText_C，屏幕反馈关闭")
        return nil
    end
    local ok, w = pcall(function()
        return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
    end)
    if not (ok and valid(w)) then
        warnOnce("tipmake", "提示条创建失败：" .. tostring(w))
        return nil
    end
    pcall(function() w:AddToViewport(400) end)
    pcall(function() w:SetVisibility(3) end)
    M.tip = w
    M.tipText = findTextBlock(w)
    if M.tipText then
        log("提示条内部文本控件: 已找到（直接写文本，不触发音效）")
    else
        log("提示条内部文本控件: 没找到（退回控件自身 SetText，会有音效）")
        pcall(function()
            local names = {}
            local root = w.WidgetTree and w.WidgetTree.RootWidget
            if root then
                local okc, cn = pcall(function() return root:GetClass():GetFName():ToString() end)
                names[#names + 1] = "root:" .. tostring(cn)
                for _, ch in ipairs(childrenOf(root)) do
                    local ok2, cn2 = pcall(function() return ch:GetClass():GetFName():ToString() end)
                    names[#names + 1] = tostring(cn2)
                end
            end
            log("提示条结构(前两层): " .. (#names > 0 and table.concat(names, ", ") or "空"))
        end)
    end
    return w
end

local function showTip(text, animate)
    local w = ensureTip()
    if not valid(w) then return end

    -- 首选：直接写内部 TextBlock，绕过提示条的显示逻辑（音效/淡入都在那里）
    if valid(M.tipText) then
        local okv, vis = pcall(function() return w:GetVisibility() end)
        if not (okv and vis == 3) then
            pcall(function() w:SetVisibility(3) end)
        end
        pcall(function() M.tipText:SetText(FText(text)) end)
        return
    end

    -- 只在不可见时才动 visibility：反复 SetVisibility 也可能触发它的显示动画
    local okv, vis = pcall(function() return w:GetVisibility() end)
    if not (okv and vis == 3) then
        pcall(function() w:SetVisibility(3) end)
    end
    pcall(function() w:SetText(FText(text)) end)
    if animate then
        pcall(function() w:PlayAnimation(w.FadeIn, 0, 1, 0, 1, false) end)
    end
end

-- 距离按 5 m 取整：走两步就换一次字，屏上就一直在跳
local function bearingText(from, to, yawDeg)
    if not (from and to) then return "" end
    local ang = math.deg(math.atan(to.Y - from.Y, to.X - from.X))
    local rel = (ang - (yawDeg or 0) + 540) % 360 - 180
    local dirs = { "前", "右前", "右", "右后", "后", "左后", "左", "左前" }
    local idx = math.floor(((rel + 22.5) % 360) / 45) + 1
    return dirs[idx] or ""
end

local function tipText()
    local near = M.diag.nearest
    local nearTxt = "—"
    if near and near < 1e9 then
        local m = math.floor(near / 500 + 0.5) * 5
        nearTxt = string.format("%dm·%s", m, bearingText(M.diag.meLoc, M.diag.nearestLoc, M.diag.camYaw))
    end
    return string.format("标记 | 敌 %d · %dm内 %d · 待标 %d · 最近 %s · %s",
        M.diag.enemies, math.floor(CFG.maxDistCm / 100), M.diag.inRange, #M.targets, nearTxt,
        M.inCombat and "战斗中" or "潜行")
end

local function updateTip(animate)
    showTip(tipText(), animate)
end

-- ------------------------------------------------------------------ 画布通道

-- 如果 PBZ 的 HUD 是 AHUD 子类，DrawHUD 每帧会回调到这里：
-- 这条路径不依赖控件、不依赖贴图，直接用 K2_DrawLine 画环。
local function canvasRing(canvas, cx, cy, radius, alpha)
    local color = { R = CFG.tint.R, G = CFG.tint.G, B = CFG.tint.B, A = alpha }
    local thick = math.max(1.0, radius * 0.11)
    local seg = 14
    local prev = nil
    for i = 0, seg do
        local a = (i / seg) * math.pi * 2
        local p = { X = cx + math.cos(a) * radius, Y = cy + math.sin(a) * radius }
        if prev ~= nil then canvas:K2_DrawLine(prev, p, thick, color) end
        prev = p
    end
end

-- 只做绘制，不投影、不查对象：坐标由 draw() 在定时器里备好
local function drawCanvas(hud)
    if M.inDraw or #M.screen == 0 then return end
    local canvas = hud.Canvas
    if not valid(canvas) then return end
    M.inDraw = true
    for i = 1, #M.screen do
        local s = M.screen[i]
        pcall(canvasRing, canvas, s.x, s.y, math.max(5, s.size * 0.55), CFG.alpha)
    end
    M.inDraw = false
end

local function bindCanvas()
    local ok = pcall(function()
        RegisterHook("/Script/Engine.HUD:ReceiveDrawHUD", function(hud, sizeX, sizeY)
            M.canvas.hud = hud
            M.canvas.w, M.canvas.h = sizeX, sizeY
            local pok, err = pcall(drawCanvas, hud)
            if not pok then warnOnce("canvas", "画布绘制出错：" .. tostring(err)) end
        end)
    end)
    log("HUD 画布钩子: " .. (ok and "已注册" or "注册失败"))
end

bindCanvas()

-- ------------------------------------------------------------------ 判定（10 Hz）

local function refresh()
    M.diag.enemies, M.diag.traced, M.diag.blocked, M.diag.marked = 0, 0, 0, 0
    M.diag.inRange, M.diag.dead, M.diag.hate, M.diag.nearest = 0, 0, 0, math.huge
    M.targets = {}

    local pc = getPC()
    if not valid(pc) then
        M.missPC = (M.missPC or 0) + 1
        if M.missPC == 20 then                       -- 约 2 秒没有 PC：换图或退出
            cleanupWidgets()
        end
        return
    end
    M.missPC = 0
    local pawn = pc.Pawn
    if not valid(pawn) then return end

    local cam = pc.PlayerCameraManager
    if not valid(cam) then return end
    local camLoc = cam:GetCameraLocation()

    local here = pawn:K2_GetActorLocation()
    M.diag.meLoc = here
    M.diag.nearestLoc = nil
    M.diag.camYaw = 0
    pcall(function() M.diag.camYaw = cam:GetCameraRotation().Yaw end)

    local all = listEnemies()
    M.diag.enemies = #all

    -- 战斗判定兜底：任何敌人恨你 = 已经在打
    local anyHate = false

    for _, e in ipairs(all) do
        local ok, eLoc = pcall(function() return e:K2_GetActorLocation() end)
        if ok and eLoc and eLoc.X then
            local d = distCm(here, eLoc)
            if d < M.diag.nearest then
                M.diag.nearest = d
                M.diag.nearestLoc = eLoc
            end
            if d <= CFG.maxDistCm then M.diag.inRange = M.diag.inRange + 1 end

            local hating = hatesPlayer(e, pawn)
            if hating then
                anyHate = true
                M.diag.hate = M.diag.hate + 1
            end

            local dead = isDead(e)
            if dead then M.diag.dead = M.diag.dead + 1 end

            local eligible = (d <= CFG.maxDistCm) and (not dead) and (not hating)
            if eligible then
                local goal = { X = eLoc.X, Y = eLoc.Y, Z = eLoc.Z + CFG.heightCm }
                local blocked = false
                if CFG.onlyOccluded then
                    M.diag.traced = M.diag.traced + 1
                    blocked = blockedByGeometry(pawn, camLoc, goal, e)
                    if blocked then M.diag.blocked = M.diag.blocked + 1 end
                end
                if blocked or not CFG.onlyOccluded then
                    M.targets[#M.targets + 1] = { actor = e, world = goal, dist = d }
                end
            end
        end
    end

    if anyHate and not M.inCombat then
        -- 有人恨你但标签没来：按战斗处理，别让"轻微"变成误导
        M.inCombat = true
        M.combatFromHate = true
    elseif not anyHate and M.combatFromHate then
        M.inCombat = false
        M.combatFromHate = false
    end
end

-- ------------------------------------------------------------------ 绘制（跟帧）

local function draw()
    M.diag.marked = 0
    M.diag.projOk = 0

    -- 底部数值：只有文字真的变了才重设（每帧 SetText 会让提示条反复重播淡入动画 = 闪烁）
    if M.live and os.clock() >= M.nextTip then
        M.nextTip = os.clock() + 1.0
        local t = tipText()
        if t ~= M.lastTipText or not tipAlive(M.tip) then
            M.lastTipText = t
            if CFG.readoutMode == "log" then
                log("读数: " .. t)
            else
                showTip(t, false)
            end
        end
    end

    M.screen = {}

    if not M.on or (CFG.hideInCombat and M.inCombat) then
        for _, w in ipairs(M.widgets) do hide(w) end
        return
    end

    local testing = M.testUntil ~= nil and os.clock() < M.testUntil
    if #M.targets == 0 and not testing then
        for _, w in ipairs(M.widgets) do hide(w) end
        return
    end

    local pc = getPC()
    if not valid(pc) then return end

    -- 1) 先把屏幕坐标算好：投影只在这里调用，HUD 回调里绝不做好耗时的事
    if testing and #M.targets == 0 then
        local vw, vh = viewportSize(pc)
        if vw > 0 then
            M.screen[1] = { x = vw / 2, y = vh / 2, size = CFG.sizeMaxPx }
        end
    else
        for i = 1, math.min(#M.targets, CFG.maxMarkers) do
            local t = M.targets[i]
            local sx, sy = project(pc, t.world)
            if sx and sy then
                local size = math.max(CFG.sizeMinPx,
                             math.min(CFG.sizeMaxPx, (9 + 9000 / (t.dist + 600)) * CFG.sizeGain))
                M.screen[#M.screen + 1] = { x = sx, y = sy, size = size }
                M.diag.projOk = M.diag.projOk + 1
            end
        end
    end

    -- 2) 画布通道：坐标已备好，绘制交给 HUD 回调
    if M.canvas.hud ~= nil then
        for _, w in ipairs(M.widgets) do hide(w) end
        return
    end

    -- 3) 控件通道（备用）：像素坐标换成 DPI 单位
    local scale = 1.0
    pcall(function()
        local s = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"):GetViewportScale(pc)
        if type(s) == "number" and s > 0 then scale = s end
    end)

    local pulse = 1.0
    if CFG.alphaPulse > 0 then
        pulse = 1.0 + CFG.alphaPulse * math.sin((os.clock() % CFG.pulsePeriodS) / CFG.pulsePeriodS * math.pi * 2)
    end

    ensureWidgets(#M.screen)

    for i = 1, #M.screen do
        local s = M.screen[i]
        local w = M.widgets[i]
        if valid(w) then
            local ok, inView = pcall(function() return w:IsInViewport() end)
            if ok and inView ~= true then
                hide(w)
                M.widgets = {}                 -- 换图 / 重生会让控件掉出视口：整池重建
                return
            end
            pcall(function() w:SetPositionInViewport({ X = s.x / scale, Y = s.y / scale }, false) end)
            fit(w, s.size)
            tint(w, math.min(1.0, CFG.alpha * pulse))
            pcall(function() w:SetVisibility(3) end)
            M.diag.marked = M.diag.marked + 1
        end
    end

    for i = #M.screen + 1, #M.widgets do
        hide(M.widgets[i])
    end
end

-- ------------------------------------------------------------------ 热键

pcall(function()
    RegisterKeyBind(Key.F7, function()
        M.on = not M.on
        log("标记 " .. (M.on and "开" or "关"))
        if not M.on then
            for _, w in ipairs(M.widgets) do hide(w) end
        end
    end)
end)

pcall(function()
    RegisterKeyBind(Key.F8, function()
        local pc = getPC()
        local camLoc, camRot = "?", "?"
        pcall(function()
            local cam = pc.PlayerCameraManager
            local l = cam:GetCameraLocation()
            local r = cam:GetCameraRotation()
            camLoc = string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z)
            camRot = string.format("%.0f/%.0f", r.Yaw, r.Pitch)
        end)
        log("--- 诊断 ---")
        log(string.format("开关=%s 战斗=%s 敌人=%d 25m内=%d 死亡=%d 仇恨=%d 射线=%d 被挡=%d 待标=%d 投影=%d 控件=%d",
            tostring(M.on), tostring(M.inCombat), M.diag.enemies, M.diag.inRange,
            M.diag.dead, M.diag.hate, M.diag.traced, M.diag.blocked, #M.targets,
            M.diag.projOk, #M.widgets))
        log("相机 位置=" .. camLoc .. " 朝向=" .. camRot .. " 射线通道=" .. tostring(CFG.traceChannel))
        log("画布=" .. (M.canvas.hud ~= nil and "on" or "off")
            .. " 贴图=" .. (M.sprite and "ok" or "缺")
            .. " 投影模式=" .. tostring(M.diag.projMode))

        -- 投影自检：相机正前方 500 cm 的点，能不能换算出屏幕坐标
        pcall(function()
            local cam = pc.PlayerCameraManager
            local l = cam:GetCameraLocation()
            local r = cam:GetCameraRotation()
            local yaw, pitch = math.rad(r.Yaw), math.rad(r.Pitch)
            local probe = {
                X = l.X + math.cos(pitch) * math.cos(yaw) * 500,
                Y = l.Y + math.cos(pitch) * math.sin(yaw) * 500,
                Z = l.Z + math.sin(pitch) * 500,
            }
            local sx, sy = project(pc, probe)
            log("投影自检: " .. (sx and string.format("ok (%.0f,%.0f)", sx, sy) or "nil"))
        end)

        -- 屏幕上现有的 UMG 实例 → 全部类名（分段打，避免一行太长被截）
        pcall(function()
            local all = FindAllOf("UserWidget") or {}
            local seen, out = {}, {}
            for _, u in ipairs(all) do
                local okn, n = pcall(function() return u:GetClass():GetFName():ToString() end)
                if okn and n and not seen[n] then
                    seen[n] = true
                    out[#out + 1] = n
                end
            end
            log("UMG 实例=" .. tostring(#all) .. " 类数=" .. #out)
            for i = 1, #out, 30 do
                local chunk = {}
                for j = i, math.min(i + 29, #out) do chunk[#chunk + 1] = out[j] end
                log("  " .. table.concat(chunk, ", "))
            end
        end)

        -- 候选探测已经得出结论（只有 wb_damageindicator_C 带 Image），
        -- 这里不再每次 F8 都创建/销毁一堆 UI 实例——那会触发它们自己的蓝图逻辑。

        -- 标记控件里到底有哪些子节点（找被漏掉的图片控件）
        pcall(function()
            local w = M.widgets[1]
            if not valid(w) then return end
            local names = {}
            local function walk(node, depth)
                if node == nil or depth > 3 then return end
                local okc, cn = pcall(function() return node:GetClass():GetFName():ToString() end)
                if not okc then return end
                local okn, fn = pcall(function() return node:GetFName():ToString() end)
                names[#names + 1] = tostring(fn) .. ":" .. tostring(cn)
                local okk, kids = pcall(function() return node:GetAllChildren() end)
                if okk and type(kids) == "table" then
                    for _, k in ipairs(kids) do
                        local okNode = pcall(function() return k:GetClass() end)
                        if okNode then walk(k, depth + 1) end
                    end
                end
            end
            local tree = w.WidgetTree
            if tree then walk(tree.RootWidget, 0) end
            log("标记控件子节点: " .. (#names > 0 and table.concat(names, ", ") or "取不到"))
        end)

        -- 强制试一次贴图导入，并把结果回报到屏幕上（否则要切窗口看日志）
        spriteTexture(pc)
        M.live = not M.live
        M.nextTip = 0
        M.lastTipText = nil
        if M.live then
            showTip(tipText(), true)
            M.lastTipText = tipText()
            M.testUntil = os.clock() + 8.0
            log("底部读数: 开（只在该变的时候刷新）")
        else
            log("底部读数: 关")
        end
        for i, t in ipairs(M.targets) do
            if i > CFG.maxMarkers then break end
            log(string.format("  #%d %s  %.1f m", i, classOf(t.actor), t.dist / 100))
        end
    end)
end)

-- ------------------------------------------------------------------ 主循环

LoopAsync(CFG.tickMs, function()
    local ok, err = pcall(refresh)
    if not ok then warnOnce("refresh", "refresh 出错：" .. tostring(err)) end
    return false
end)

LoopAsync(CFG.drawMs, function()
    local ok, err = pcall(draw)
    if not ok then warnOnce("draw", "draw 出错：" .. tostring(err)) end
    return false
end)

log(string.format("v%s 已载入（F7 开关 / F8 诊断）", VERSION))
