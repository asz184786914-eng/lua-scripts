-- ============================================================
-- ╔══════════════════════════════════════════════╗
-- ║   Unity Time.timeScale 加速器 v4.4          ║
-- ║   全量分批评分 + 二分法 + GG保存列表          ║
-- ║   Unity引擎精准检测                          ║
-- ║   署名: xy435116694754                      ║
-- ╚══════════════════════════════════════════════╝
-- ============================================================

local speedAddr = nil
local currentSpeed = 1.0
local candidates = {}
local isUnityGame = nil  -- nil=未检测, true=Unity, false=非Unity
local SAVE_TAG = "⚡TimeScale"
local APP_NAME = "Unity加速器"
local APP_VER = "v4.4"
local AUTHOR = "xy435116694754"

-- Unity Time经典组合（+4偏移值, +8偏移值）
local CLASSIC_COMBOS = {
    {0.1, 0.03},       -- 地平线行者
    {0.1, 0.04},       -- 地平线变体
    {0.333, 0.1},      -- 女神异闻录
    {0.333, 0.06},     -- 进击的恶魔团
    {0.333, 0.15},
    {0.333, 0.03},
    {0.02, 0.1},
    {0.02, 0.333},
    {0.033, 0.333},
    {0.03, 0.1},
    {0.05, 0.1},
    {0.05, 0.333},
    {0.0167, 0.1},     -- 60fps
    {0.0167, 0.333},   -- 60fps
}

-- ============ Unity引擎精准检测 ============
-- 检测原理：Unity游戏必定在内存中包含特定的特征字符串
-- 使用多特征交叉验证，避免误判（广告SDK也可能包含"Unity"）
--
-- 特征层级：
--   🔴 核心特征（单独命中即可确认Unity）：
--     - libunity.so      : Unity引擎核心库，只有Unity游戏加载
--     - UnityEngine.Time : Unity命名空间+类名，非常独特
--
--   🟡 辅助特征（需要2个以上命中）：
--     - Time.timeScale        : Unity Time类独有属性
--     - Time.fixedDeltaTime   : Unity Time类独有属性
--     - Time.maximumDeltaTime : Unity Time类独有属性
--     - UnityEngine           : Unity命名空间（短，可能误匹配）
--
-- 判定规则：
--   命中1个核心特征 → ✅ Unity
--   命中2个以上辅助特征 → ✅ Unity
--   命中1个辅助特征 → ❌ 非Unity（不够确信）
--   无命中 → ❌ 非Unity

