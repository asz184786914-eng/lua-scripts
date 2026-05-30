-- GG文件读写全面测试
local results = {}

-- 用os.execute通过su写测试文件
os.execute("su -c 'echo TEST_READ_OK > /sdcard/.unity_key_test'")
os.execute("su -c 'echo TEST_READ_OK > /data/local/tmp/.unity_key_test'")

local paths = {
    "/sdcard/.unity_key_test",
    "/data/local/tmp/.unity_key_test",
    "/sdcard/.unity_key",
}

for _, p in ipairs(paths) do
    local f = io.open(p, "r")
    if f then
        local d = f:read("*a")
        f:close()
        results[#results + 1] = "✅ 读 " .. p .. " → [" .. (d or "nil") .. "]"
    else
        results[#results + 1] = "❌ 读 " .. p .. " → 打不开"
    end
end

-- gg.loadVariable
if type(gg.loadVariable) == "function" then
    local ok, val = pcall(gg.loadVariable, "unity_act")
    if ok and val and type(val) == "string" and val ~= "" then
        results[#results + 1] = "✅ gg.loadVariable → [" .. val .. "]"
    else
        results[#results + 1] = "❌ gg.loadVariable → 无数据"
    end
else
    results[#results + 1] = "❌ gg.loadVariable → 不存在"
end

-- io.open写测试
local wf = io.open("/sdcard/.unity_key_writetest", "w")
if wf then
    wf:write("WRITE_TEST_123")
    wf:close()
    local rf = io.open("/sdcard/.unity_key_writetest", "r")
    if rf then
        local rd = rf:read("*a")
        rf:close()
        if rd == "WRITE_TEST_123" then
            results[#results + 1] = "✅ io.open写读 → 一致"
        else
            results[#results + 1] = "⚠️ io.open写读 → 不匹配[" .. (rd or "nil") .. "]"
        end
    else
        results[#results + 1] = "❌ io.open写读 → 写了读不回"
    end
else
    results[#results + 1] = "❌ io.open写 → 失败"
end

-- os.execute+su写测试
os.execute("su -c 'echo SU_WRITE_TEST > /sdcard/.unity_key_sutest'")
local sf = io.open("/sdcard/.unity_key_sutest", "r")
if sf then
    local sd = sf:read("*a")
    sf:close()
    results[#results + 1] = "✅ su写io读 → [" .. (sd or "nil") .. "]"
else
    results[#results + 1] = "❌ su写io读 → 读不到"
end

-- gg.saveVariable测试
if type(gg.saveVariable) == "function" then
    pcall(gg.saveVariable, "test_key", "SAVE_VAR_123")
end
if type(gg.loadVariable) == "function" then
    local ok2, v2 = pcall(gg.loadVariable, "test_key")
    if ok2 and v2 == "SAVE_VAR_123" then
        results[#results + 1] = "✅ gg.save/loadVariable → 一致"
    else
        results[#results + 1] = "❌ gg.save/loadVariable → 不一致[" .. tostring(v2) .. "]"
    end
end

gg.alert(table.concat(results, "\n"))