function detectUnity()
    local pkg = gg.getSelectedPackage()
    if not pkg then return false, "未选中进程" end

    local coreHits = {}     -- 核心特征命中
    local auxHits = {}      -- 辅助特征命中
    local foundIL2CPP = false

    -- ====== 检测1: libunity.so（核心） ======
    -- 6C 69 62 75 6E 69 74 79 2E 73 6F
    gg.clearResults()
    local ok1 = pcall(function()
        gg.searchNumber("h 6C 69 62 75 6E 69 74 79 2E 73 6F", gg.TYPE_BYTE)
    end)
    if ok1 then
        local cnt = gg.getResultsCount()
        if cnt > 0 then
            coreHits[#coreHits + 1] = "✅ libunity.so (" .. cnt .. "处)"
        end
    end

    -- ====== 检测2: UnityEngine.Time（核心） ======
    -- 55 6E 69 74 79 45 6E 67 69 6E 65 2E 54 69 6D 65
    gg.clearResults()
    local ok2 = pcall(function()
        gg.searchNumber("h 55 6E 69 74 79 45 6E 67 69 6E 65 2E 54 69 6D 65", gg.TYPE_BYTE)
    end)
    if ok2 then
        local cnt = gg.getResultsCount()
        if cnt > 0 then
            coreHits[#coreHits + 1] = "✅ UnityEngine.Time (" .. cnt .. "处)"
        end
    end

    -- ====== 检测3: Time.timeScale（辅助） ======
    -- 54 69 6D 65 2E 74 69 6D 65 53 63 61 6C 65
    gg.clearResults()
    local ok3 = pcall(function()
        gg.searchNumber("h 54 69 6D 65 2E 74 69 6D 65 53 63 61 6C 65", gg.TYPE_BYTE)
    end)
    if ok3 then
        local cnt = gg.getResultsCount()
        if cnt > 0 then
            auxHits[#auxHits + 1] = "✅ Time.timeScale (" .. cnt .. "处)"
        end
    end

    -- ====== 检测4: Time.fixedDeltaTime（辅助） ======
    -- 54 69 6D 65 2E 66 69 78 65 64 44 65 6C 74 61 54 69 6D 65
    gg.clearResults()
    local ok4 = pcall(function()
        gg.searchNumber("h 54 69 6D 65 2E 66 69 78 65 64 44 65 6C 74 61 54 69 6D 65", gg.TYPE_BYTE)
    end)
    if ok4 then
        local cnt = gg.getResultsCount()
        if cnt > 0 then
            auxHits[#auxHits + 1] = "✅ Time.fixedDeltaTime (" .. cnt .. "处)"
        end
    end

    -- ====== 检测5: Time.maximumDeltaTime（辅助） ======
    -- 54 69 6D 65 2E 6D 61 78 69 6D 75 6D 44 65 6C 74 61 54 69 6D 65
    gg.clearResults()
    local ok5 = pcall(function()
        gg.searchNumber("h 54 69 6D 65 2E 6D 61 78 69 6D 75 6D 44 65 6C 74 61 54 69 6D 65", gg.TYPE_BYTE)
    end)
    if ok5 then
        local cnt = gg.getResultsCount()
        if cnt > 0 then
            auxHits[#auxHits + 1] = "✅ Time.maximumDeltaTime (" .. cnt .. "处)"
        end
    end

    -- ====== 检测6: UnityEngine（辅助，短字符串可能误匹配） ======
    -- 55 6E 69 74 79 45 6E 67 69 6E 65
    gg.clearResults()
    local ok6 = pcall(function()
        gg.searchNumber("h 55 6E 69 74 79 45 6E 67 69 6E 65", gg.TYPE_BYTE)
    end)
    if ok6 then
        local cnt = gg.getResultsCount()
        if cnt > 0 then
            auxHits[#auxHits + 1] = "✅ UnityEngine (" .. cnt .. "处)"
        end
    end

    -- ====== 附加检测: libil2cpp.so（IL2CPP编译标识） ======
    gg.clearResults()
    local okIl2 = pcall(function()
        gg.searchNumber("h 6C 69 62 69 6C 32 63 70 70 2E 73 6F", gg.TYPE_BYTE)
    end)
    if okIl2 then
        local cnt = gg.getResultsCount()
        if cnt > 0 then
            foundIL2CPP = true
        end
    end

    -- 清理搜索结果
    gg.clearResults()

    -- ====== 判定逻辑 ======
    local isUnity = false
    local confidence = ""

    if #coreHits >= 1 then
        isUnity = true
        confidence = "🔴 核心特征命中，高可信度"
    elseif #auxHits >= 2 then
        isUnity = true
        confidence = "🟡 辅助特征多重命中，中可信度"
    else
        confidence = "⚪ 特征不足，判定为非Unity"
    end

    -- 构建检测报告
    local report = "━━━ 引擎检测 ━━━\n\n"
    report = report .. "📦 包名: " .. pkg .. "\n"
    report = report .. "🎯 可信度: " .. confidence .. "\n\n"

    if isUnity then
        report = report .. "🎮 引擎: ✅ Unity\n\n"
    else
        report = report .. "🎮 引擎: ❌ 非Unity\n\n"
    end

    report = report .. "━━━ 核心特征 ━━━\n"
    if #coreHits > 0 then
        for i = 1, #coreHits do
            report = report .. coreHits[i] .. "\n"
        end
    else
        report = report .. "❌ 无命中\n"
    end

    report = report .. "\n━━━ 辅助特征 ━━━\n"
    if #auxHits > 0 then
        for i = 1, #auxHits do
            report = report .. auxHits[i] .. "\n"
        end
    else
        report = report .. "❌ 无命中\n"
    end

    if isUnity then
        if foundIL2CPP then
            report = report .. "\n🔧 编译方式: IL2CPP"
        else
            report = report .. "\n🔧 编译方式: Mono / 未检测到IL2CPP"
        end
    else
        report = report .. "\n\n⚠️ timeScale加速仅适用于Unity游戏\n仍可尝试搜索，但可能无法找到"
    end

    return isUnity, report, foundIL2CPP
end

-- ============ 启动欢迎 ============
function showWelcome()
    gg.alert(
        "━━━━━━━━━━━━━━━━━━━━━\n" ..
        "  ⚡ " .. APP_NAME .. " " .. APP_VER .. "\n" ..
        "━━━━━━━━━━━━━━━━━━━━━\n\n" ..
        "  Unity游戏加速专用工具\n" ..
        "  精准检测Unity引擎\n" ..
        "  自动搜索 timeScale 地址\n" ..
        "  二分法精准确认\n" ..
        "  结果保存到GG列表\n\n" ..
        "━━━━━━━━━━━━━━━━━━━━━\n" ..
        "  闲鱼: " .. AUTHOR .. "\n" ..
        "━━━━━━━━━━━━━━━━━━━━━"
    )
end

-- ============ 主菜单 ============
function showMenu()
    while true do
        local title
        local items
        local engineLabel = isUnityGame == true and " ✅Unity" or (isUnityGame == false and " ❌非Unity" or " ❓未检测")

        if speedAddr then
            title = APP_NAME .. " " .. APP_VER .. engineLabel .. "  🎯 " .. string.format("0x%X", speedAddr) .. " | " .. currentSpeed .. "x"
            items = {
                "⚡  加速倍率  【" .. currentSpeed .. "x】",
                "⏩  快捷加速  →  2x / 3x / 5x / 10x",
                "⏪  快捷减速  →  0.5x / 0.25x",
                "🔄  恢复正常  →  1.0x",
                "━━━━━━━━━━━━━━━━━",
                "🔍  重新搜索 timeScale",
                "🔍  检测Unity引擎",
                "💾  保存列表管理",
                "📋  关于 / 署名",
                "❌  退出脚本"
            }
        else
            title = APP_NAME .. " " .. APP_VER .. engineLabel .. "  🔍 未锁定"
            items = {
                "🔍  搜索 timeScale",
                "🔍  检测Unity引擎",
                "💾  从GG保存列表加载",
                "📋  关于 / 署名",
                "❌  退出脚本"
            }
        end

        local choice = gg.choice(items, nil, title)
        if not choice then return end

        if not speedAddr then
            if choice == 1 then searchAndTest()
            elseif choice == 2 then runUnityDetect()
            elseif choice == 3 then loadFromSaveListMenu()
            elseif choice == 4 then showAbout()
            elseif choice == 5 then return end
        else
            if choice == 1 then setSpeedDialog()
            elseif choice == 2 then quickSpeedUp()
            elseif choice == 3 then quickSlowDown()
            elseif choice == 4 then resetSpeed()
            elseif choice == 5 then -- 分隔线
            elseif choice == 6 then resetSpeed(); speedAddr = nil; searchAndTest()
            elseif choice == 7 then runUnityDetect()
            elseif choice == 8 then showSaveListInfo()
            elseif choice == 9 then showAbout()
            elseif choice == 10 then return end
        end
    end
end

-- ============ 运行Unity检测 ============
function runUnityDetect()
    local pkg = gg.getSelectedPackage()
    if not pkg then
        gg.alert("⚠️ 请先选择游戏进程")
        return
    end

    gg.toast("🔍 正在检测Unity引擎...")
    local isUnity, report = detectUnity()
    isUnityGame = isUnity
    gg.alert(report)
end

-- ============ 搜索主流程 ============
function searchAndTest()
    local pkg = gg.getSelectedPackage()
    if not pkg then
        gg.alert(
            "⚠️ 未选中游戏进程\n\n" ..
            "请先点击GG悬浮窗\n左上角图标选择游戏"
        )
        return
    end

    -- 搜索前自动检测Unity
    if isUnityGame == nil then
        gg.toast("🔍 自动检测Unity引擎...")
        local isUnity = detectUnity()
        isUnityGame = isUnity
        if not isUnity then
            local choice = gg.choice(
                {"⚠️  仍然继续搜索", "🔙  返回"},
                nil,
                "⚠️ 检测结果: 非Unity引擎\n\n" ..
                "此游戏可能不是Unity\n" ..
                "timeScale加速仅适用于Unity游戏\n\n" ..
                "仍然尝试搜索？"
            )
            if choice ~= 1 then return end
        end
    elseif isUnityGame == false then
        local choice = gg.choice(
            {"⚠️  仍然继续搜索", "🔙  返回"},
            nil,
            "⚠️ 已知: 非Unity引擎\n\n" ..
            "timeScale加速仅适用于Unity游戏\n\n" ..
            "仍然尝试搜索？"
        )
        if choice ~= 1 then return end
    end

    candidates = {}

    gg.toast("🔍 开始搜索 timeScale ...")
    gg.clearResults()
    gg.searchNumber("1.0", gg.TYPE_FLOAT)
    local count = gg.getResultsCount()

    if count == 0 then
        gg.alert(
            "❌ 未找到 float 1.0\n\n" ..
            "请确认：\n" ..
            "① 游戏正在运行\n" ..
            "② GG已选中游戏进程\n" ..
            "③ 内存区域全选后再运行"
        )
        return
    end

    gg.toast("📊 找到 " .. count .. " 个 1.0f，开始评分...")

    -- 可选保留数量
    local keepInput = gg.prompt(
        {"保留得分前N个候选"},
        {"1000"},
        {"number"}
    )
    local KEEP = keepInput and tonumber(keepInput[1]) or 1000
    if KEEP < 10 then KEEP = 10 end

    -- 分批处理所有结果
    local BATCH = 8000
    local offset = 0

    while offset < count do
        local batchCount = math.min(BATCH, count - offset)
        local results = gg.getResults(batchCount, offset)

        -- 批量读取+4和+8
        local readList = {}
        for i = 1, #results do
            readList[#readList + 1] = {address = results[i].address + 4, flags = gg.TYPE_FLOAT}
            readList[#readList + 1] = {address = results[i].address + 8, flags = gg.TYPE_FLOAT}
        end
        local vals = gg.getValues(readList)

        for i = 1, #results do
            local val2 = vals[(i - 1) * 2 + 1].value
            local val3 = vals[(i - 1) * 2 + 2].value
            local score = calcScore(val2, val3)
            candidates[#candidates + 1] = {
                address = results[i].address,
                score = score,
                val2 = val2,
                val3 = val3
            }
        end

        offset = offset + batchCount
        gg.toast("📊 评分: " .. math.min(offset, count) .. "/" .. count)
    end

    -- 按得分排序
    table.sort(candidates, function(a, b) return a.score > b.score end)

    -- 只保留前KEEP个
    if #candidates > KEEP then
        local trimmed = {}
        for i = 1, KEEP do trimmed[i] = candidates[i] end
        candidates = trimmed
    end

    -- 显示结果
    local info = "━━━ 评分完成 ━━━\n\n" ..
        "📦 搜到 " .. count .. " 个 1.0f\n" ..
        "🎯 " .. #candidates .. " 个候选（前" .. KEEP .. "）\n" ..
        "🏆 最高分: " .. (candidates[1] and candidates[1].score or 0)

    if #candidates > 0 then
        info = info .. "\n\n🏅 TOP3:\n"
        for i = 1, math.min(3, #candidates) do
            info = info .. string.format(
                "  #%d  ⭐%d  +4=%.4f  +8=%.4f\n",
                i, candidates[i].score, candidates[i].val2, candidates[i].val3
            )
        end
    end
    info = info .. "\n即将使用二分法确认 ⚡"
    gg.alert(info)

    binarySearch()
end

-- ============ 评分函数 ============
function calcScore(val2, val3)
    local score = 0

    if isGoodFloat(val2) then
        score = score + 50
        if near(val2, 0.333333) then score = score + 40 end
        if near(val2, 0.033333) then score = score + 40 end
        if near(val2, 0.02) then score = score + 35 end
        if near(val2, 0.016666) or near(val2, 0.0167) then score = score + 35 end
        if near(val2, 0.011111) then score = score + 30 end
        if near(val2, 0.1) then score = score + 30 end
        if near(val2, 0.05) then score = score + 20 end
        if near(val2, 0.03) then score = score + 35 end
        if val2 > 0 and val2 < 0.5 then score = score + 15 end
        if val2 > 0.5 and val2 < 1.0 then score = score + 5 end
        if val2 >= 5.0 then score = score - 30 end
        if val2 >= 10.0 then score = score - 40 end
    else
        score = -100
    end

    if isGoodFloat(val3) then
        score = score + 20
        if near(val3, 0.1) then score = score + 30 end
        if near(val3, 0.333333) then score = score + 25 end
        if near(val3, 0.05) then score = score + 20 end
        if near(val3, 0.033333) then score = score + 15 end
        if near(val3, 0.03) then score = score + 25 end
        if near(val3, 0.02) then score = score + 20 end
        if val3 > 0 and val3 < 0.5 then score = score + 10 end
        if val3 >= 5.0 then score = score - 20 end
    else
        score = score - 30
    end

    -- 经典组合加分
    if isGoodFloat(val2) and isGoodFloat(val3) then
        for _, c in ipairs(CLASSIC_COMBOS) do
            if near(val2, c[1]) and near(val3, c[2]) then
                score = score + 50
                break
            end
        end
    end

    return score
end

-- ============ 二分法 ============
function binarySearch()
    if #candidates == 0 then
        gg.alert("❌ 没有候选地址")
        return
    end

    local lo = 1
    local hi = #candidates

    while lo < hi do
        local mid = math.floor((lo + hi) / 2)

        local modifyList = {}
        for i = lo, mid do
            modifyList[#modifyList + 1] = {address = candidates[i].address, flags = gg.TYPE_FLOAT, value = 5.0}
        end
        gg.setValues(modifyList)

        local choice = gg.choice(
            {"✅  速度变了！在这组", "❌  没变化，另一组"},
            nil,
            "⚡ 二分法测试\n\n" ..
            "🔴 测试: #" .. lo .. " ~ #" .. mid .. " (" .. (mid - lo + 1) .. "个)\n" ..
            "⚪ 剩余: #" .. (mid + 1) .. " ~ #" .. hi .. "\n\n" ..
            "已将前半组改为 5.0x\n游戏速度变了吗？"
        )

        local restoreList = {}
        for i = lo, mid do
            restoreList[#restoreList + 1] = {address = candidates[i].address, flags = gg.TYPE_FLOAT, value = 1.0}
        end
        gg.setValues(restoreList)

        if choice == 1 then
            hi = mid
        elseif choice == 2 then
            lo = mid + 1
        else
            return
        end

        if hi - lo < 5 then
            testOneByOne(lo, hi)
            return
        end
    end

    testSingle(lo)
end

-- ============ 逐个测试 ============
function testOneByOne(lo, hi)
    for i = lo, hi do
        gg.setValues({{address = candidates[i].address, flags = gg.TYPE_FLOAT, value = 5.0}})
        local c = gg.choice(
            {"✅  就是它！", "❌  不是，下一个", "🔙  退出测试"},
            nil,
            "🎯 逐个确认 " .. (i - lo + 1) .. "/" .. (hi - lo + 1) ..
            "\n\n⭐ 得分: " .. candidates[i].score ..
            "\n📍 地址: " .. string.format("0x%X", candidates[i].address) ..
            string.format("\n+4: %.6f\n+8: %.6f", candidates[i].val2, candidates[i].val3) ..
            "\n\n已改为 5.0x，速度变了吗？"
        )
        if c == 1 then
            speedAddr = candidates[i].address
            currentSpeed = 5.0
            onSaveFound()
            return
        elseif c == 3 then
            gg.setValues({{address = candidates[i].address, flags = gg.TYPE_FLOAT, value = 1.0}})
            return
        end
        gg.setValues({{address = candidates[i].address, flags = gg.TYPE_FLOAT, value = 1.0}})
    end
    gg.alert("❌ 未找到 timeScale\n\n请重新搜索或检查区域设置")
end

function testSingle(idx)
    gg.setValues({{address = candidates[idx].address, flags = gg.TYPE_FLOAT, value = 5.0}})
    local c = gg.choice(
        {"✅  就是它！", "❌  不是"},
        nil,
        "🎯 最后1个候选\n\n" ..
        "⭐ 得分: " .. candidates[idx].score ..
        "\n📍 地址: " .. string.format("0x%X", candidates[idx].address) ..
        "\n\n已改为 5.0x，速度变了吗？"
    )
    if c == 1 then
        speedAddr = candidates[idx].address
        currentSpeed = 5.0
        onSaveFound()
    else
        gg.setValues({{address = candidates[idx].address, flags = gg.TYPE_FLOAT, value = 1.0}})
        gg.alert("❌ 未找到 timeScale")
    end
end

-- ============ 找到后保存到GG列表 ============
function onSaveFound()
    removeOldSaves()

    local pkg = gg.getSelectedPackage() or "unknown"
    local note = SAVE_TAG .. " | " .. pkg .. " | " .. string.format("0x%X", speedAddr) .. " | " .. currentSpeed .. "x | " .. AUTHOR

    gg.addListItems({
        {
            address = speedAddr,
            flags = gg.TYPE_FLOAT,
            name = note,
            value = currentSpeed
        }
    })

    gg.alert(
        "━━━━━━━━━━━━━━━━━━━━━\n" ..
        "  ✅ 锁定 timeScale！\n" ..
        "━━━━━━━━━━━━━━━━━━━━━\n\n" ..
        "📍 地址: " .. string.format("0x%X", speedAddr) .. "\n" ..
        "🚀 当前: " .. currentSpeed .. "x\n\n" ..
        "💾 已保存到GG列表\n" ..
        "   可在列表中直接改数值\n\n" ..
        "━━━━━━━━━━━━━━━━━━━━━\n" ..
        "  闲鱼: " .. AUTHOR .. "\n" ..
        "━━━━━━━━━━━━━━━━━━━━━"
    )
end

-- ============ 清除旧的保存项 ============
function removeOldSaves()
    local items = gg.getListItems()
    local toRemove = {}
    for i = 1, #items do
        if items[i].name and string.find(items[i].name, "TimeScale") then
            toRemove[#toRemove + 1] = i
        end
    end
    if #toRemove > 0 then
        gg.removeListItems(toRemove)
    end
end

-- ============ 从GG保存列表加载 ============
function loadFromSaveList()
    local items = gg.getListItems()
    for i = 1, #items do
        if items[i].name and string.find(items[i].name, "TimeScale") then
            return items[i]
        end
    end
    return nil
end

function loadFromSaveListMenu()
    local saved = loadFromSaveList()
    if not saved then
        gg.alert(
            "❌ 保存列表中没有 timeScale\n\n" ..
            "请先搜索并确认"
        )
        return
    end

    speedAddr = saved.address
    currentSpeed = saved.value

    local choice = gg.choice(
        {
            "⚡  加载此地址（" .. currentSpeed .. "x）",
            "🔄  恢复1.0x正常速度",
            "🗑️  从保存列表移除",
            "🔙  返回"
        },
        nil,
        "💾 找到已保存的 timeScale\n\n" ..
        "📍 地址: " .. string.format("0x%X", speedAddr) .. "\n" ..
        "📝 备注: " .. (saved.name or "") .. "\n" ..
        "🚀 当前: " .. currentSpeed .. "x"
    )

    if choice == 1 then
        gg.toast("✅ 已加载 timeScale")
    elseif choice == 2 then
        applySpeed(1.0)
    elseif choice == 3 then
        local items = gg.getListItems()
        for i = 1, #items do
            if items[i].name and string.find(items[i].name, "TimeScale") then
                gg.removeListItems({i})
                break
            end
        end
        speedAddr = nil
        currentSpeed = 1.0
        gg.toast("🗑️ 已从保存列表移除")
    end
end

-- ============ 保存列表管理 ============
function showSaveListInfo()
    local saved = loadFromSaveList()
    if not saved then
        gg.alert("📋 保存列表中无 timeScale 记录")
        return
    end

    local choice = gg.choice(
        {
            "🚀  修改加速倍率",
            "🔄  恢复1.0x",
            "🗑️  移除记录",
            "🔙  返回"
        },
        nil,
        "💾 GG保存列表 - timeScale\n\n" ..
        "📍 地址: " .. string.format("0x%X", saved.address) .. "\n" ..
        "🚀 当前值: " .. saved.value .. "\n" ..
        "📝 备注: " .. (saved.name or "") .. "\n\n" ..
        "💡 也可直接在GG列表中\n   长按条目修改数值"
    )

    if choice == 1 then
        setSpeedDialog()
    elseif choice == 2 then
        resetSpeed()
    elseif choice == 3 then
        removeOldSaves()
        speedAddr = nil
        currentSpeed = 1.0
        gg.toast("🗑️ 已移除")
    end
end

-- ============ 工具函数 ============
function isGoodFloat(v)
    if v == nil then return false end
    if v ~= v then return false end
    if v == math.huge or v == -math.huge then return false end
    if v < -10000 or v > 10000 then return false end
    return true
end

function near(v, target)
    return math.abs(v - target) < 0.001
end

-- ============ 速度控制 ============
function setSpeedDialog()
    local input = gg.prompt(
        {"🚀 输入加速倍率"},
        {tostring(currentSpeed)},
        {"number"}
    )
    if not input then return end
    local speed = tonumber(input[1])
    if not speed or speed < 0.001 or speed > 1000 then
        gg.alert("⚠️ 倍率范围: 0.001 ~ 1000")
        return
    end
    applySpeed(speed)
end

function quickSpeedUp()
    local choice = gg.choice(
        {"🔥  2x  双倍", "🔥  3x", "🔥  5x  常用", "🔥  10x  高速", "🔥  20x  疾速", "✏️  自定义"},
        nil,
        "⏩ 快捷加速  【当前: " .. currentSpeed .. "x】"
    )
    if not choice then return end
    local speeds = {2.0, 3.0, 5.0, 10.0, 20.0}
    if choice <= 5 then applySpeed(speeds[choice]) else setSpeedDialog() end
end

function quickSlowDown()
    local choice = gg.choice(
        {"🐌  0.5x  半速", "🐌  0.25x", "🐌  0.1x  慢动作", "🐌  0.01x  极慢", "✏️  自定义"},
        nil,
        "⏪ 快捷减速  【当前: " .. currentSpeed .. "x】"
    )
    if not choice then return end
    local speeds = {0.5, 0.25, 0.1, 0.01}
    if choice <= 4 then applySpeed(speeds[choice]) else setSpeedDialog() end
end

function applySpeed(speed)
    if not speedAddr then
        gg.alert("⚠️ 请先搜索 timeScale")
        return
    end
    gg.setValues({{address = speedAddr, flags = gg.TYPE_FLOAT, value = speed}})
    currentSpeed = speed
    updateSaveListItem(speed)
    gg.toast("🚀 速度: " .. speed .. "x")
end

-- ============ 更新保存列表项 ============
function updateSaveListItem(speed)
    removeOldSaves()
    local pkg = gg.getSelectedPackage() or "unknown"
    local note = SAVE_TAG .. " | " .. pkg .. " | " .. string.format("0x%X", speedAddr) .. " | " .. speed .. "x | " .. AUTHOR
    gg.addListItems({
        {
            address = speedAddr,
            flags = gg.TYPE_FLOAT,
            name = note,
            value = speed
        }
    })
end

function resetSpeed()
    if not speedAddr then return end
    gg.setValues({{address = speedAddr, flags = gg.TYPE_FLOAT, value = 1.0}})
    currentSpeed = 1.0
    updateSaveListItem(1.0)
    gg.toast("🔄 已恢复 1.0x")
end

-- ============ 关于 / 署名 ============
function showAbout()
    gg.alert(
        "━━━━━━━━━━━━━━━━━━━━━\n" ..
        "  ⚡ " .. APP_NAME .. " " .. APP_VER .. "\n" ..
        "━━━━━━━━━━━━━━━━━━━━━\n\n" ..
        "  🔍 搜1.0f → 全量评分\n" ..
        "  ⚡ 二分法 → 精准确认\n" ..
        "  💾 自动保存 → GG列表\n" ..
        "  🎮 精准检测 → Unity引擎\n\n" ..
        "  检测规则：\n" ..
        "  • 核心特征(libunity.so/\n" ..
        "    UnityEngine.Time)命中即确认\n" ..
        "  • 辅助特征需2个以上命中\n" ..
        "  • 避免广告SDK误判\n\n" ..
        "━━━━━━━━━━━━━━━━━━━━━\n" ..
        "  👤 作者: " .. AUTHOR .. "\n" ..
        "  🛒 闲鱼: " .. AUTHOR .. "\n" ..
        "━━━━━━━━━━━━━━━━━━━━━\n\n" ..
        "⚠️ 使用前请在GG里\n   把内存区域全选！"
    )
end

-- ============ 启动 ============
showWelcome()
showMenu()
